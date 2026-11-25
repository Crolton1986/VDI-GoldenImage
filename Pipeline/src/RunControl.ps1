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
        $runPath = Join-Path $Config.Paths.State "$runId.json"
        if (-not (Test-Path -LiteralPath $runPath)) { throw "Run $runId not found." }
        $step = [string](& $get 'step')
        if ($step) {
            if ($stage -ne 'Maintain') { throw "A step can only be given for the Maintain stage." }
            if ($step -notmatch '^[A-Za-z]+(:[A-Za-z]+)?$') { throw "Invalid step '$step'." }
            $known = @(Get-GIStepList -Run (Get-GIRun -Config $Config -RunId $runId) | ForEach-Object { [string]$_.id })
            if ($known -cnotcontains $step) { throw "Run $runId has no Maintain step '$step'." }
        }
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
        [string] $Step,
        [string] $RunId,
        [string] $Pool,
        [string] $SnapshotName,
        [switch] $ForceLogoff,
        [Parameter(Mandatory)] [string] $RequestedBy
    )
    $req = [ordered]@{
        id = [guid]::NewGuid().ToString(); action = $Action
        stage = if ($Stage) { $Stage } else { $null }
        step = if ($Step) { $Step } else { $null }
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

function Start-GIRunnerProcess {
    <#
    .SYNOPSIS
      Local (-LocalAdmin) runs: starts Invoke-GIPipeline.ps1 -FromRequest as a separate pwsh process
      under the current user instead of the VDI-GI-Runner scheduled task. Output goes to
      <Paths.Logs>/runner-<timestamp>.log. Returns @{ Pid; Log; Error } (Error set when it died right away).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [hashtable] $Config, [string] $ConfigPath)
    $script = Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-GIPipeline.ps1'
    $pwsh = (Get-Process -Id $PID).Path
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-GIProcessArgument $script), '-FromRequest')
    if ($ConfigPath) { $argList += @('-ConfigPath', (ConvertTo-GIProcessArgument $ConfigPath)) }
    $logDir = [string]$Config.Paths.Logs
    if (-not (Test-Path -LiteralPath $logDir)) { $null = New-Item -ItemType Directory -Path $logDir -Force }
    $log = Join-Path $logDir ("runner-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    if (-not $PSCmdlet.ShouldProcess($script, 'Start pipeline runner process')) { return }
    $sp = @{ FilePath = $pwsh; ArgumentList = $argList; PassThru = $true; RedirectStandardOutput = $log; RedirectStandardError = "$log.err" }
    if ($IsWindows) { $sp.WindowStyle = 'Hidden' }
    $proc = Start-Process @sp
    $result = @{ Pid = $proc.Id; Log = $log; Error = $null }
    # Exit 0 or 3 (pipeline busy / nothing to do) right away is normal; anything else is a startup failure
    if ($proc.WaitForExit(3000) -and $proc.ExitCode -notin 0, 3) {
        $err = ''
        foreach ($f in "$log.err", $log) {
            if (Test-Path -LiteralPath $f) { $err = ((Get-Content -LiteralPath $f -Tail 5 -ErrorAction SilentlyContinue) -join ' ').Trim(); if ($err) { break } }
        }
        $result.Error = if ($err) { $err } else { "exit code $($proc.ExitCode)" }
    }
    return $result
}

function Start-GIQueuedRun {
    <#
    .SYNOPSIS
      Starts whatever picks up the queued request: a local process with -LocalAdmin, otherwise the
      VDI-GI-Runner scheduled task. Returns the notice code for /run: started, queued, norunner or runfailed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config, [string] $ConfigPath, [switch] $Local)
    if ($Local) {
        try {
            $r = Start-GIRunnerProcess -Config $Config -ConfigPath $ConfigPath
            if ($r.Error) { Write-Warning "Runner process stopped right away: $($r.Error) (log: $($r.Log).err)"; return 'runfailed' }
            return 'started'
        } catch {
            Write-Warning "Could not start the runner process: $($_.Exception.Message)"
            return 'runfailed'
        }
    }
    try { Start-GIRunnerTask; return 'queued' } catch { return 'norunner' }
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

function Test-GITcpPort {
    <#
    .SYNOPSIS
      True when a TCP connection to Server:Port opens within TimeoutMs. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string] $Server, [int] $Port = 443, [int] $TimeoutMs = 5000)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($Server, $Port)
        return ($task.Wait($TimeoutMs) -and $client.Connected)
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Connect-GITestVIServer {
    <#
    .SYNOPSIS
      Connect-VIServer for connection tests: fails fast when vCenter isn't reachable on 443 and caps
      PowerCLI's web operation timeout. The cap leaves room for an MFA push (Duo times out at about
      60 seconds); a denied or unanswered push comes back as a login error, not a hang.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config)
    $server = [string]$Config.vCenter.Server
    if (-not $server) { throw 'vCenter.Server is empty.' }
    $cred = Get-GISecretCredential -Name $Config.vCenter.CredentialSecret
    if (-not (Test-GITcpPort -Server $server -Port 443 -TimeoutMs 5000)) {
        throw "Can't reach $server on port 443 within 5 seconds (DNS, firewall or proxy)."
    }
    try { Set-PowerCLIConfiguration -Scope Session -WebOperationTimeoutSeconds 90 -Confirm:$false -ErrorAction Stop | Out-Null }
    catch { Write-Verbose "Could not set the PowerCLI web operation timeout: $($_.Exception.Message)" }
    try {
        Connect-VIServer -Server $server -Credential $cred -ErrorAction Stop
    } catch {
        $m = $_.Exception.Message
        if ($m -match '(?i)incorrect user name or password|cannot complete login|authentication|denied|timed? ?out|timeout') {
            throw "vCenter login for $($cred.UserName) failed: $m If this account is behind Duo or another MFA push, the push was denied or not answered in time. Approve it and test again; for scheduled runs, exempt the service account from MFA."
        }
        throw
    }
}

