#----------------[ Pipeline stages: Preflight, Maintain, Snapshot, TestPush, Validate ]----------------
# Each Invoke-GIStage* function does the work and returns @{ Message = ''; Data = @{} }.
# Invoke-GIStage wraps them with state transitions, logging and failure handling.

$script:GIGoodMachineStates      = @('AVAILABLE', 'CONNECTED', 'DISCONNECTED')
$script:GITransientMachineStates = @('PROVISIONING', 'CUSTOMIZING', 'DELETING', 'MAINTENANCE', 'WAITING_FOR_AGENT',
                                     'STARTUP', 'VALIDATING', 'PROVISIONED', 'IN_PROGRESS', 'ALREADY_USED_PENDING')
# Registry DisplayName patterns for in-guest version checks (keys match the manifest from VDI-GoldenImage.ps1)
$script:GIAgentDisplayNames = [ordered]@{
    VmTools    = 'VMware Tools'
    Horizon    = 'Horizon Agent'
    DEM        = 'Dynamic Environment Manager'
    AppVolumes = 'App Volumes Agent'
    FSLogix    = 'Microsoft FSLogix Apps'
}

function Get-GIConfigValue {
    # Reads a nested config value with a default, e.g. Get-GIConfigValue $Config 'GoldenImage.GuestWorkDir' 'C:\x'
    param([hashtable] $Config, [string] $Path, $Default)
    $cur = $Config
    foreach ($part in $Path.Split('.')) {
        if ($cur -is [System.Collections.IDictionary] -and $cur.Contains($part)) { $cur = $cur[$part] } else { return $Default }
    }
    if ($null -eq $cur -or ($cur -is [string] -and $cur -eq '')) { return $Default }
    return $cur
}

function Invoke-GIStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] $Run,
        [Parameter(Mandatory)] [string] $Stage,
        [Parameter(Mandatory)] [scriptblock] $Action
    )
    $Run.status = 'Running'
    $Run.error = $null
    Set-GIStage -Config $Config -Run $Run -Stage $Stage -Status Running -Message ''
    Write-GILog -Config $Config -RunId $Run.runId -Message "Stage $Stage started"
    try {
        $out = & $Action
        $msg  = if ($out -is [hashtable] -and $out['Message']) { [string]$out.Message } else { '' }
        $data = if ($out -is [hashtable] -and $out['Data']) { $out['Data'] } else { $null }
        $params = @{ Config = $Config; Run = $Run; Stage = $Stage; Status = 'Succeeded'; Message = $msg }
        if ($data) { $params.Data = $data }
        Set-GIStage @params
        Set-GIProgress -Config $Config -Run $Run -Message ''
        Write-GILog -Config $Config -RunId $Run.runId -Message "Stage $Stage succeeded. $msg" -Level Success
    } catch {
        $err = "$Stage failed: $($_.Exception.Message)"
        Set-GIStage -Config $Config -Run $Run -Stage $Stage -Status Failed -Message $err
        Write-GILog -Config $Config -RunId $Run.runId -Message $err -Level Error
        throw
    }
}

#----- Connections -----

function Connect-GIServices {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config, [switch] $SkipAppVolumes)
    $vcCred = Get-GISecretCredential -Name $Config.vCenter.CredentialSecret
    Connect-VIServer -Server $Config.vCenter.Server -Credential $vcCred -ErrorAction Stop | Out-Null
    Connect-GIHorizon -Config $Config
    if (-not $SkipAppVolumes -and (Get-GIConfigValue $Config 'AppVolumes.Server' $null)) {
        Connect-GIAppVol -Config $Config
    }
}

function Disconnect-GIServices {
    [CmdletBinding()]
    param()
    Disconnect-GIHorizon
    $script:GIAppVol = $null
    try { Disconnect-VIServer -Server * -Confirm:$false -Force -ErrorAction Stop } catch { Write-Verbose "vCenter disconnect: $($_.Exception.Message)" }
}

#----- Guest helpers (VMware Tools guest operations, no WinRM needed) -----

function Invoke-GIGuestScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $VM,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [Parameter(Mandatory)] [string] $ScriptText
    )
    return Invoke-VMScript -VM $VM -GuestCredential $Credential -ScriptType Powershell -ScriptText $ScriptText -ErrorAction Stop
}

