#----------------[ Pipeline lock, run requests, runner task, connection tests ]----------------

$script:GIRequestActions = @('All', 'FromStage', 'Stage', 'PostCheck', 'Rollback')
$script:GIRunnableStages = @('Preflight', 'Maintain', 'Snapshot', 'TestPush', 'Validate')
$script:GIRunnerTaskName = 'VDI-GI-Runner'
$script:GIPipelineTaskName = 'VDI-GI-Pipeline'

#----- Lock -----

function Get-GILockPath { param([hashtable] $Config) Join-Path $Config.Paths.State 'pipeline.lock' }

function Test-GIProcessAlive {
    param([int] $ProcessId)
    try { return [bool](Get-Process -Id $ProcessId -ErrorAction Stop) } catch { return $false }
}

function Get-GIPipelineLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config)
    $path = Get-GILockPath $Config
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $lock = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        # Being written right now, or corrupt: treat as held (not stale) so nothing starts on top of it
        return [pscustomobject]@{ pid = 0; host = ''; runId = $null; stage = '?'; startedAt = $null; requestedBy = $null; stale = $false }
    }
    $sameHost = ([string]$lock.host) -eq [Environment]::MachineName
    # A lock from another host can't be checked; it is only stale once the owner is clearly gone here
    $stale = $sameHost -and -not (Test-GIProcessAlive -ProcessId ([int]$lock.pid))
    $lock | Add-Member -NotePropertyName stale -NotePropertyValue $stale -Force
    return $lock
}

function Enter-GIPipelineLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [string] $Stage,
        [string] $RunId,
        [string] $RequestedBy = "$env:USERDOMAIN\$env:USERNAME"
    )
    $path = Get-GILockPath $Config
    $body = [ordered]@{
        pid = $PID; host = [Environment]::MachineName; runId = $RunId; stage = $Stage
        startedAt = (Get-Date).ToString('o'); requestedBy = $RequestedBy
    } | ConvertTo-Json -Compress
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                $fs.Write($bytes, 0, $bytes.Length)
            } finally { $fs.Dispose() }
            return
        } catch [System.IO.IOException] {
            $held = Get-GIPipelineLock -Config $Config
            if ($held -and $held.stale -and $attempt -eq 1) {
                Write-Warning "Removing stale pipeline lock (pid $($held.pid), stage $($held.stage), started $($held.startedAt))."
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                continue
            }
            $who = if ($held) { "stage $($held.stage), run $($held.runId), pid $($held.pid) on $($held.host), started $($held.startedAt) by $($held.requestedBy)" } else { 'unknown owner' }
            throw "Pipeline is busy: $who"
        }
    }
}

function Set-GIPipelineLockInfo {
    # Updates fields of a lock this process holds (stage/runId become known after a request is read)
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config, [string] $Stage, [string] $RunId, [string] $RequestedBy)
    $lock = Get-GIPipelineLock -Config $Config
    if (-not $lock -or [int]$lock.pid -ne $PID) { return }
    if ($PSBoundParameters.ContainsKey('Stage') -and $Stage) { $lock.stage = $Stage }
    if ($PSBoundParameters.ContainsKey('RunId') -and $RunId) { $lock.runId = $RunId }
    if ($PSBoundParameters.ContainsKey('RequestedBy') -and $RequestedBy) { $lock.requestedBy = $RequestedBy }
    $lock.PSObject.Properties.Remove('stale')
    Write-GIJsonAtomic -Path (Get-GILockPath $Config) -InputObject $lock
}

function Update-GIPipelineLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config, [Parameter(Mandatory)] [string] $RunId)
    Set-GIPipelineLockInfo -Config $Config -RunId $RunId
}

