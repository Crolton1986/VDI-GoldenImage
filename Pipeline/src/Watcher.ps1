#----------------[ Guest watcher: host side (plan, launch, poll, mirror, cleanup) ]----------------
# The guest watcher (Pipeline/guest/Invoke-GIWatcher.ps1) runs EnableUpdates, WindowsUpdate and the Pkg:* steps
# inside the golden image. This file plans and launches it, polls it with one Invoke-VMScript per tick, mirrors
# its step files into run.stages.Maintain.steps and cleans up. See docs/CONTRACT.md, "Guest watcher".
# Functions marked (pure) never call PowerCLI and are unit-tested directly.

$script:GIWatcherTaskName = 'VDI-GI-Watcher'
$script:GIWatcherSourceFiles = @('Invoke-GIWatcher.ps1', 'GIWatcher.Core.ps1', 'Invoke-GIFixRunner.ps1', 'Invoke-GIWindowsUpdate.ps1')
$script:GIWatcherMaxLogBytes = 65536

#----- Small helpers (pure) -----

function Get-GIWatcherProp {
    # Safe property read for parsed JSON under Set-StrictMode: returns $Default when the object or property is missing.
    param($Object, [string] $Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] } else { return $Default }
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $Default
}

function ConvertTo-GIOffset {
    # [datetimeoffset] from a datetime, datetimeoffset or ISO 8601 string; $null when it can't be read.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetimeoffset]) { return $Value }
    if ($Value -is [datetime]) { return [datetimeoffset]$Value }
    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) { return $parsed }
    return $null
}

function ConvertTo-GIPsLiteral {
    # Body of a single-quoted PowerShell string: single quotes doubled.
    param([AllowEmptyString()][string] $Text)
    return $Text.Replace("'", "''")
}

function Assert-GIGuestPathValue {
    # Values pasted into guest scripts come from config; refuse anything that could break out of the quoting.
    param([Parameter(Mandatory)][string] $Value, [Parameter(Mandatory)][string] $What)
    if ($Value -notmatch '^[A-Za-z]:\\' -or $Value -match '["\x00-\x1f]') {
        throw "$What '$Value' is not a usable absolute guest path (drive letter path without quotes or control characters)."
    }
}

