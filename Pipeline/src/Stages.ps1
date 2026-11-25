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

function Resolve-GIInstallerSourceDir {
    # GoldenImage.InstallerSourceDir as a full path, or '' when not set. Relative paths resolve from the Pipeline folder.
    param([Parameter(Mandatory)] [hashtable] $Config)
    $dir = [string](Get-GIConfigValue $Config 'GoldenImage.InstallerSourceDir' '')
    if (-not $dir.Trim()) { return '' }
    $dir = $dir.Trim()
    if (-not [System.IO.Path]::IsPathRooted($dir)) { $dir = Join-Path $Config.Root $dir }
    return $dir
}

function Get-GIInstallerStatus {
    <#
    .SYNOPSIS
        One row per known package: whether it's selected and whether its installer is in the host folder.
        State: Found, Download (missing, guest script fetches it), Missing, NoFolder (no host folder set). Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config)
    $dir = Resolve-GIInstallerSourceDir -Config $Config
    $selected = @(Get-GIConfigValue $Config 'GoldenImage.Actions' @()) | ForEach-Object { [string]$_ }
    $folderError = $null
    $files = @()
    if ($dir) {
        try {
            if (Test-Path -LiteralPath $dir -PathType Container) { $files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction Stop) }
            else { $folderError = "Folder '$dir' not found on the pipeline host." }
        } catch { $folderError = "Can't read '$dir': $($_.Exception.Message)" }
    }
    $rows = foreach ($action in $script:GIGuestPackages.Keys) {
        $pkg = $script:GIGuestPackages[$action]
        $match = $files | Where-Object { $_.Name -like $pkg.Mask } | Sort-Object LastWriteTime, Name | Select-Object -Last 1
        $state = if (-not $dir) { 'NoFolder' } elseif ($match) { 'Found' } elseif ($pkg.AutoDownload) { 'Download' } else { 'Missing' }
        $version = ''
        if ($match -and $match.Extension -eq '.exe') { try { $version = [string]$match.VersionInfo.FileVersion } catch { $version = '' } }
        [pscustomobject]@{
            Action = $action; Name = $pkg.Name; Mask = $pkg.Mask; AutoDownload = [bool]$pkg.AutoDownload
            Selected = ($selected -ccontains $action); State = $state
            File = $(if ($match) { $match.Name } else { '' }); Version = $version.Trim()
            SizeMB = $(if ($match) { [math]::Round($match.Length / 1MB, 1) } else { $null })
            Modified = $(if ($match) { $match.LastWriteTime } else { $null })
        }
    }
    return [pscustomobject]@{ Folder = $dir; FolderError = $folderError; Packages = @($rows) }
}