function Wait-GIGuestReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $VM,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [int] $TimeoutMinutes = 20
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    Wait-Tools -VM $VM -TimeoutSeconds ($TimeoutMinutes * 60) -ErrorAction Stop | Out-Null
    while ((Get-Date) -lt $deadline) {
        try { Invoke-GIGuestScript -VM $VM -Credential $Credential -ScriptText 'exit 0' | Out-Null; return } catch { Start-Sleep -Seconds 20 }
    }
    throw "Guest operations on '$($VM.Name)' not ready after $TimeoutMinutes minutes."
}

function Restart-GIGuest {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $VM, [Parameter(Mandatory)] [pscredential] $Credential)
    Restart-VMGuest -VM $VM -Confirm:$false -ErrorAction Stop | Out-Null
    Start-Sleep -Seconds 90   # let Tools go down before waiting for it to come back
    Wait-GIGuestReady -VM (Get-VM -Id $VM.Id) -Credential $Credential
}

function Invoke-GIGuestAction {
    <#
    .SYNOPSIS
      Runs VDI-GoldenImage.ps1 -Action <Action> -Unattended in the guest and returns its parsed result file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] $VM,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [Parameter(Mandatory)] [string] $Action
    )
    $script = $Config.GoldenImage.ScriptPathInGuest
    $work   = Get-GIConfigValue $Config 'GoldenImage.GuestWorkDir' 'C:\ProgramData\VDI\Pipeline'
    $res    = "$work\result-$Action.json"
    $text = @"
New-Item -ItemType Directory -Path '$work' -Force | Out-Null
Remove-Item '$res' -ErrorAction SilentlyContinue
& '$script' -Action $Action -Unattended -ResultFile '$res'
exit `$LASTEXITCODE
"@
    $r = Invoke-GIGuestScript -VM $VM -Credential $Credential -ScriptText $text
    $json = (Invoke-GIGuestScript -VM $VM -Credential $Credential -ScriptText "if(Test-Path '$res'){ Get-Content '$res' -Raw }").ScriptOutput
    $parsed = if ($json -and $json.Trim()) { $json | ConvertFrom-Json } else { $null }
    if ($r.ExitCode -ne 0) {
        $errs = if ($parsed -and $parsed.errors) { ($parsed.errors -join '; ') } else { ($r.ScriptOutput | Out-String).Trim() }
        throw "In-guest action '$Action' exited $($r.ExitCode): $errs"
    }
    return $parsed
}

function Invoke-GIGuestWindowsUpdate {
    <#
    .SYNOPSIS
      Repeats Windows Update passes (scheduled task as SYSTEM) with reboots until nothing is left or MaxPasses is hit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] $Run,
        [Parameter(Mandatory)] $VM,
        [Parameter(Mandatory)] [pscredential] $Credential
    )
    $work     = Get-GIConfigValue $Config 'GoldenImage.GuestWorkDir' 'C:\ProgramData\VDI\Pipeline'
    $maxPass  = [int](Get-GIConfigValue $Config 'GoldenImage.WindowsUpdate.MaxPasses' 5)
    $passMin  = [int](Get-GIConfigValue $Config 'GoldenImage.WindowsUpdate.PassTimeoutMin' 120)
    $wuScript = Join-Path $Config.Root 'guest/Invoke-GIWindowsUpdate.ps1'
    $res      = "$work\wu-result.json"
    $task     = 'VDI-GI-WindowsUpdate'

    Invoke-GIGuestScript -VM $VM -Credential $Credential -ScriptText "New-Item -ItemType Directory -Path '$work' -Force | Out-Null" | Out-Null
    Copy-VMGuestFile -Source $wuScript -Destination "$work\" -VM $VM -LocalToGuest -GuestCredential $Credential -Force -ErrorAction Stop

    $summary = [System.Collections.Generic.List[object]]::new()
    for ($pass = 1; $pass -le $maxPass; $pass++) {
        Set-GIProgress -Config $Config -Run $Run -Message "Windows Update pass $pass of ${maxPass}: searching and installing"
        $start = @"
Remove-Item '$res' -ErrorAction SilentlyContinue
`$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File "$work\Invoke-GIWindowsUpdate.ps1" -ResultFile "$res"'
Register-ScheduledTask -TaskName '$task' -Action `$a -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName '$task'
"@
        Invoke-GIGuestScript -VM $VM -Credential $Credential -ScriptText $start | Out-Null

        $deadline = (Get-Date).AddMinutes($passMin)
        $result = $null
        while (-not $result) {
            if ((Get-Date) -gt $deadline) { throw "Windows Update pass $pass did not finish within $passMin minutes." }
            Start-Sleep -Seconds 60
            try {
                $out = (Invoke-GIGuestScript -VM $VM -Credential $Credential -ScriptText "if(Test-Path '$res'){ Get-Content '$res' -Raw }").ScriptOutput
                if ($out -and $out.Trim()) { $result = $out | ConvertFrom-Json }
            } catch { Write-Verbose "Polling WU result: $($_.Exception.Message)" }
        }
        $summary.Add([pscustomobject]@{ pass = $pass; found = $result.found; installed = $result.installed; failed = $result.failed; reboot = $result.rebootRequired })
        Write-GILog -Config $Config -RunId $Run.runId -Message "WU pass ${pass}: found=$($result.found) installed=$($result.installed) failed=$($result.failed) reboot=$($result.rebootRequired)"
        if ($result.error) { throw "Windows Update pass $pass error: $($result.error)" }

        if ($result.rebootRequired) {
            Set-GIProgress -Config $Config -Run $Run -Message "Windows Update pass ${pass}: $($result.installed) installed, rebooting"
            Restart-GIGuest -VM $VM -Credential $Credential
        }
        if ($result.found -eq 0 -and -not $result.rebootRequired) { break }
    }
    Invoke-GIGuestScript -VM $VM -Credential $Credential -ScriptText "Unregister-ScheduledTask -TaskName '$task' -Confirm:`$false -ErrorAction SilentlyContinue" | Out-Null

    $last = $summary | Select-Object -Last 1
    $remaining = if ($last -and $last.found -gt 0) { "Updates still pending after $maxPass passes." } else { '' }
    return @{ Passes = @($summary); Warning = $remaining }
}