function Get-GIGuestParentPath {
    # Parent folder of a Windows path, using backslashes only (works on any host OS).
    param([Parameter(Mandatory)][string] $Path)
    $p = $Path.TrimEnd('\')
    $i = $p.LastIndexOf('\')
    if ($i -lt 0) { return '' }
    if ($i -le 2 -and $p -match '^[A-Za-z]:') { return $p.Substring(0, 3) }
    return $p.Substring(0, $i)
}

function Get-GIWatcherStepIds {
    # (pure) Ids of the run's guest steps that still need work (not Succeeded, not Skipped), in run order.
    param([Parameter(Mandatory)] $Run, [switch] $All)
    $rows = @(@(Get-GIStepList -Run $Run) | Where-Object { Test-GIWatcherStep -Id ([string]$_.id) })
    if (-not $All) { $rows = @($rows | Where-Object { $_.status -notin 'Succeeded', 'Skipped' }) }
    return @($rows | ForEach-Object { [string]$_.id })
}

function Get-GIWatcherSettings {
    # (pure) Effective GoldenImage.Watcher values with the contract defaults.
    param([Parameter(Mandatory)][hashtable] $Config)
    $d = @{ LogPollSec = 10; IdlePollSec = 60; StatusPollSec = 60; WatchingWindowSec = 30; StaleHeartbeatSec = 180; MaxRelaunches = 3; MaxStepAttempts = 4; FixTimeoutSec = 600 }
    $out = @{}
    foreach ($k in $d.Keys) { $out[$k] = [int](Get-GIConfigValue $Config "GoldenImage.Watcher.$k" $d[$k]) }
    return $out
}

function Get-GIWatcherPaths {
    # (pure) Guest folders for this config.
    param([Parameter(Mandatory)][hashtable] $Config)
    $work   = [string](Get-GIConfigValue $Config 'GoldenImage.GuestWorkDir' 'C:\ProgramData\VDI\Pipeline')
    $script = [string]$Config.GoldenImage.ScriptPathInGuest
    $dir    = Get-GIGuestParentPath -Path $script
    return @{ WorkDir = $work.TrimEnd('\'); ScriptPath = $script; ScriptDir = $dir; InstallDir = "$dir\Install"; LogDir = "$dir\Logs" }
}

function Get-GIWatcherPollInterval {
    # Seconds until the next tick: LogPollSec while someone watches the run page, else IdlePollSec.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Config, [Parameter(Mandatory)][string] $RunId)
    $s = Get-GIWatcherSettings -Config $Config
    $age = [double]::MaxValue
    if (Get-Command -Name Get-GIRunWatchingAge -ErrorAction SilentlyContinue) {
        try { $age = [double](Get-GIRunWatchingAge -Config $Config -RunId $RunId) } catch { $age = [double]::MaxValue }
    }
    if ($age -lt $s.WatchingWindowSec) { return $s.LogPollSec }
    return $s.IdlePollSec
}

function Wait-GIPollTick {
    # Sleeps between ticks; tests inject -SleepAction so loops run instantly.
    param([Parameter(Mandatory)][double] $Seconds, [scriptblock] $SleepAction)
    if ($SleepAction) { & $SleepAction $Seconds } else { Start-Sleep -Seconds $Seconds }
}

#----- Plan -----

function New-GIWatcherPlan {
    # (pure) plan.json content for the run's guest steps that are not Succeeded or Skipped.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)] $Run,
        [Parameter(Mandatory)][string] $AttemptId,
        [string] $LaunchId = ([guid]::NewGuid().ToString())
    )
    $p = Get-GIWatcherPaths -Config $Config
    $s = Get-GIWatcherSettings -Config $Config
    $maxPasses = [int](Get-GIConfigValue $Config 'GoldenImage.WindowsUpdate.MaxPasses' 5)
    $steps = foreach ($id in @(Get-GIWatcherStepIds -Run $Run)) {
        if ($id -notmatch '^[A-Za-z]+(:[A-Za-z]+)?$') { throw "Step id '$id' can't be handed to the guest watcher." }
        if ($id -ceq 'EnableUpdates') { [ordered]@{ id = $id; kind = 'Action'; action = 'Update' } }
        elseif ($id -ceq 'WindowsUpdate') { [ordered]@{ id = $id; kind = 'WindowsUpdate'; maxPasses = $maxPasses } }
        else { [ordered]@{ id = $id; kind = 'Action'; action = $id.Substring(4) } }
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        runId         = [string]$Run.runId
        attemptId     = $AttemptId
        launchId      = $LaunchId
        createdAt     = (Get-Date).ToString('o')
        scriptPath    = $p.ScriptPath
        workDir       = $p.WorkDir
        installDir    = $p.InstallDir
        logDir        = $p.LogDir
        settings      = [ordered]@{ heartbeatSec = 15; maxStepAttempts = $s.MaxStepAttempts; fixTimeoutSec = $s.FixTimeoutSec }
        steps         = @($steps)
    }
}

#----- Poll script, parsing, log chunks -----

function Get-GIWatcherPollScript {
    # (pure) Guest script for one tick (Windows PowerShell 5.1). Prints one compressed JSON line.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $WorkDir,
        [Parameter(Mandatory)][long] $LogOffset,
        [switch] $IncludeSteps
    )
    Assert-GIGuestPathValue -Value $WorkDir -What 'Guest work folder'
    $template = @'
$ErrorActionPreference = 'Stop'
$w = '{W}'
$off = [long]{OFF}
$inc = {INC}
function Read-Txt([string]$p) {
    try {
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        $fs = New-Object System.IO.FileStream($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try { $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8); return $sr.ReadToEnd() } finally { $fs.Dispose() }
    } catch { return $null }
}
$wt = Read-Txt "$w\watcher.json"
$alive = $false
if ($wt) {
    try {
        $wp = [int]((ConvertFrom-Json $wt).pid)
        if ($wp -gt 0) { $pr = Get-Process -Id $wp -ErrorAction SilentlyContinue; $alive = [bool]($pr -and $pr.ProcessName -match 'powershell|pwsh') }
    } catch { $alive = $false }
}
$size = [long]0
$b64 = ''
try {
    $lp = "$w\watcher.log"
    if (Test-Path -LiteralPath $lp) {
        $fs = New-Object System.IO.FileStream($lp, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $size = $fs.Length
            if ($off -lt $size) {
                $n = [int][Math]::Min({MAX}, $size - $off)
                $buf = New-Object byte[] $n
                [void]$fs.Seek($off, [System.IO.SeekOrigin]::Begin)
                $got = 0
                while ($got -lt $n) { $r = $fs.Read($buf, $got, $n - $got); if ($r -le 0) { break }; $got += $r }
                $b64 = [Convert]::ToBase64String($buf, 0, $got)
            }
        } finally { $fs.Dispose() }
    }
} catch { $b64 = '' }
$st = $null
if ($inc) {
    $st = @()
    if (Test-Path -LiteralPath "$w\steps") {
        foreach ($f in (Get-ChildItem -LiteralPath "$w\steps" -Filter '*.json' -File)) {
            if ($f.Name -match '\.\d+\.result\.json$') { continue }
            $t = Read-Txt $f.FullName
            if ($t) { $st += $t }
        }
    }
}
$os = Get-CimInstance Win32_OperatingSystem
$task = Get-ScheduledTask -TaskName 'VDI-GI-Watcher' -ErrorAction SilentlyContinue
$ts = ''
if ($task) { $ts = [string]$task.State }
[pscustomobject]@{ now = (Get-Date).ToString('o'); boot = $os.LastBootUpTime.ToString('o'); watcher = $wt; pidAlive = $alive; task = $ts; offset = $off; size = $size; log = $b64; steps = $st } | ConvertTo-Json -Compress -Depth 4
'@
    $inc = if ($IncludeSteps) { '$true' } else { '$false' }
    return $template.Replace('{W}', (ConvertTo-GIPsLiteral $WorkDir)).Replace('{OFF}', [string][math]::Max(0, $LogOffset)).Replace('{INC}', $inc).Replace('{MAX}', [string]$script:GIWatcherMaxLogBytes)
}

function ConvertFrom-GIWatcherPoll {
    # (pure) Parses the tick output. Throws when it isn't the expected JSON line.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)
    $line = @($Text -split "`r?`n" | Where-Object { $_.TrimStart().StartsWith('{') }) | Select-Object -Last 1
    if (-not $line) { throw "Unexpected guest watcher poll output: $(($Text | Out-String).Trim())" }
    $o = ConvertFrom-Json -InputObject $line
    $now = ConvertTo-GIOffset (Get-GIWatcherProp $o 'now')
    $boot = ConvertTo-GIOffset (Get-GIWatcherProp $o 'boot')
    if (-not $now -or -not $boot) { throw 'Guest watcher poll output has no usable time stamps.' }
    $parse = {
        param($raw)
        if ($null -eq $raw -or -not ([string]$raw).Trim()) { return $null }
        try { ConvertTo-GIDateString (ConvertFrom-Json -InputObject ([string]$raw)) } catch { $null }
    }
    $watcher = & $parse (Get-GIWatcherProp $o 'watcher')
    $rawSteps = Get-GIWatcherProp $o 'steps'
    $steps = $null
    if ($null -ne $rawSteps) {
        $steps = @(foreach ($t in @($rawSteps)) { $s = & $parse $t; if ($s) { $s } })
    }
    $b64 = [string](Get-GIWatcherProp $o 'log' '')
    $bytes = if ($b64) { [Convert]::FromBase64String($b64) } else { [byte[]]@() }
    return [pscustomobject]@{
        Now       = $now
        BootTime  = $boot
        Watcher   = $watcher
        PidAlive  = [bool](Get-GIWatcherProp $o 'pidAlive' $false)
        TaskState = [string](Get-GIWatcherProp $o 'task' '')
        Steps     = $steps
        Log       = @{ Offset = [long](Get-GIWatcherProp $o 'offset' 0); Size = [long](Get-GIWatcherProp $o 'size' 0); Bytes = $bytes }
    }
}

function Split-GIWatcherLogChunk {
    # (pure) Complete lines only. Bytes after the last LF stay for the next tick (NextOffset stops at the LF), so a
    # line or a multibyte character split across two reads is delivered whole. A chunk of the maximum size without
    # any LF is delivered as one line so an over-long line can't stall the log.
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][byte[]] $Bytes,
        [long] $Offset = 0
    )
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return [pscustomobject]@{ Lines = [string[]]@(); NextOffset = $Offset } }
    $last = [array]::LastIndexOf($Bytes, [byte]10)
    if ($last -lt 0) {
        if ($Bytes.Length -ge $script:GIWatcherMaxLogBytes) {
            return [pscustomobject]@{ Lines = [string[]]@([System.Text.Encoding]::UTF8.GetString($Bytes)); NextOffset = $Offset + $Bytes.Length }
        }
        return [pscustomobject]@{ Lines = [string[]]@(); NextOffset = $Offset }
    }
    $text = [System.Text.Encoding]::UTF8.GetString($Bytes, 0, $last + 1)
    $parts = @($text.Split("`n"))
    # The text ends with LF, so the final element is empty
    $lines = @($parts[0..($parts.Count - 2)] | ForEach-Object { $_.TrimEnd("`r") })
    if ($lines.Count -eq 1 -and $parts.Count -eq 1) { $lines = @() }
    return [pscustomobject]@{ Lines = [string[]]$lines; NextOffset = $Offset + $last + 1 }
}