function Sync-GIGuestInstallers {
    # Copies installer packages from a folder on the pipeline host into the guest's Install folder.
    # Files the guest already has with the same name and size are skipped, so large agents copy once.
    # Timestamps are carried over because VDI-GoldenImage.ps1 picks the newest file per mask by LastWriteTime.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $VM,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [Parameter(Mandatory)] [string] $SourceDir,
        [Parameter(Mandatory)] [string] $GuestDir
    )
    if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
        throw "Installer source folder '$SourceDir' not found on the pipeline host."
    }
    $files = @(Get-ChildItem -LiteralPath $SourceDir -File)
    if (-not $files.Count) { return [pscustomobject]@{ Copied = @(); Skipped = @() } }

    $listScript = "New-Item -ItemType Directory -Path '$GuestDir' -Force | Out-Null; " +
                  "@(Get-ChildItem -LiteralPath '$GuestDir' -File | ForEach-Object { @{ n = `$_.Name; l = `$_.Length } }) | ConvertTo-Json -Compress"
    $out = Invoke-GIGuestScript -VM $VM -Credential $Credential -ScriptText $listScript
    $existing = @{}
    $json = if ($out) { ([string]$out.ScriptOutput).Trim() } else { '' }
    if ($json) { foreach ($e in @($json | ConvertFrom-Json)) { if ($e.n) { $existing[[string]$e.n] = [int64]$e.l } } }

    $copied = @(); $skipped = @(); $stamps = @()
    foreach ($f in $files) {
        if ($existing.ContainsKey($f.Name) -and $existing[$f.Name] -eq $f.Length) { $skipped += $f.Name; continue }
        Copy-VMGuestFile -Source $f.FullName -Destination "$GuestDir\" -VM $VM -LocalToGuest -GuestCredential $Credential -Force -ErrorAction Stop
        $copied += $f.Name
        $stamps += "(Get-Item -LiteralPath '$GuestDir\$($f.Name -replace "'", "''")').LastWriteTimeUtc = [datetime]::new($($f.LastWriteTimeUtc.Ticks), 'Utc')"
    }
    if ($stamps.Count) { Invoke-GIGuestScript -VM $VM -Credential $Credential -ScriptText ($stamps -join '; ') | Out-Null }
    return [pscustomobject]@{ Copied = $copied; Skipped = $skipped }
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
    .DESCRIPTION
      With -TimeoutMin the guest command runs async and is polled every 30 s; -OnWait gets the elapsed minutes.
      When the time runs out, installer processes in the guest are stopped and the action fails.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] $VM,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [Parameter(Mandatory)] [string] $Action,
        [int] $TimeoutMin = 0,
        [scriptblock] $OnWait
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
    if ($TimeoutMin -gt 0) {
        $r = Wait-GIGuestScriptAsync -Config $Config -VM $VM -Credential $Credential -ScriptText $text -Action $Action -TimeoutMin $TimeoutMin -OnWait $OnWait
    } else {
        $r = Invoke-GIGuestScript -VM $VM -Credential $Credential -ScriptText $text
    }
    $json = (Invoke-GIGuestScript -VM $VM -Credential $Credential -ScriptText "if(Test-Path '$res'){ Get-Content '$res' -Raw }").ScriptOutput
    $parsed = if ($json -and $json.Trim()) { $json | ConvertFrom-Json } else { $null }
    if ($r.ExitCode -ne 0) {
        $errs = if ($parsed -and $parsed.errors) { ($parsed.errors -join '; ') } else { ($r.ScriptOutput | Out-String).Trim() }
        throw "In-guest action '$Action' exited $($r.ExitCode): $errs"
    }
    return $parsed
}