function Remove-GIRunRequest {
    <#
    .SYNOPSIS
      Admin cancels a queued request that the runner hasn't picked up.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [hashtable] $Config, [Parameter(Mandatory)] [string] $By)
    $req = Get-GIPendingRunRequest -Config $Config
    if (-not $req) { return $false }
    if ($PSCmdlet.ShouldProcess($req.id, 'Cancel queued request')) {
        Remove-Item -LiteralPath (Get-GIRequestPath $Config) -Force -ErrorAction SilentlyContinue
        Write-GIAudit -Config $Config -User $By -Action 'run.request.cancel' -Target ([string]$req.action) -Detail @{ id = $req.id; requestedBy = $req.requestedBy }
    }
    return $true
}

function Exit-GIPipelineLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config)
    $lock = Get-GIPipelineLock -Config $Config
    if ($lock -and [int]$lock.pid -eq $PID -and ([string]$lock.host) -eq [Environment]::MachineName) {
        Remove-Item -LiteralPath (Get-GILockPath $Config) -Force -ErrorAction SilentlyContinue
    }
}

#----- Run requests -----

function Get-GIRequestPath { param([hashtable] $Config) Join-Path $Config.Paths.State 'run-request.json' }

function Get-GIPendingRunRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config)
    $path = Get-GIRequestPath $Config
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { return $null }
}

function Get-GIConfigPoolNames {
    param([Parameter(Mandatory)] [hashtable] $Config)
    @([string]$Config.Pools.Test.Name) + @($Config.Pools.Production | ForEach-Object { [string]$_['Name'] }) | Where-Object { $_ }
}

function Assert-GIRunRequest {
    <#
    .SYNOPSIS
      Validates a request object (from the dashboard, or read back from disk). Throws on anything off.
    #>
    param([Parameter(Mandatory)] [hashtable] $Config, [Parameter(Mandatory)] $Request)
    $get = { param($n) if ($Request -is [System.Collections.IDictionary]) { $Request[$n] } elseif ($Request.PSObject.Properties[$n]) { $Request.$n } }
    $action = [string](& $get 'action')
    if ($script:GIRequestActions -notcontains $action) { throw "Unknown action '$action'." }

    if ($action -in 'FromStage', 'Stage') {
        $stage = [string](& $get 'stage')
        if ($script:GIRunnableStages -notcontains $stage) { throw "Stage '$stage' can't be started from a request." }
        $runId = [string](& $get 'runId')
        if ($runId -notmatch '^\d{8}-\d{6}$') { throw "Invalid run id '$runId'." }
        if (-not (Test-Path -LiteralPath (Join-Path $Config.Paths.State "$runId.json"))) { throw "Run $runId not found." }
    }
    if ($action -eq 'Rollback') {
        $pool = [string](& $get 'pool')
        if ((Get-GIConfigPoolNames -Config $Config) -notcontains $pool) { throw "Pool '$pool' is not configured." }
        $snap = [string](& $get 'snapshotName')
        if ($snap -and $snap -notmatch '^[\w .:()-]{1,80}$') { throw "Invalid snapshot name '$snap'." }
    }
}