#----- Liveness, timeouts, mirroring (pure) -----

function Test-GIWatcherDead {
    # (pure) Dead = heartbeat older than StaleSec by the guest's clock AND the pid is gone. A watcher that exited
    # cleanly or asked for a reboot isn't dead. The host clock isn't used (guest and host can disagree).
    [CmdletBinding()]
    param($Watcher, [bool] $PidAlive, [Parameter(Mandatory)] $Now, [Parameter(Mandatory)][int] $StaleSec)
    if ($null -eq $Watcher) { return $false }
    $state = [string](Get-GIWatcherProp $Watcher 'state' '')
    if ($state -in 'Exited', 'RebootRequested') { return $false }
    if ($PidAlive) { return $false }
    $hb = ConvertTo-GIOffset (Get-GIWatcherProp $Watcher 'heartbeat')
    $n = ConvertTo-GIOffset $Now
    if (-not $hb -or -not $n) { return $false }
    return (($n - $hb).TotalSeconds -gt $StaleSec)
}

function Test-GIWatcherHeartbeatStale {
    # (pure) Heartbeat older than StaleSec by the guest clock, regardless of the pid (used for the live-pid warning).
    param($Watcher, [Parameter(Mandatory)] $Now, [Parameter(Mandatory)][int] $StaleSec)
    if ($null -eq $Watcher) { return $false }
    $hb = ConvertTo-GIOffset (Get-GIWatcherProp $Watcher 'heartbeat')
    $n = ConvertTo-GIOffset $Now
    if (-not $hb -or -not $n) { return $false }
    return (($n - $hb).TotalSeconds -gt $StaleSec)
}

function Test-GIStepTimedOut {
    # (pure) Running or Fixing step whose current attempt started more than TimeoutMin minutes ago (guest clock).
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Step, [Parameter(Mandatory)] $Now, [Parameter(Mandatory)][double] $TimeoutMin)
    if ([string](Get-GIWatcherProp $Step 'status' '') -notin 'Running', 'Fixing') { return $false }
    $start = ConvertTo-GIOffset (Get-GIWatcherProp $Step 'attemptStartedAt')
    $n = ConvertTo-GIOffset $Now
    if (-not $start -or -not $n) { return $false }
    return (($n - $start).TotalMinutes -gt $TimeoutMin)
}