#----- Stage: Preflight -----

function Invoke-GIStagePreflight {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config, [Parameter(Mandatory)] $Run)

    $vm = Get-VM -Name $Config.GoldenImage.VmName -ErrorAction Stop
    if ($vm.PowerState -ne 'PoweredOff') {
        throw "Golden VM '$($vm.Name)' is $($vm.PowerState). Someone may be working on it; power it off to let the pipeline run."
    }
    $img = Get-GIHorizonBaseImage -Config $Config

    $poolNames = @($Config.Pools.Test.Name) + @($Config.Pools.Production | ForEach-Object { $_.Name })
    $pools = @{}
    foreach ($n in $poolNames) {
        $info = Get-GIPoolImageInfo -Pool (Get-GIHorizonPool -Name $n)
        if ($info.PendingSnapshotId) {
            throw "Pool '$n' already has a pending image push (state '$($info.PendingImageState)'). Wait for it or cancel it first."
        }
        $pools[$n] = $info.PoolId
    }
    @{ Message = "vCenter, Horizon and pools OK ($($poolNames.Count) pools)"; Data = @{ poolIds = $pools; baseVmId = $img.BaseVm.id } }
}

#----- Stage: Maintain -----

function Invoke-GIStageMaintain {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config, [Parameter(Mandatory)] $Run)

    $gi   = $Config.GoldenImage
    $cred = Get-GISecretCredential -Name $gi.GuestCredentialSecret
    $vm   = Get-VM -Name $gi.VmName -ErrorAction Stop

    # Safety snapshot before touching anything
    Set-GIProgress -Config $Config -Run $Run -Message 'Creating safety snapshot'
    $safety = New-Snapshot -VM $vm -Name "pre-maint-$($Run.runId)" -Description "Before VDI pipeline run $($Run.runId)" -Memory:$false -Confirm:$false -ErrorAction Stop
    $Run.safetySnapshot = [pscustomobject]@{ id = [string]$safety.Id; name = $safety.Name }
    Save-GIRun -Config $Config -Run $Run

    Set-GIProgress -Config $Config -Run $Run -Message 'Powering on golden VM'
    if ($vm.PowerState -ne 'PoweredOn') { $vm = Start-VM -VM $vm -Confirm:$false -ErrorAction Stop }
    Wait-GIGuestReady -VM $vm -Credential $cred

    if (Get-GIConfigValue $Config 'GoldenImage.CopyScript' $true) {
        $local = Join-Path (Split-Path $Config.Root -Parent) 'VDI-GoldenImage.ps1'
        if (Test-Path $local) {
            $dir = Split-Path $gi.ScriptPathInGuest -Parent
            Invoke-GIGuestScript -VM $vm -Credential $cred -ScriptText "New-Item -ItemType Directory -Path '$dir' -Force | Out-Null" | Out-Null
            Copy-VMGuestFile -Source $local -Destination "$dir\" -VM $vm -LocalToGuest -GuestCredential $cred -Force -ErrorAction Stop
        }
    }

    $data = @{ actions = @() }
    Set-GIProgress -Config $Config -Run $Run -Message 'Enabling updates (-Action Update)'
    Invoke-GIGuestAction -Config $Config -VM $vm -Credential $cred -Action 'Update' | Out-Null

    if (Get-GIConfigValue $Config 'GoldenImage.WindowsUpdate.Enabled' $true) {
        $wu = Invoke-GIGuestWindowsUpdate -Config $Config -Run $Run -VM $vm -Credential $cred
        $data.windowsUpdate = $wu.Passes
        if ($wu.Warning) { $data.warnings = @($wu.Warning); Write-GILog -Config $Config -RunId $Run.runId -Message $wu.Warning -Level Warn }
    }

    foreach ($a in @($gi.Actions)) {
        Set-GIProgress -Config $Config -Run $Run -Message "Running in-guest action $a"
        Invoke-GIGuestAction -Config $Config -VM $vm -Credential $cred -Action $a | Out-Null
        $data.actions += $a
    }
    if (@($gi.Actions).Count) {
        Set-GIProgress -Config $Config -Run $Run -Message 'Rebooting after agent installs'
        Restart-GIGuest -VM $vm -Credential $cred
    }

    # 'Exit' action does nothing but still writes the result file with installed versions
    $manifestResult = Invoke-GIGuestAction -Config $Config -VM $vm -Credential $cred -Action 'Exit'
    $manifest = @{}
    if ($manifestResult -and $manifestResult.versions) {
        foreach ($p in $manifestResult.versions.PSObject.Properties) { if ($p.Value) { $manifest[$p.Name] = [string]$p.Value } }
    }
    $data.manifest = $manifest

    Set-GIProgress -Config $Config -Run $Run -Message "Finalizing (-Action $($gi.FinalizeAction))"
    try {
        Invoke-GIGuestAction -Config $Config -VM $vm -Credential $cred -Action $gi.FinalizeAction | Out-Null
    } catch {
        # OSOT -shutdown can power the guest off before the guest operation returns.
        # That's success; any other failure (VM still running after 5 minutes) is real.
        $finalizeError = $_
        $wait = (Get-Date).AddMinutes(5)
        while ((Get-VM -Id $vm.Id).PowerState -ne 'PoweredOff' -and (Get-Date) -lt $wait) { Start-Sleep -Seconds 20 }
        if ((Get-VM -Id $vm.Id).PowerState -ne 'PoweredOff') { throw $finalizeError }
    }

    $vm = Get-VM -Id $vm.Id
    if ($vm.PowerState -eq 'PoweredOn') {
        Set-GIProgress -Config $Config -Run $Run -Message 'Shutting down guest'
        Stop-VMGuest -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null
    }
    $timeout = [int](Get-GIConfigValue $Config 'GoldenImage.PowerOffTimeoutMin' 90)
    $deadline = (Get-Date).AddMinutes($timeout)
    while ((Get-VM -Id $vm.Id).PowerState -ne 'PoweredOff') {
        if ((Get-Date) -gt $deadline) { throw "Golden VM did not power off within $timeout minutes after finalize." }
        Set-GIProgress -Config $Config -Run $Run -Message 'Waiting for golden VM to power off'
        Start-Sleep -Seconds 30
    }
    @{ Message = "Updated and finalized ($(@($gi.Actions).Count) agent actions)"; Data = $data }
}