function New-GIRunRequest {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [ValidateSet('All', 'FromStage', 'Stage', 'PostCheck', 'Rollback')] [string] $Action,
        [string] $Stage,
        [string] $RunId,
        [string] $Pool,
        [string] $SnapshotName,
        [switch] $ForceLogoff,
        [Parameter(Mandatory)] [string] $RequestedBy
    )
    $req = [ordered]@{
        id = [guid]::NewGuid().ToString(); action = $Action
        stage = if ($Stage) { $Stage } else { $null }
        runId = if ($RunId) { $RunId } else { $null }
        pool = if ($Pool) { $Pool } else { $null }
        snapshotName = if ($SnapshotName) { $SnapshotName.Trim() } else { $null }
        forceLogoff = [bool]$ForceLogoff
        requestedBy = $RequestedBy; requestedAt = (Get-Date).ToString('o')
    }
    Assert-GIRunRequest -Config $Config -Request $req

    $lock = Get-GIPipelineLock -Config $Config
    if ($lock -and -not $lock.stale) { throw "Pipeline is busy (stage $($lock.stage), run $($lock.runId)); try again when it finishes." }
    if (Get-GIPendingRunRequest -Config $Config) { throw 'A request is already queued and waiting for the runner.' }
    if (-not $PSCmdlet.ShouldProcess($Action, 'Queue run request')) { return }

    $path = Get-GIRequestPath $Config
    $json = $req | ConvertTo-Json -Compress
    try {
        # CreateNew: two admins pressing Go at the same moment can't both queue
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $b = [System.Text.Encoding]::UTF8.GetBytes($json); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
    } catch [System.IO.IOException] {
        throw 'A request is already queued and waiting for the runner.'
    }
    $auditAction = if ($Action -eq 'Rollback') { 'rollback.request' } else { 'run.request' }
    $target = if ($Action -eq 'Rollback') { $Pool } elseif ($RunId) { $RunId } else { $Action }
    Write-GIAudit -Config $Config -User $RequestedBy -Action $auditAction -Target $target -Detail ([hashtable]$req)
    return [pscustomobject]$req
}

function Read-GIRunRequest {
    <#
    .SYNOPSIS
      Runner side: takes the queued request (deletes the file) and re-validates it. $null when none.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config)
    $path = Get-GIRequestPath $Config
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $claimed = "$path.$PID.claimed"
    try { Move-Item -LiteralPath $path -Destination $claimed -ErrorAction Stop } catch { return $null }  # another runner took it
    try {
        $req = Get-Content -LiteralPath $claimed -Raw | ConvertFrom-Json -ErrorAction Stop
    } finally {
        Remove-Item -LiteralPath $claimed -Force -ErrorAction SilentlyContinue
    }
    Assert-GIRunRequest -Config $Config -Request $req
    return $req
}

#----- Scheduled tasks (Windows) -----

function Start-GIRunnerTask {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not $IsWindows) { throw 'The runner scheduled task only exists on Windows. The request stays queued.' }
    if ($PSCmdlet.ShouldProcess($script:GIRunnerTaskName, 'Start scheduled task')) {
        Start-ScheduledTask -TaskName $script:GIRunnerTaskName -ErrorAction Stop
    }
}

function Set-GIPipelineScheduleTask {
    <#
    .SYNOPSIS
      Points the weekly VDI-GI-Pipeline task at Promotion.PipelineSchedule (Day, Time). Returns @{ ok; detail }.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [hashtable] $Config)
    $day  = Get-GIConfigValue $Config 'Promotion.PipelineSchedule.Day' 'Tuesday'
    $time = Get-GIConfigValue $Config 'Promotion.PipelineSchedule.Time' '20:00'
    if (-not $IsWindows) { return @{ ok = $false; detail = 'Scheduled tasks are only available on Windows; settings saved, task not changed.' } }
    try {
        $task = Get-ScheduledTask -TaskName $script:GIPipelineTaskName -ErrorAction Stop
        $at = [datetime]::ParseExact($time, 'HH:mm', [cultureinfo]::InvariantCulture)
        $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $day -At $at
        if ($PSCmdlet.ShouldProcess($task.TaskName, "Set weekly trigger $day $time")) {
            Set-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Trigger $trigger -ErrorAction Stop | Out-Null
        }
        return @{ ok = $true; detail = "Weekly run now $day at $time." }
    } catch {
        return @{ ok = $false; detail = "Settings saved, but the scheduled task wasn't updated: $($_.Exception.Message)" }
    }
}

#----- Connection tests -----