function ConvertTo-GIRunStepUpdate {
    # (pure) Guest step status file -> @{ Status; Message; Attempt; Fixes } for the run step (mapping table in the contract).
    [CmdletBinding()]
    param([Parameter(Mandatory)] $GuestStep)
    $status  = [string](Get-GIWatcherProp $GuestStep 'status' 'Pending')
    $msg     = [string](Get-GIWatcherProp $GuestStep 'message' '')
    $attempt = [int](Get-GIWatcherProp $GuestStep 'attempt' 0)
    $id      = [string](Get-GIWatcherProp $GuestStep 'id' '')
    $applied = @(@(Get-GIWatcherProp $GuestStep 'fixApplied' @()) | Where-Object { $null -ne $_ })
    $fixes   = @(foreach ($f in $applied) {
            [pscustomobject]@{
                id         = [string](Get-GIWatcherProp $f 'id' '')
                outcome    = [string](Get-GIWatcherProp $f 'outcome' '')
                fixAttempt = [int](Get-GIWatcherProp $f 'fixAttempt' 0)
            }
        })
    $prefix = if ($attempt -gt 1) { "Attempt ${attempt}: " } else { '' }
    switch ($status) {
        'Pending' { $rs = 'Pending'; $text = '' }
        'Running' { $rs = 'Running'; $text = "$prefix$msg" }
        'Fixing' {
            $rs = 'Running'
            $fixId = if ($msg -match 'applying fix (\S+)') { $Matches[1] } elseif ($fixes.Count) { $fixes[-1].id } else { '' }
            $text = "Attempt ${attempt}: applying fix $fixId".TrimEnd()
        }
        'RebootRequested' { $rs = 'Running'; $text = '' }
        'RebootRequired' {
            $rs = 'Running'
            $pending = Get-GIWatcherProp $GuestStep 'pendingFix'
            $what = if ($pending -and (Get-GIWatcherProp $pending 'id')) { [string](Get-GIWatcherProp $pending 'id') }
            elseif ($id -ceq 'WindowsUpdate') { "Windows Update pass $([int](Get-GIWatcherProp (Get-GIWatcherProp $GuestStep 'data') 'pass' 0))" }
            else { 'installer' }
            $text = "Reboot requested ($what)"
        }
        'Succeeded' {
            $rs = 'Succeeded'
            $ids = @($fixes | ForEach-Object { $_.id } | Where-Object { $_ } | Select-Object -Unique)
            $text = if ($ids.Count) { "$msg; fixed by $($ids -join ', ')" } else { $msg }
        }
        'Failed' { $rs = 'Failed'; $text = $msg }
        default { $rs = 'Running'; $text = $msg }
    }
    return @{ Status = $rs; Message = $text; Attempt = $attempt; Fixes = $fixes }
}

function Sync-GIWatcherSteps {
    # Mirrors guest step files into the run's steps. Writes (Set-GIStep saves the run) only when the status,
    # message, attempt or fixes changed. Guest steps from another attempt are ignored. Returns the number of changes.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)] $Run,
        [AllowNull()][AllowEmptyCollection()][object[]] $GuestSteps = @(),
        [string] $AttemptId = ''
    )
    $changes = 0
    foreach ($g in @($GuestSteps)) {
        if ($null -eq $g) { continue }
        if ($AttemptId -and [string](Get-GIWatcherProp $g 'attemptId' '') -ne $AttemptId) { continue }
        $id = [string](Get-GIWatcherProp $g 'id' '')
        if (-not (Test-GIWatcherStep -Id $id)) { continue }
        $row = Get-GIStep -Run $Run -Id $id
        if (-not $row -or $row.status -eq 'Skipped') { continue }
        $u = ConvertTo-GIRunStepUpdate -GuestStep $g
        $oldFixes = if ($row.PSObject.Properties['fixes']) { ConvertTo-Json -InputObject @($row.fixes) -Compress -Depth 4 } else { '[]' }
        $newFixes = ConvertTo-Json -InputObject @($u.Fixes) -Compress -Depth 4
        $oldAttempt = if ($row.PSObject.Properties['attempt']) { [int]$row.attempt } else { 0 }
        if ($row.status -eq $u.Status -and [string]$row.message -ceq $u.Message -and $oldAttempt -eq $u.Attempt -and $oldFixes -ceq $newFixes) { continue }
        $p = @{ Config = $Config; Run = $Run; Id = $id; Message = $u.Message; Attempt = $u.Attempt; Fixes = @($u.Fixes) }
        if ($row.status -ne $u.Status) { $p.Status = $u.Status }
        Set-GIStep @p
        $changes++
    }
    return $changes
}

#----- Stored watcher state (run.stages.Maintain.data.watcher) -----

function Get-GIWatcherState {
    param([Parameter(Mandatory)] $Run)
    $d = Get-GIWatcherProp $Run.stages.Maintain 'data'
    $w = Get-GIWatcherProp $d 'watcher'
    return @{
        logOffset  = [long](Get-GIWatcherProp $w 'logOffset' 0)
        launchId   = [string](Get-GIWatcherProp $w 'launchId' '')
        attemptId  = [string](Get-GIWatcherProp $w 'attemptId' '')
        bootTime   = [string](Get-GIWatcherProp $w 'bootTime' '')
        relaunches = [int](Get-GIWatcherProp $w 'relaunches' 0)
    }
}