#----- Stage: Snapshot -----

function Invoke-GIStageSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config, [Parameter(Mandatory)] $Run)

    $manifest = @{}
    $m = $Run.stages.Maintain.data
    if ($m -and $m.PSObject.Properties['manifest'] -and $m.manifest) {
        foreach ($p in $m.manifest.PSObject.Properties) { $manifest[$p.Name] = $p.Value }
    }
    $snap = New-GIGoldenSnapshot -Config $Config -Run $Run -Manifest $manifest
    $Run.snapshot = $snap
    Save-GIRun -Config $Config -Run $Run

    $life = Invoke-GISnapshotLifecycle -Config $Config -Run $Run
    foreach ($w in $life.Warnings) { Write-GILog -Config $Config -RunId $Run.runId -Message $w -Level Warn }
    $removeList = @($life.Plan | Where-Object Action -eq 'Remove' | ForEach-Object Name)
    @{
        Message = "Created $($snap.name). Retention $($life.Mode): $($removeList.Count) candidate(s), $(@($life.Removed).Count) removed, chain depth $($life.ChainDepth)"
        Data    = @{ retentionMode = $life.Mode; candidates = $removeList; removed = @($life.Removed); chainDepth = $life.ChainDepth; warnings = @($life.Warnings) }
    }
}