function Wait-GIGuestScriptAsync {
    # Invoke-VMScript -RunAsync with a deadline. On timeout, stops installers started from the guest Install
    # folder (and msiexec) so the guest script returns, then throws.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] $VM,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [Parameter(Mandatory)] [string] $ScriptText,
        [Parameter(Mandatory)] [string] $Action,
        [Parameter(Mandatory)] [int] $TimeoutMin,
        [scriptblock] $OnWait
    )
    $task = Invoke-VMScript -VM $VM -GuestCredential $Credential -ScriptType Powershell -ScriptText $ScriptText -RunAsync -ErrorAction Stop
    $start = Get-Date
    $deadline = $start.AddMinutes($TimeoutMin)
    $timedOut = $false
    while ($true) {
        $state = [string](Get-Task -Id $task.Id -ErrorAction Stop).State
        if ($state -in 'Success', 'Error') { break }
        if (-not $timedOut -and (Get-Date) -gt $deadline) {
            $timedOut = $true
            $install = Join-Path (Split-Path $Config.GoldenImage.ScriptPathInGuest -Parent) 'Install'
            $kill = "Get-Process | Where-Object { `$_.Path -like '$install\*' } | Stop-Process -Force -ErrorAction SilentlyContinue; " +
                    "Get-Process msiexec -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue"
            try { Invoke-GIGuestScript -VM $VM -Credential $Credential -ScriptText $kill | Out-Null } catch { Write-Verbose "Stopping installers: $($_.Exception.Message)" }
            # Give the guest script a couple of minutes to notice and return
            $deadline = (Get-Date).AddMinutes(2)
            continue
        }
        if ($timedOut -and (Get-Date) -gt $deadline) { break }
        if ($OnWait -and -not $timedOut) { & $OnWait ([int][math]::Floor(((Get-Date) - $start).TotalMinutes)) }
        Start-Sleep -Seconds 30
    }
    $logs = Join-Path (Split-Path $Config.GoldenImage.ScriptPathInGuest -Parent) 'Logs'
    if ($timedOut) { throw "In-guest action '$Action' did not finish within $TimeoutMin minutes; installer processes were stopped. See the install logs in $logs." }
    if ($state -eq 'Error') {
        $t = Get-Task -Id $task.Id
        $why = try { [string]$t.ExtensionData.Info.Error.LocalizedMessage } catch { '' }
        throw "In-guest action '$Action' failed to run: $why"
    }
    return Wait-Task -Task $task -ErrorAction Stop
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
    # Catch a missing installer now, not after Windows Update has run for ten minutes
    $inst = Get-GIInstallerStatus -Config $Config
    if ($inst.Folder) {
        if ($inst.FolderError) { throw "Installer folder problem: $($inst.FolderError) Fix it under Settings > Packages." }
        $missing = @($inst.Packages | Where-Object { $_.Selected -and $_.State -eq 'Missing' })
        if ($missing.Count) {
            $list = ($missing | ForEach-Object { "$($_.Name) ($($_.Mask))" }) -join ', '
            throw "Installer missing on host for: $list in $($inst.Folder). Add it or untick it under Settings > Packages."
        }
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

#----- Maintain sub-steps -----

function Get-GIMaintainStepPlan {
    # Ordered Maintain steps for this config. Resumable steps are skipped on resume when they already succeeded;
    # the others run on every attempt (power on, copy files) or depend on everything before them (reboot onward).
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config)
    $gi = $Config.GoldenImage
    $actions = @(@(Get-GIConfigValue $Config 'GoldenImage.Actions' @()) | Where-Object { $_ })
    $wuOn = [bool](Get-GIConfigValue $Config 'GoldenImage.WindowsUpdate.Enabled' $true)
    $hasInstallers = [bool](Resolve-GIInstallerSourceDir -Config $Config)
    $plan = [System.Collections.Generic.List[object]]::new()
    $add = { param($Id, $Label, $Resumable, $Applies = $true, $SkipReason = '') $plan.Add([pscustomobject]@{ Id = $Id; Label = $Label; Resumable = $Resumable; Applies = $Applies; SkipReason = $SkipReason }) }
    & $add 'SafetySnapshot' 'Safety snapshot' $true
    & $add 'PowerOn' 'Power on, wait for guest' $false
    & $add 'CopyScript' 'Copy guest script' $false ([bool](Get-GIConfigValue $Config 'GoldenImage.CopyScript' $true)) 'CopyScript is off'
    & $add 'CopyInstallers' 'Copy installers' $false $hasInstallers 'No installer folder set'
    & $add 'EnableUpdates' 'Enable updates (-Action Update)' $true
    & $add 'WindowsUpdate' 'Windows Update' $true $wuOn 'Windows Update is turned off'
    foreach ($a in $actions) {
        $name = if ($script:GIGuestPackages.Contains([string]$a)) { $script:GIGuestPackages[[string]$a].Name } else { [string]$a }
        & $add "Pkg:$a" "Install $name" $true
    }
    & $add 'Reboot' 'Reboot after installs' $false ($actions.Count -gt 0) 'No packages selected'
    & $add 'Manifest' 'Read installed versions' $false
    & $add 'Finalize' "Finalize (-Action $($gi.FinalizeAction))" $false
    & $add 'PowerOff' 'Wait for power off' $false
    return $plan.ToArray()
}

function Get-GIVmRevertEvent {
    # Newest snapshot revert of the VM since $Since, or $null. Throws when vCenter events can't be read.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $VM, [Parameter(Mandatory)] [datetime] $Since)
    $ids = @('VirtualMachine.revertToSnapshot', 'VirtualMachine.revertToCurrentSnapshot')
    Get-VIEvent -Entity $VM -Start $Since -MaxSamples 2000 -ErrorAction Stop |
        Where-Object { $_.PSObject.Properties['Info'] -and $_.Info -and $ids -contains [string]$_.Info.DescriptionId } |
        Sort-Object CreatedTime | Select-Object -Last 1
}

function Invoke-GIMaintainStep {
    # Runs one Maintain step: Running -> Succeeded (message = last string the action returns) or Failed (rethrows).
    # Skipped steps and resumable steps that already succeeded are left alone.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] $Run,
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [scriptblock] $Action
    )
    $step = Get-GIStep -Run $Run -Id $Id
    if (-not $step) { throw "Unknown Maintain step '$Id'." }
    if ($step.status -eq 'Skipped') { return }
    if ($step.status -eq 'Succeeded' -and $step.resumable) {
        Write-GILog -Config $Config -RunId $Run.runId -Message "Maintain step '$($step.label)' already done in an earlier attempt; skipping"
        return
    }
    Set-GIStep -Config $Config -Run $Run -Id $Id -Status Running -Message ''
    Write-GILog -Config $Config -RunId $Run.runId -Message "Maintain step '$($step.label)' started"
    try {
        $out = @(& $Action)
        $msg = [string](@($out | Where-Object { $_ -is [string] }) | Select-Object -Last 1)
        Set-GIStep -Config $Config -Run $Run -Id $Id -Status Succeeded -Message $msg
    } catch {
        Set-GIStep -Config $Config -Run $Run -Id $Id -Status Failed -Message $_.Exception.Message
        throw
    }
}