function Set-GIWatcherState {
    param([Parameter(Mandatory)][hashtable] $Config, [Parameter(Mandatory)] $Run, [Parameter(Mandatory)][hashtable] $State)
    $obj = [pscustomobject][ordered]@{
        logOffset = [long]$State.logOffset; launchId = [string]$State.launchId; attemptId = [string]$State.attemptId
        bootTime = [string]$State.bootTime; relaunches = [int]$State.relaunches
    }
    if (-not $Run.stages.Maintain.PSObject.Properties['data'] -or $null -eq $Run.stages.Maintain.data) {
        Add-Member -InputObject $Run.stages.Maintain -NotePropertyName data -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    Add-Member -InputObject $Run.stages.Maintain.data -NotePropertyName watcher -NotePropertyValue $obj -Force
    Save-GIRun -Config $Config -Run $Run
}

function Add-GIWatcherHostLog {
    # Appends guest log lines unchanged to logs/<RunId>.watcher.log (UTF-8, no BOM, CRLF).
    param([Parameter(Mandatory)][hashtable] $Config, [Parameter(Mandatory)][string] $RunId, [string[]] $Lines)
    if (-not @($Lines).Count) { return }
    $dir = $Config.Paths.Logs
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir "$RunId.watcher.log"
    [System.IO.File]::AppendAllText($path, (($Lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding $false))
}

#----- Launch -----

function Start-GIGuestWatcher {
    <#
    .SYNOPSIS
      Copies the watcher files into the guest, writes plan.json and starts the one-shot SYSTEM task VDI-GI-Watcher.
    .DESCRIPTION
      -ResetSteps also deletes the guest's steps folder and watcher.log (a fresh Maintain attempt).
      Returns @{ LaunchId; BootTime } (guest boot time, ISO 8601).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)] $Run,
        [Parameter(Mandatory)] $VM,
        [Parameter(Mandatory)][pscredential] $Credential,
        [Parameter(Mandatory)][string] $AttemptId,
        [switch] $ResetSteps
    )
    $p = Get-GIWatcherPaths -Config $Config
    foreach ($v in @(@($p.WorkDir, 'Guest work folder'), @($p.ScriptPath, 'Guest script path'))) { Assert-GIGuestPathValue -Value $v[0] -What $v[1] }
    $src = Join-Path $Config.Root 'guest'
    foreach ($f in $script:GIWatcherSourceFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $src $f) -PathType Leaf)) { throw "Guest watcher file not found on the pipeline host: $(Join-Path $src $f)" }
    }
    $fixFiles = @()
    $fixDir = Join-Path $src 'fixes'
    if (Test-Path -LiteralPath $fixDir -PathType Container) { $fixFiles = @(Get-ChildItem -LiteralPath $fixDir -Filter '*.ps1' -File | Sort-Object Name) }

    $plan = New-GIWatcherPlan -Config $Config -Run $Run -AttemptId $AttemptId
    $W = ConvertTo-GIPsLiteral $p.WorkDir
    $prep = @'
$w = '{W}'
Stop-ScheduledTask -TaskName 'VDI-GI-Watcher' -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path "$w\watcher" -Force | Out-Null
if (Test-Path -LiteralPath "$w\fixes") { Remove-Item -Path "$w\fixes\*" -Recurse -Force -ErrorAction Stop }
New-Item -ItemType Directory -Path "$w\fixes" -Force | Out-Null
Remove-Item -LiteralPath "$w\watcher.json" -Force -ErrorAction SilentlyContinue
{RESET}
'@.Replace('{W}', $W).Replace('{RESET}', $(if ($ResetSteps) { "Remove-Item -LiteralPath `"`$w\steps`" -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item -LiteralPath `"`$w\watcher.log`" -Force -ErrorAction SilentlyContinue" } else { '' }))
    Invoke-GIGuestScript -VM $VM -Credential $Credential -ScriptText $prep | Out-Null

    foreach ($f in $script:GIWatcherSourceFiles) {
        Copy-VMGuestFile -Source (Join-Path $src $f) -Destination "$($p.WorkDir)\watcher\" -VM $VM -LocalToGuest -GuestCredential $Credential -Force -ErrorAction Stop
    }
    foreach ($f in $fixFiles) {
        Copy-VMGuestFile -Source $f.FullName -Destination "$($p.WorkDir)\fixes\" -VM $VM -LocalToGuest -GuestCredential $Credential -Force -ErrorAction Stop
    }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "gi-plan-$([guid]::NewGuid().ToString('N')).json"
    try {
        [System.IO.File]::WriteAllText($tmp, ($plan | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding $false))
        Copy-VMGuestFile -Source $tmp -Destination "$($p.WorkDir)\plan.json" -VM $VM -LocalToGuest -GuestCredential $Credential -Force -ErrorAction Stop
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }

    $launch = @'