#----- Stage: TestPush -----

function Wait-GIPoolPush {
    <#
    .SYNOPSIS
      Polls a pool until its current image is the expected snapshot and nothing is pending.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] $Run,
        [Parameter(Mandatory)] [string] $PoolName,
        [Parameter(Mandatory)] [string] $ExpectedSnapshotId,
        [int] $TimeoutMinutes = 120,
        [int] $PollSeconds = 30
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($true) {
        $info = Get-GIPoolImageInfo -Pool (Get-GIHorizonPool -Name $PoolName)
        $state = [string]$info.PendingImageState
        if ($state -match 'FAIL|ERROR') { throw "Push image on '$PoolName' failed (pending image state '$state')." }
        if (-not $info.PendingSnapshotId -and [string]$info.SnapshotId -eq $ExpectedSnapshotId) { return $info }
        if ((Get-Date) -gt $deadline) { throw "Push image on '$PoolName' not finished after $TimeoutMinutes minutes (state '$state')." }
        $pct = if ($info.PendingImageProgress) { " $($info.PendingImageProgress)%" } else { '' }
        Set-GIProgress -Config $Config -Run $Run -Message "Pushing image to ${PoolName}: $state$pct"
        Start-Sleep -Seconds $PollSeconds
    }
}

function Invoke-GIStageTestPush {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config, [Parameter(Mandatory)] $Run)
    if (-not $Run.snapshot) { throw 'Run has no snapshot; run the Snapshot stage first.' }

    $img  = Get-GIHorizonBaseImage -Config $Config -SnapshotName $Run.snapshot.name
    $test = $Config.Pools.Test
    $pool = Get-GIHorizonPool -Name $test.Name
    $policy = Get-GIConfigValue $Config 'Pools.Test.LogoffPolicy' 'FORCE_LOGOFF'

    Invoke-GIHorizonPushImage -PoolId $pool.id -ParentVmId $img.BaseVm.id -SnapshotId $img.Snapshot.id `
        -StartTime (Get-Date) -LogoffPolicy $policy -StopOnFirstError $true
    $timeout = [int](Get-GIConfigValue $Config 'Pools.PushTimeoutMin' 120)
    Wait-GIPoolPush -Config $Config -Run $Run -PoolName $test.Name -ExpectedSnapshotId ([string]$img.Snapshot.id) -TimeoutMinutes $timeout | Out-Null
    @{ Message = "Test pool '$($test.Name)' now on $($Run.snapshot.name)"; Data = @{ horizonSnapshotId = [string]$img.Snapshot.id; horizonBaseVmId = [string]$img.BaseVm.id } }
}

#----- Stage: Validate -----

function New-GICheck {
    param([string] $Category, [string] $Name, [string] $Target, [bool] $Passed, [string] $Detail)
    [pscustomobject]@{ category = $Category; name = $Name; target = $Target; passed = $Passed; detail = $Detail }
}

function Wait-GIPoolMachinesSettled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        $Run,
        [Parameter(Mandatory)] [string] $PoolId,
        [Parameter(Mandatory)] [string] $PoolName,
        [int] $TimeoutMinutes = 60
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($true) {
        $machines = @(Get-GIHorizonPoolMachines -PoolId $PoolId)
        $busy = @($machines | Where-Object { $script:GITransientMachineStates -contains $_.state })
        if ($machines.Count -gt 0 -and $busy.Count -eq 0) { return $machines }
        if ((Get-Date) -gt $deadline) { return $machines }
        if ($Run) { Set-GIProgress -Config $Config -Run $Run -Message "Waiting for $PoolName machines: $($busy.Count) of $($machines.Count) still provisioning" }
        Start-Sleep -Seconds 30
    }
}

function Test-GIPoolHealth {
    <#
    .SYNOPSIS
      Horizon (+ optional guest and App Volumes) checks for one pool. Returns check objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        $Run,
        [Parameter(Mandatory)] [string] $PoolName,
        [string] $ExpectedSnapshotId,
        [hashtable] $Manifest = @{},
        [switch] $IncludeGuest,
        [switch] $IncludeAppVolumes
    )
    $checks = [System.Collections.Generic.List[object]]::new()
    $pool = Get-GIHorizonPool -Name $PoolName
    $info = Get-GIPoolImageInfo -Pool $pool

    if ($ExpectedSnapshotId) {
        $checks.Add((New-GICheck 'Horizon' 'PoolImage' $PoolName ([string]$info.SnapshotId -eq $ExpectedSnapshotId) "current snapshot id '$($info.SnapshotId)'"))
    }

    $timeout = [int](Get-GIConfigValue $Config 'Validation.MachineReadyTimeoutMin' 60)
    $machines = @(Wait-GIPoolMachinesSettled -Config $Config -Run $Run -PoolId $info.PoolId -PoolName $PoolName -TimeoutMinutes $timeout)
    $checks.Add((New-GICheck 'Horizon' 'MachineCount' $PoolName ($machines.Count -gt 0) "$($machines.Count) machine(s)"))
    foreach ($m in $machines) {
        $checks.Add((New-GICheck 'Horizon' 'MachineState' $m.name ($script:GIGoodMachineStates -contains $m.state) ([string]$m.state)))
    }
    $healthy = @($machines | Where-Object { $_.state -eq 'AVAILABLE' })

    if ($IncludeGuest) {
        $credName = Get-GIConfigValue $Config 'Validation.GuestCredentialSecret' $Config.GoldenImage.GuestCredentialSecret
        $cred = Get-GISecretCredential -Name $credName
        $count = [int](Get-GIConfigValue $Config 'Validation.GuestSampleCount' 2)
        $services = @(Get-GIConfigValue $Config 'Validation.RequiredServices' @())
        $namesJson = ($script:GIAgentDisplayNames | ConvertTo-Json -Compress).Replace("'", "''")
        $svcList = ($services | ForEach-Object { "'$($_.Replace("'", "''"))'" }) -join ','
        $probe = @"
`$names = '$namesJson' | ConvertFrom-Json
`$svc = @{}; foreach(`$s in @($svcList)){ `$x = Get-Service -Name `$s -ErrorAction SilentlyContinue; `$svc[`$s] = if(`$x){ [string]`$x.Status } else { 'Missing' } }
`$keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
`$apps = Get-ItemProperty `$keys -ErrorAction SilentlyContinue
`$ver = @{}; foreach(`$p in `$names.PSObject.Properties){ `$a = @(`$apps | Where-Object { `$_.DisplayName -like "*`$(`$p.Value)*" }) | Select-Object -First 1; `$ver[`$p.Name] = if(`$a){ [string]`$a.DisplayVersion } else { `$null } }
@{ services = `$svc; versions = `$ver } | ConvertTo-Json -Compress
"@
        foreach ($m in ($healthy | Select-Object -First $count)) {
            try {
                $vm = Get-VM -Name $m.name -ErrorAction Stop
                $out = (Invoke-GIGuestScript -VM $vm -Credential $cred -ScriptText $probe).ScriptOutput
                $r = $out | ConvertFrom-Json
                foreach ($s in $services) {
                    $st = [string]$r.services.$s
                    $checks.Add((New-GICheck 'Guest' "Service:$s" $m.name ($st -eq 'Running') $st))
                }
                foreach ($k in $Manifest.Keys) {
                    if (-not $script:GIAgentDisplayNames.Contains($k) -or -not $Manifest[$k]) { continue }
                    $actual = [string]$r.versions.$k
                    $checks.Add((New-GICheck 'Guest' "Version:$k" $m.name ($actual -eq [string]$Manifest[$k]) "expected $($Manifest[$k]), found $actual"))
                }
            } catch {
                $checks.Add((New-GICheck 'Guest' 'Probe' $m.name $false $_.Exception.Message))
            }
        }
        if (-not $healthy) { $checks.Add((New-GICheck 'Guest' 'Probe' $PoolName $false 'No AVAILABLE machine to probe')) }
    }

    if ($IncludeAppVolumes -and $script:GIAppVol) {
        # AVM response shapes vary by release; match each record's JSON text against the machine name
        # so the check doesn't depend on exact field names. Endpoints are set in config.
        try {
            $online = @((Get-GIAppVolOnlineEntities -Config $Config).Entities)
            $attach = @(Get-GIAppVolCollection (Invoke-GIAppVolApi -Path (Get-GIAppVolEndpoint -Config $Config -Name Attachments)))
            $onlineText = @($online | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 })
            $attachText = @($attach | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 })
            $packages = @(Get-GIConfigValue $Config 'AppVolumes.TestPackages' @())
            foreach ($m in $healthy) {
                $short = [regex]::Escape(($m.name -split '\.')[0])
                $isOnline = [bool]($onlineText | Where-Object { $_ -match "(?i)\b$short\b" })
                $checks.Add((New-GICheck 'AppVolumes' 'AgentOnline' $m.name $isOnline ($(if ($isOnline) { 'seen by App Volumes Manager' } else { 'not in online entities' }))))
                foreach ($pkg in $packages) {
                    $p = [regex]::Escape($pkg)
                    $hit = [bool]($attachText | Where-Object { $_ -match "(?i)\b$short\b" -and $_ -match "(?i)$p" })
                    $checks.Add((New-GICheck 'AppVolumes' "Attached:$pkg" $m.name $hit ($(if ($hit) { 'attached' } else { 'no attachment found' }))))
                }
            }
        } catch {
            $checks.Add((New-GICheck 'AppVolumes' 'Api' $PoolName $false $_.Exception.Message))
        }
    }
    return $checks.ToArray()
}