#----- Stage: Maintain -----

function Invoke-GIStageMaintain {
    <#
    .SYNOPSIS
      Safety snapshot, Windows Update, package installs and finalize, as tracked sub-steps (run.stages.Maintain.steps).
    .DESCRIPTION
      A retry after a failed or interrupted attempt resumes at the first unfinished step; -FromStep picks the
      step to resume from ('SafetySnapshot' restarts everything). If the VM was reverted to a snapshot since the
      last attempt started, the earlier work is gone, so Maintain restarts from the beginning.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config, [Parameter(Mandatory)] $Run, [string] $FromStep = '')

    $gi   = $Config.GoldenImage
    $cred = Get-GISecretCredential -Name $gi.GuestCredentialSecret
    # Scriptblocks below run in a child scope, so shared state lives in this table
    $ctx  = @{ vm = (Get-VM -Name $gi.VmName -ErrorAction Stop); data = @{}; reverted = $false }

    # A revert since the earlier attempt started throws away its work: resume isn't safe
    $prev = @(Get-GIStepList -Run $Run)
    $resumeFrom = $FromStep
    $earliest = @($prev | Where-Object { $_.startedAt } | ForEach-Object { [datetime]$_.startedAt } | Sort-Object) | Select-Object -First 1
    if ($earliest -and @($prev | Where-Object { $_.status -eq 'Succeeded' -and $_.resumable -and $_.id -ne 'SafetySnapshot' }).Count) {
        try {
            $rev = Get-GIVmRevertEvent -VM $ctx.vm -Since $earliest
            if ($rev) {
                Write-GILog -Config $Config -RunId $Run.runId -Level Warn -Message "Golden VM was reverted to a snapshot at $($rev.CreatedTime) by $($rev.UserName); restarting Maintain from the beginning."
                $resumeFrom = 'SafetySnapshot'
                $ctx.reverted = $true
            }
        } catch {
            Write-GILog -Config $Config -RunId $Run.runId -Level Warn -Message "Couldn't read vCenter events to check for a snapshot revert ($($_.Exception.Message)); restarting Maintain from the beginning to be safe."
            # Not a confirmed revert: the existing safety snapshot still predates this run's Maintain, so keep it
            $resumeFrom = 'SafetySnapshot'
        }
    }
    $plan = Get-GIMaintainStepPlan -Config $Config
    $startAt = Initialize-GIMaintainSteps -Config $Config -Run $Run -Plan $plan -ResumeFrom $resumeFrom
    if ($startAt) { Write-GILog -Config $Config -RunId $Run.runId -Message "Maintain resuming at step '$((Get-GIStep -Run $Run -Id $startAt).label)'" }
    $step = { param($Id, $Body) Invoke-GIMaintainStep -Config $Config -Run $Run -Id $Id -Action $Body }

    & $step 'SafetySnapshot' {
        $existing = $Run.safetySnapshot
        $snap = if ($existing) { Get-Snapshot -VM $ctx.vm -Name $existing.name -ErrorAction SilentlyContinue | Select-Object -First 1 }
        # After a revert, the old safety snapshot is only still "before Maintain" if it's the one the VM went back to
        if ($snap -and (-not $ctx.reverted -or $snap.IsCurrent)) { return "Reusing $($existing.name)" }
        $name = if ($snap) { "pre-maint-$($Run.runId)-$((Get-Date).ToString('HHmmss'))" } else { "pre-maint-$($Run.runId)" }
        $safety = New-Snapshot -VM $ctx.vm -Name $name -Description "Before VDI pipeline run $($Run.runId)" -Memory:$false -Confirm:$false -ErrorAction Stop
        $Run.safetySnapshot = [pscustomobject]@{ id = [string]$safety.Id; name = $safety.Name }
        Save-GIRun -Config $Config -Run $Run
        "Created $($safety.Name)"
    }

    & $step 'PowerOn' {
        $ctx.vm = Get-VM -Id $ctx.vm.Id
        if ($ctx.vm.PowerState -ne 'PoweredOn') { $ctx.vm = Start-VM -VM $ctx.vm -Confirm:$false -ErrorAction Stop }
        Wait-GIGuestReady -VM $ctx.vm -Credential $cred
        'Guest ready'
    }

    & $step 'CopyScript' {
        $local = Join-Path (Split-Path $Config.Root -Parent) 'VDI-GoldenImage.ps1'
        if (-not (Test-Path $local)) { return "Not found on host: $local (using the copy already in the guest)" }
        $dir = Split-Path $gi.ScriptPathInGuest -Parent
        Invoke-GIGuestScript -VM $ctx.vm -Credential $cred -ScriptText "New-Item -ItemType Directory -Path '$dir' -Force | Out-Null" | Out-Null
        Copy-VMGuestFile -Source $local -Destination "$dir\" -VM $ctx.vm -LocalToGuest -GuestCredential $cred -Force -ErrorAction Stop
        "Copied to $dir"
    }

    & $step 'CopyInstallers' {
        $installerSrc = Resolve-GIInstallerSourceDir -Config $Config
        $guestInstall = Join-Path (Split-Path $gi.ScriptPathInGuest -Parent) 'Install'
        $sync = Sync-GIGuestInstallers -VM $ctx.vm -Credential $cred -SourceDir $installerSrc -GuestDir $guestInstall
        $ctx.data.installers = [pscustomobject]@{ copied = @($sync.Copied); skipped = @($sync.Skipped) }
        Write-GILog -Config $Config -RunId $Run.runId -Message "Installers: copied=$(@($sync.Copied).Count) unchanged=$(@($sync.Skipped).Count) -> $guestInstall" -Level Info
        "$(@($sync.Copied).Count) copied, $(@($sync.Skipped).Count) unchanged"
    }

    & $step 'EnableUpdates' {
        Invoke-GIGuestAction -Config $Config -VM $ctx.vm -Credential $cred -Action 'Update' | Out-Null
        'Done'
    }

    & $step 'WindowsUpdate' {
        $wu = Invoke-GIGuestWindowsUpdate -Config $Config -Run $Run -VM $ctx.vm -Credential $cred
        $ctx.data.windowsUpdate = $wu.Passes
        if ($wu.Warning) { $ctx.data.warnings = @($wu.Warning); Write-GILog -Config $Config -RunId $Run.runId -Message $wu.Warning -Level Warn }
        $installed = (@($wu.Passes) | Measure-Object -Property installed -Sum).Sum
        "$(@($wu.Passes).Count) pass(es), $([int]$installed) update(s) installed$(if ($wu.Warning) { "; $($wu.Warning)" })"
    }

    $timeout = [int](Get-GIConfigValue $Config 'GoldenImage.ActionTimeoutMin' 60)
    foreach ($a in @($gi.Actions | Where-Object { $_ })) {
        $id = "Pkg:$a"
        & $step $id {
            $onWait = { param($min) Set-GIStep -Config $Config -Run $Run -Id $id -Message "Running $min min (timeout $timeout min)" }.GetNewClosure()
            $r = Invoke-GIGuestAction -Config $Config -VM $ctx.vm -Credential $cred -Action $a -TimeoutMin $timeout -OnWait $onWait
            $ver = if ($r -and $r.PSObject.Properties['versions'] -and $r.versions -and $r.versions.PSObject.Properties[[string]$a]) { [string]$r.versions.$a } else { '' }
            if ($ver) { "Installed version $ver" } else { 'Done' }
        }
    }
    $ctx.data.actions = @(@(Get-GIStepList -Run $Run) | Where-Object { $_.id -like 'Pkg:*' -and $_.status -eq 'Succeeded' } | ForEach-Object { $_.id.Substring(4) })

    & $step 'Reboot' {
        Restart-GIGuest -VM $ctx.vm -Credential $cred
        'Guest back up'
    }

    & $step 'Manifest' {
        # 'Exit' action does nothing but still writes the result file with installed versions
        $manifestResult = Invoke-GIGuestAction -Config $Config -VM $ctx.vm -Credential $cred -Action 'Exit'
        $manifest = @{}
        if ($manifestResult -and $manifestResult.versions) {
            foreach ($p in $manifestResult.versions.PSObject.Properties) { if ($p.Value) { $manifest[$p.Name] = [string]$p.Value } }
        }
        $ctx.data.manifest = $manifest
        ($manifest.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name) $($_.Value)" }) -join ', '
    }

    & $step 'Finalize' {
        try {
            Invoke-GIGuestAction -Config $Config -VM $ctx.vm -Credential $cred -Action $gi.FinalizeAction | Out-Null
        } catch {
            # OSOT -shutdown can power the guest off before the guest operation returns.
            # That's success; any other failure (VM still running after 5 minutes) is real.
            $finalizeError = $_
            $wait = (Get-Date).AddMinutes(5)
            while ((Get-VM -Id $ctx.vm.Id).PowerState -ne 'PoweredOff' -and (Get-Date) -lt $wait) { Start-Sleep -Seconds 20 }
            if ((Get-VM -Id $ctx.vm.Id).PowerState -ne 'PoweredOff') { throw $finalizeError }
        }
        'Done'
    }

    & $step 'PowerOff' {
        $ctx.vm = Get-VM -Id $ctx.vm.Id
        if ($ctx.vm.PowerState -eq 'PoweredOn') {
            Set-GIStep -Config $Config -Run $Run -Id 'PowerOff' -Message 'Shutting down guest'
            Stop-VMGuest -VM $ctx.vm -Confirm:$false -ErrorAction Stop | Out-Null
        }
        $offTimeout = [int](Get-GIConfigValue $Config 'GoldenImage.PowerOffTimeoutMin' 90)
        $deadline = (Get-Date).AddMinutes($offTimeout)
        while ((Get-VM -Id $ctx.vm.Id).PowerState -ne 'PoweredOff') {
            if ((Get-Date) -gt $deadline) { throw "Golden VM did not power off within $offTimeout minutes after finalize." }
            Set-GIStep -Config $Config -Run $Run -Id 'PowerOff' -Message 'Waiting for golden VM to power off'
            Start-Sleep -Seconds 30
        }
        'Powered off'
    }
    @{ Message = "Updated and finalized ($(@($ctx.data.actions).Count) agent actions)"; Data = $ctx.data }
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
    # Fix a pending consolidation (failed or manual delete) before stacking a new Baseline on top
    $vm = Get-VM -Name $Config.GoldenImage.VmName -ErrorAction Stop
    $cons = Invoke-GIGoldenConsolidation -Config $Config -VM $vm
    if (-not $cons.Ok) { throw "$($cons.Message). Consolidate the golden VM's disks in vCenter, then re-run." }
    if ($cons.Needed) { Write-GILog -Config $Config -RunId $Run.runId -Message "Golden VM needed disk consolidation before the snapshot: $($cons.Message)" -Level Warn }

    $minFree = [double](Get-GIConfigValue $Config 'Snapshots.MinFreeSpacePercent' 15)
    $space = Get-GIGoldenSpace -VM $vm
    $spaceWarn = @()
    if ($space) {
        foreach ($d in $space.Datastores | Where-Object { $null -ne $_.FreePercent -and $_.FreePercent -lt $minFree }) {
            $spaceWarn += "Datastore $($d.Name) has $($d.FreePercent)% free ($($d.FreeGB) GB), below $minFree%."
        }
    }
    foreach ($w in $spaceWarn) { Write-GILog -Config $Config -RunId $Run.runId -Message $w -Level Warn }

    $snap = New-GIGoldenSnapshot -Config $Config -Run $Run -Manifest $manifest
    $Run.snapshot = $snap
    Save-GIRun -Config $Config -Run $Run

    # Preview only: snapshots are removed after the production push passes PostCheck
    $life = Invoke-GISnapshotLifecycle -Config $Config -Run $Run -ReportOnly
    foreach ($w in $life.Warnings) { Write-GILog -Config $Config -RunId $Run.runId -Message $w -Level Warn }
    $removeList = @($life.Plan | Where-Object Action -eq 'Remove' | ForEach-Object Name)
    @{
        Message = "Created $($snap.name). After production: $($removeList.Count) snapshot(s) to remove$(if ($removeList.Count) { " ($($removeList -join ', '))" }), chain depth $($life.ChainDepth)"
        Data    = @{ retentionMode = $life.Mode; candidates = $removeList; chain = $life.Chain; chainDepth = $life.ChainDepth; warnings = @($life.Warnings) + $spaceWarn; consolidation = $cons.Message }
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