$w = '{W}'
$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' + $w + '\watcher\Invoke-GIWatcher.ps1" -WorkDir "' + $w + '"')
# Default task priority is 7 (below normal) and installers inherit it; 4 is normal
$s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -Priority 4 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'VDI-GI-Watcher' -Action $a -Settings $s -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName 'VDI-GI-Watcher'
(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')
'@.Replace('{W}', $W)
    $out = Invoke-GIGuestScript -VM $VM -Credential $Credential -ScriptText $launch
    $boot = @(([string]$out.ScriptOutput) -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1
    return @{ LaunchId = [string]$plan.launchId; BootTime = [string]$boot }
}

function Stop-GIGuestWatcher {
    # Stops the watcher task and its process tree, msiexec and anything running from the install folder.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $VM,
        [Parameter(Mandatory)][pscredential] $Credential,
        [Parameter(Mandatory)][string] $WorkDir,
        [Alias('Pid')][int] $WatcherPid = 0,
        [string] $InstallDir = ''
    )
    Assert-GIGuestPathValue -Value $WorkDir -What 'Guest work folder'
    $install = if ($InstallDir) { Assert-GIGuestPathValue -Value $InstallDir -What 'Guest install folder'; ConvertTo-GIPsLiteral $InstallDir.TrimEnd('\') } else { '' }
    $text = @'
Stop-ScheduledTask -TaskName 'VDI-GI-Watcher' -ErrorAction SilentlyContinue
function Stop-Tree([int]$id) { Get-CimInstance Win32_Process -Filter "ParentProcessId=$id" | ForEach-Object { Stop-Tree $_.ProcessId }; Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
{TREE}
Get-Process msiexec -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
{INSTALL}
'@.Replace('{TREE}', $(if ($WatcherPid -gt 0) { "Stop-Tree $WatcherPid" } else { '' })).Replace('{INSTALL}', $(if ($install) { "Get-Process | Where-Object { `$_.Path -like '$install\*' } | Stop-Process -Force -ErrorAction SilentlyContinue" } else { '' }))
    Invoke-GIGuestScript -VM $VM -Credential $Credential -ScriptText $text | Out-Null
}

#----- Poll loop -----

function Set-GIWatcherRunFailure {
    # Makes sure a failed wait leaves a Failed guest step in the run (Maintain resumes only when a step is Failed or
    # Running): the running one, else the first one still pending.
    param([Parameter(Mandatory)][hashtable] $Config, [Parameter(Mandatory)] $Run, [Parameter(Mandatory)][string] $Message)
    $rows = @(@(Get-GIStepList -Run $Run) | Where-Object { (Test-GIWatcherStep -Id ([string]$_.id)) -and $_.status -ne 'Skipped' })
    if (@($rows | Where-Object { $_.status -eq 'Failed' }).Count) { return }
    $target = @($rows | Where-Object { $_.status -eq 'Running' }) | Select-Object -First 1
    if (-not $target) { $target = @($rows | Where-Object { $_.status -eq 'Pending' }) | Select-Object -First 1 }
    if ($target) { Set-GIStep -Config $Config -Run $Run -Id ([string]$target.id) -Status Failed -Message $Message }
}

function Wait-GIGuestWatcher {
    <#
    .SYNOPSIS
      Polls the guest watcher until every guest step of the plan Succeeded; throws when a step fails or the guest is lost.
    .DESCRIPTION
      One Invoke-VMScript per tick (adaptive interval). Mirrors step files into the run, appends new watcher.log
      lines to logs/<RunId>.watcher.log, restarts the guest when the watcher asks for it, relaunches a dead watcher
      (counted against GoldenImage.Watcher.MaxRelaunches) and enforces the per-attempt timeout.
      Returns the guest step objects of this attempt. -SleepAction (called with seconds) replaces Start-Sleep in tests.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)] $Run,
        [Parameter(Mandatory)] $VM,
        [Parameter(Mandatory)][pscredential] $Credential,
        [Parameter(Mandatory)][string] $AttemptId,
        [scriptblock] $SleepAction
    )
    $planIds = @(Get-GIWatcherStepIds -Run $Run)
    if (-not $planIds.Count) { return @() }
    $S = Get-GIWatcherSettings -Config $Config
    $P = Get-GIWatcherPaths -Config $Config
    $actionTimeout = [int](Get-GIConfigValue $Config 'GoldenImage.ActionTimeoutMin' 60)
    $wuTimeout = [int](Get-GIConfigValue $Config 'GoldenImage.WindowsUpdate.PassTimeoutMin' 120)
    $runId = [string]$Run.runId
    $log = { param($Msg, $Level = 'Info') Write-GILog -Config $Config -RunId $runId -Message $Msg -Level $Level }

    $state = Get-GIWatcherState -Run $Run
    $state.attemptId = $AttemptId
    $failures = 0
    $needSteps = $true
    $sinceSteps = 0
    $noWatcher = 0
    $prevSig = $null
    $guestSteps = @()
    $warned = [System.Collections.Generic.HashSet[string]]::new()
    try {
        while ($true) {
            $interval = [double](Get-GIWatcherPollInterval -Config $Config -RunId $runId)
            $includeSteps = $needSteps -or $sinceSteps -ge $S.StatusPollSec
            $poll = $null
            try {
                $text = Get-GIWatcherPollScript -WorkDir $P.WorkDir -LogOffset $state.logOffset -IncludeSteps:$includeSteps
                $res = Invoke-GIGuestScript -VM $VM -Credential $Credential -ScriptText $text
                $poll = ConvertFrom-GIWatcherPoll -Text ([string]$res.ScriptOutput)
                $failures = 0
            } catch {
                # Guest operations fail briefly while VMware Tools restarts (agent installs, reboots)
                $failures++
                Write-Verbose "Guest watcher poll failed ($failures): $($_.Exception.Message)"
                if ($failures -ge 10) { throw "Lost contact with the guest watcher (10 failed checks in a row): $($_.Exception.Message)" }
                Wait-GIPollTick -Seconds $interval -SleepAction $SleepAction
                $sinceSteps += $interval
                continue
            }

            # Log
            $backlog = $false
            if ($poll.Log.Size -lt $state.logOffset) {
                & $log "Guest watcher log is shorter than the stored offset ($($poll.Log.Size) < $($state.logOffset)); reading it from the start." 'Warn'
                $state.logOffset = 0
                $backlog = $true
            } else {
                $chunk = Split-GIWatcherLogChunk -Bytes $poll.Log.Bytes -Offset $poll.Log.Offset
                if (@($chunk.Lines).Count) {
                    Add-GIWatcherHostLog -Config $Config -RunId $runId -Lines $chunk.Lines
                    $backlog = ($poll.Log.Size -gt $chunk.NextOffset)
                }
                $state.logOffset = [long]$chunk.NextOffset
            }

            # Steps (only when the call included them)
            $fresh = $false
            if ($null -ne $poll.Steps) {
                $fresh = $true
                $needSteps = $false
                $sinceSteps = 0
                $guestSteps = @(@($poll.Steps) | Where-Object {
                        [string](Get-GIWatcherProp $_ 'runId' $runId) -eq $runId -and [string](Get-GIWatcherProp $_ 'attemptId' '') -eq $AttemptId
                    })
                $null = Sync-GIWatcherSteps -Config $Config -Run $Run -GuestSteps $guestSteps -AttemptId $AttemptId
            }

            # Watcher.json of an earlier launch is stale
            $w = $poll.Watcher
            if ($w -and $state.launchId -and [string](Get-GIWatcherProp $w 'launchId' '') -ne $state.launchId) { $w = $null }
            $wState = [string](Get-GIWatcherProp $w 'state' '')
            $wReason = [string](Get-GIWatcherProp $w 'exitReason' '')
            $sig = "$wState|$wReason|$(Get-GIWatcherProp $w 'currentStep' '')"
            $sigChanged = ($null -ne $prevSig -and $sig -ne $prevSig)
            $prevSig = $sig
            if ($sigChanged -and -not $fresh) {
                # Watcher moved on: read the step files right away
                $needSteps = $true
                Set-GIWatcherState -Config $Config -Run $Run -State $state
                continue
            }

            # A failed step ends Maintain (the step is already Failed in the run)
            $failed = @($guestSteps | Where-Object { $fresh -and [string](Get-GIWatcherProp $_ 'status' '') -eq 'Failed' }) | Select-Object -First 1
            if ($failed) {
                Set-GIWatcherState -Config $Config -Run $Run -State $state
                throw ([string](Get-GIWatcherProp $failed 'message' "Guest step '$(Get-GIWatcherProp $failed 'id' '')' failed."))
            }

            # Per-attempt timeout (only judged on fresh step files; a stale 'Running' must not time out a finished step)
            if ($fresh -and $wState -eq 'Running') {
                foreach ($g in $guestSteps) {
                    $gid = [string](Get-GIWatcherProp $g 'id' '')
                    $limit = if ($gid -ceq 'WindowsUpdate') { $wuTimeout } else { $actionTimeout }
                    if (Test-GIStepTimedOut -Step $g -Now $poll.Now -TimeoutMin $limit) {
                        try { Stop-GIGuestWatcher -VM $VM -Credential $Credential -WorkDir $P.WorkDir -WatcherPid ([int](Get-GIWatcherProp $w 'pid' 0)) -InstallDir $P.InstallDir }
                        catch { & $log "Stopping the guest watcher after a timeout failed: $($_.Exception.Message)" 'Warn' }
                        $msg = "Timed out after $limit min (attempt $([int](Get-GIWatcherProp $g 'attempt' 0))); installer processes were stopped. See the install logs in $($P.LogDir)."
                        Set-GIStep -Config $Config -Run $Run -Id $gid -Status Failed -Message $msg
                        Set-GIWatcherState -Config $Config -Run $Run -State $state
                        throw $msg
                    }
                }
            }

            # Boot time
            $bootChanged = $false
            $prevBoot = ConvertTo-GIOffset $state.bootTime
            if ($prevBoot) { $bootChanged = ([math]::Abs(($poll.BootTime - $prevBoot).TotalSeconds) -gt 30) }
            else { $state.bootTime = $poll.BootTime.ToString('o') }

            $action = ''   # '', 'Reboot', 'Relaunch', 'RelaunchFree'
            $why = ''
            if ($bootChanged -and ($wState -eq 'RebootRequested' -or ($wState -eq 'Exited' -and $wReason -eq 'RebootRequested'))) {
                $action = 'RelaunchFree'; $why = 'the guest rebooted for the requested reboot'
            } elseif ($bootChanged) {
                $action = 'Relaunch'; $why = 'the guest rebooted without being asked'
            } elseif ($wState -eq 'RebootRequested' -or ($wState -eq 'Exited' -and $wReason -eq 'RebootRequested')) {
                $action = 'Reboot'
            } elseif ($wState -eq 'Exited') {
                switch ($wReason) {
                    'AllDone' {
                        if (-not $fresh) { $needSteps = $true; Set-GIWatcherState -Config $Config -Run $Run -State $state; continue }
                        foreach ($id in $planIds) {
                            $g = @($guestSteps | Where-Object { [string](Get-GIWatcherProp $_ 'id' '') -ceq $id }) | Select-Object -First 1
                            $gs = [string](Get-GIWatcherProp $g 'status' 'missing')
                            if ($gs -ne 'Succeeded') { throw "Guest watcher finished but step '$id' is $gs." }
                        }
                        Set-GIWatcherState -Config $Config -Run $Run -State $state
                        return @($guestSteps)
                    }
                    'Crashed' { $action = 'Relaunch'; $why = 'it crashed' }
                    'PlanError' { throw 'The guest watcher could not read its plan (PlanError). See the watcher log.' }
                    default {
                        if (-not $fresh) { $needSteps = $true; Set-GIWatcherState -Config $Config -Run $Run -State $state; continue }
                        throw "The guest watcher stopped ($wReason) without a failed step. See the watcher log."
                    }
                }
            } elseif ($w) {
                $noWatcher = 0
                if (Test-GIWatcherDead -Watcher $w -PidAlive $poll.PidAlive -Now $poll.Now -StaleSec $S.StaleHeartbeatSec) {
                    $action = 'Relaunch'; $why = "its heartbeat stopped and the process is gone (last heartbeat $(Get-GIWatcherProp $w 'heartbeat' ''))"
                } elseif ((Test-GIWatcherHeartbeatStale -Watcher $w -Now $poll.Now -StaleSec $S.StaleHeartbeatSec)) {
                    $cur = @($guestSteps | Where-Object { [string](Get-GIWatcherProp $_ 'id' '') -ceq [string](Get-GIWatcherProp $w 'currentStep' '') }) | Select-Object -First 1
                    $key = "$(Get-GIWatcherProp $w 'currentStep' '')/$(Get-GIWatcherProp $cur 'attempt' 0)"
                    if ($warned.Add($key)) { & $log "Guest watcher heartbeat is older than $($S.StaleHeartbeatSec) s but its process is alive (step $key); the step timeout handles a real hang." 'Warn' }
                }
            } else {
                # No watcher.json of this launch yet: give the task a few ticks to start
                if ($poll.TaskState -ne 'Running') { $noWatcher++ } else { $noWatcher = 0 }
                if ($noWatcher -ge 3) { $action = 'Relaunch'; $why = "it never started (task state '$($poll.TaskState)')" }
            }

            switch ($action) {
                'Reboot' {
                    & $log 'Guest watcher requested a reboot; restarting the guest.'
                    Restart-GIGuest -VM $VM -Credential $Credential
                    $l = Start-GIGuestWatcher -Config $Config -Run $Run -VM $VM -Credential $Credential -AttemptId $AttemptId
                    $state.launchId = [string]$l.LaunchId; $state.bootTime = [string]$l.BootTime
                    $needSteps = $true; $noWatcher = 0; $prevSig = $null
                    Set-GIWatcherState -Config $Config -Run $Run -State $state
                    continue
                }
                { $_ -in 'Relaunch', 'RelaunchFree' } {
                    if ($action -eq 'Relaunch') {
                        $state.relaunches++
                        if ($state.relaunches -gt $S.MaxRelaunches) {
                            Set-GIWatcherState -Config $Config -Run $Run -State $state
                            throw "Guest watcher died $($state.relaunches) times (last: $why). See the watcher log."
                        }
                    }
                    & $log "Relaunching the guest watcher: $why ($($state.relaunches) of $($S.MaxRelaunches) relaunches used)." 'Warn'
                    $l = Start-GIGuestWatcher -Config $Config -Run $Run -VM $VM -Credential $Credential -AttemptId $AttemptId
                    $state.launchId = [string]$l.LaunchId; $state.bootTime = [string]$l.BootTime
                    $needSteps = $true; $noWatcher = 0; $prevSig = $null
                    Set-GIWatcherState -Config $Config -Run $Run -State $state
                    continue
                }
            }

            Set-GIWatcherState -Config $Config -Run $Run -State $state
            if (-not $backlog) {
                Wait-GIPollTick -Seconds $interval -SleepAction $SleepAction
                $sinceSteps += $interval
            }
        }
    } catch {
        $m = $_.Exception.Message
        try { Set-GIWatcherRunFailure -Config $Config -Run $Run -Message $m } catch { Write-Verbose "Marking the failed guest step: $($_.Exception.Message)" }
        throw
    }
}