function Invoke-GIStageValidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config, [Parameter(Mandatory)] $Run)

    $manifest = @{}
    if ($Run.snapshot -and $Run.snapshot.manifest) {
        foreach ($p in $Run.snapshot.manifest.PSObject.Properties) { $manifest[$p.Name] = $p.Value }
    }
    $expected = $null
    $tp = $Run.stages.TestPush.data
    if ($tp -and $tp.PSObject.Properties['horizonSnapshotId']) { $expected = [string]$tp.horizonSnapshotId }

    $checks = @(Test-GIPoolHealth -Config $Config -Run $Run -PoolName $Config.Pools.Test.Name -ExpectedSnapshotId $expected `
        -Manifest $manifest -IncludeGuest -IncludeAppVolumes)
    $failed = @($checks | Where-Object { -not $_.passed })
    $Run.validation = [pscustomobject]@{ passed = ($checks.Count -gt 0 -and $failed.Count -eq 0); checks = $checks }
    Save-GIRun -Config $Config -Run $Run

    if ($failed.Count) {
        $first = ($failed | Select-Object -First 3 | ForEach-Object { "$($_.category)/$($_.name) on $($_.target): $($_.detail)" }) -join '; '
        throw "$($failed.Count) of $($checks.Count) checks failed. $first"
    }
    @{ Message = "All $($checks.Count) checks passed" }
}