function Test-GIConnection {
    <#
    .SYNOPSIS
      Read-only connectivity check for one system. Returns @{ ok; detail }. Never throws, never changes anything.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [ValidateSet('vCenter', 'Horizon', 'AppVolumes', 'GoldenImage', 'Pools', 'Email')] [string] $System
    )
    $vcConnected = $false
    try {
        switch ($System) {
            'vCenter' {
                $vc = Connect-VIServer -Server $Config.vCenter.Server -Credential (Get-GISecretCredential -Name $Config.vCenter.CredentialSecret) -ErrorAction Stop
                $vcConnected = $true
                return @{ ok = $true; detail = "Connected to $($vc.Name) (version $($vc.Version)) as $($vc.User)." }
            }
            'Horizon' {
                Connect-GIHorizon -Config $Config
                $n = @(Get-GIHorizonPools).Count
                return @{ ok = $true; detail = "Logged in to $($Config.Horizon.Server); $n desktop pool(s) visible." }
            }
            'AppVolumes' {
                Connect-GIAppVol -Config $Config
                $online = @(Get-GIAppVolCollection (Invoke-GIAppVolApi -Path (Get-GIAppVolEndpoint -Config $Config -Name OnlineEntities)))
                return @{ ok = $true; detail = "Logged in to $($Config.AppVolumes.Server); $($online.Count) online entities." }
            }
            'GoldenImage' {
                Connect-VIServer -Server $Config.vCenter.Server -Credential (Get-GISecretCredential -Name $Config.vCenter.CredentialSecret) -ErrorAction Stop | Out-Null
                $vcConnected = $true
                $vm = Get-VM -Name $Config.GoldenImage.VmName -ErrorAction Stop
                $snaps = @(Get-Snapshot -VM $vm -ErrorAction SilentlyContinue).Count
                Connect-GIHorizon -Config $Config
                Get-GIHorizonBaseImage -Config $Config | Out-Null
                $guest = 'guest credential not tested (VM is off; the test never powers it on)'
                if ($vm.PowerState -eq 'PoweredOn') {
                    $cred = Get-GISecretCredential -Name $Config.GoldenImage.GuestCredentialSecret
                    Invoke-GIGuestScript -VM $vm -Credential $cred -ScriptText 'exit 0' | Out-Null
                    $guest = 'guest credential OK'
                }
                return @{ ok = $true; detail = "$($vm.Name) is $($vm.PowerState), $snaps snapshot(s), visible to Horizon as a base VM; $guest." }
            }
            'Pools' {
                Connect-GIHorizon -Config $Config
                $found = foreach ($n in (Get-GIConfigPoolNames -Config $Config)) {
                    $info = Get-GIPoolImageInfo -Pool (Get-GIHorizonPool -Name $n)
                    $m = @(Get-GIHorizonPoolMachines -PoolId $info.PoolId).Count
                    "$n ($m machines$(if ($info.PendingSnapshotId) { ', push pending' }))"
                }
                return @{ ok = $true; detail = "Found: $($found -join '; ')." }
            }
            'Email' {
                $probe = [pscustomobject]@{ runId = 'test'; goldenVm = $Config.GoldenImage.VmName; status = 'Test'; stages = [pscustomobject]@{} }
                if (-not (Get-GIConfigValue $Config 'Email.Enabled' $false)) { return @{ ok = $false; detail = 'Email is disabled; enable it and save first.' } }
                $warn = $null
                Send-GIReport -Config $Config -Run $probe -Subject '[VDI Pipeline] Test email' -WarningVariable warn -WarningAction SilentlyContinue
                if ($warn) { return @{ ok = $false; detail = [string]$warn[0] } }
                return @{ ok = $true; detail = "Test email sent to $(@($Config.Email.To) -join ', ')." }
            }
        }
    } catch {
        return @{ ok = $false; detail = $_.Exception.Message }
    } finally {
        if ($System -in 'Horizon', 'GoldenImage', 'Pools') { Disconnect-GIHorizon }
        if ($System -eq 'AppVolumes') { $script:GIAppVol = $null }
        if ($vcConnected) { try { Disconnect-VIServer -Server * -Confirm:$false -Force -ErrorAction Stop } catch { Write-Verbose $_.Exception.Message } }
    }
}