#----- Cleanup -----

function Test-GIGuestWorkDirSafe {
    # (pure) $false for an empty path, a relative path, a drive root, or a folder equal to or above the guest script folder.
    [CmdletBinding()]
    param([AllowEmptyString()][string] $WorkDir, [AllowEmptyString()][string] $ScriptPath)
    if ([string]::IsNullOrWhiteSpace($WorkDir)) { return $false }
    $w = $WorkDir.Trim().Replace('/', '\').TrimEnd('\')
    if ($w -notmatch '^[A-Za-z]:\\.+' -or $w -match '["\x00-\x1f]') { return $false }
    if ($w -match '(^|\\)\.\.?(\\|$)') { return $false }
    $dir = if ($ScriptPath) { (Get-GIGuestParentPath -Path $ScriptPath.Trim().Replace('/', '\')).TrimEnd('\') } else { '' }
    if ($dir) {
        if ($dir -ieq $w) { return $false }
        if ($dir.StartsWith("$w\", [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Remove-GIGuestWatcher {
    <#
    .SYNOPSIS
      CleanupGuest: copies the guest watcher.log to logs/<RunId>.watcher.guest.log, removes the task and deletes the work folder.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)] $Run,
        [Parameter(Mandatory)] $VM,
        [Parameter(Mandatory)][pscredential] $Credential
    )
    $p = Get-GIWatcherPaths -Config $Config
    if (-not (Test-GIGuestWorkDirSafe -WorkDir $p.WorkDir -ScriptPath $p.ScriptPath)) {
        throw "Refusing to delete guest folder '$($p.WorkDir)': it is empty, a drive root, or the guest script folder '$($p.ScriptDir)' or a parent of it. Check GoldenImage.GuestWorkDir."
    }
    $runId = [string]$Run.runId
    $logs = $Config.Paths.Logs
    try {
        if (-not (Test-Path -LiteralPath $logs)) { New-Item -ItemType Directory -Path $logs -Force | Out-Null }
        Copy-VMGuestFile -Source "$($p.WorkDir)\watcher.log" -Destination (Join-Path $logs "$runId.watcher.guest.log") -VM $VM -GuestToLocal -GuestCredential $Credential -Force -ErrorAction Stop
    } catch {
        Write-GILog -Config $Config -RunId $runId -Level Warn -Message "Couldn't copy the guest watcher log: $($_.Exception.Message)"
    }
    $W = ConvertTo-GIPsLiteral $p.WorkDir
    $text = @'
$w = '{W}'
Stop-ScheduledTask -TaskName 'VDI-GI-Watcher' -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'VDI-GI-Watcher' -Confirm:$false -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $w) { Remove-Item -LiteralPath $w -Recurse -Force -ErrorAction Stop }
'@.Replace('{W}', $W)
    Invoke-GIGuestScript -VM $VM -Credential $Credential -ScriptText $text | Out-Null
}