function Invoke-GIConnectionTest {
    <#
    .SYNOPSIS
      Runs Test-GIConnection in a separate PowerShell process with a hard time limit, so a hung
      Connect-VIServer, a locked SecretStore prompt or a slow PowerCLI load can't block the web
      server. Returns @{ ok; detail; seconds }. Never throws.
    #>
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [Parameter(Mandatory)] [ValidateSet('vCenter', 'Horizon', 'AppVolumes', 'GoldenImage', 'Pools', 'Email')] [string] $System,
        [int] $TimeoutSeconds = 120
    )
    $manifest = Join-Path (Split-Path -Parent $PSScriptRoot) 'VDI-GIPipeline.psd1'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $job = $null
    try {
        $job = Start-Job -ArgumentList $manifest, $ConfigPath, $System -ScriptBlock {
            param($m, $cp, $sys)
            $ProgressPreference = 'SilentlyContinue'
            Import-Module $m -Force -ErrorAction Stop
            $a = @{}
            if ($cp) { $a.Path = $cp }
            $cfg = Get-GIConfig @a
            $r = Test-GIConnection -Config $cfg -System $sys
            [pscustomobject]@{ ok = [bool]$r.ok; detail = [string]$r.detail }
        }
        $done = Wait-Job -Job $job -Timeout $TimeoutSeconds
        if (-not $done) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            return @{ ok = $false; seconds = [int]$sw.Elapsed.TotalSeconds
                detail = "No answer after $TimeoutSeconds seconds; the test was stopped. Likely causes: an MFA (Duo) push that wasn't approved, the server is slow or unreachable, the SecretStore vault is locked and waiting for a password (Unlock-SecretStore / Set-SecretStoreConfiguration -Authentication None for the service account), or PowerCLI is waiting on a certificate or CEIP prompt (run the PowerCLI setup step)." }
        }
        $out = @(Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErr)
        $res = $out | Where-Object { $null -ne $_.PSObject.Properties['ok'] } | Select-Object -Last 1
        if (-not $res) {
            $msg = if ($jobErr) { [string]$jobErr[0] } elseif ($job.ChildJobs[0].JobStateInfo.Reason) { $job.ChildJobs[0].JobStateInfo.Reason.Message } else { 'The test process ended without a result.' }
            return @{ ok = $false; detail = $msg; seconds = [int]$sw.Elapsed.TotalSeconds }
        }
        return @{ ok = [bool]$res.ok; detail = [string]$res.detail; seconds = [int]$sw.Elapsed.TotalSeconds }
    } catch {
        return @{ ok = $false; detail = "Could not start the test: $($_.Exception.Message)"; seconds = [int]$sw.Elapsed.TotalSeconds }
    } finally {
        if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    }
}

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
                $vc = Connect-GITestVIServer -Config $Config
                $vcConnected = $true
                return @{ ok = $true; detail = "Connected to $($vc.Name) (version $($vc.Version)) as $($vc.User)." }
            }
            'Horizon' {
                Connect-GIHorizon -Config $Config
                $n = @(Get-GIHorizonPools).Count
                return @{ ok = $true; detail = "Logged in to $($Config.Horizon.Server); $n desktop pool(s) visible." }
            }
            'AppVolumes' {
                $trail = [System.Collections.Generic.List[string]]::new()
                $hints = [System.Collections.Generic.List[string]]::new()
                try {
                    Connect-GIAppVol -Config $Config
                    $trail.AddRange([string[]]$script:GIAppVol.Trail)
                    if ($script:GIAppVol.SessionPath -ne (Get-GIAppVolEndpoint -Config $Config -Name Session)) {
                        $hints.Add("Login worked at $($script:GIAppVol.SessionPath); set Session endpoint to that.")
                    }
                    $on = Get-GIAppVolOnlineEntities -Config $Config
                    $trail.AddRange([string[]]$on.Trail)
                    if ($on.Path -ne (Get-GIAppVolEndpoint -Config $Config -Name OnlineEntities)) {
                        $hints.Add("Online entities worked at $($on.Path); set Online entities endpoint to that.")
                    }
                } catch {
                    if ($_.Exception.Data.Contains('Trail')) { $trail.AddRange([string[]]$_.Exception.Data['Trail']) } else { $trail.Add($_.Exception.Message) }
                    return @{ ok = $false; detail = (@("App Volumes test failed on $($Config.AppVolumes.Server).") + $trail) -join "`n" }
                }
                $head = "Logged in to $($Config.AppVolumes.Server); $($on.Entities.Count) online entities."
                return @{ ok = $true; detail = (@($head) + $hints + $trail) -join "`n" }
            }
            'GoldenImage' {
                Connect-GITestVIServer -Config $Config | Out-Null
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
