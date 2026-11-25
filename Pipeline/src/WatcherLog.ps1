# Host side of the guest watcher log for the dashboard: reads slices of logs/<RunId>.watcher.log (the runner appends
# to it while the dashboard reads), and a "someone is watching" marker the runner uses to poll faster.
# Line format and behavior: docs/CONTRACT.md, "watcher.log" and "Dashboard (src/WatcherLog.ps1, Web/)".

function Test-GIWatcherStep {
    <# True for the Maintain steps that run in the guest watcher: EnableUpdates, WindowsUpdate and Pkg:<Action>. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string]$Id)
    if ([string]::IsNullOrEmpty($Id)) { return $false }
    return [regex]::IsMatch($Id, '^(EnableUpdates|WindowsUpdate|Pkg:[A-Za-z]+)\z', 'CultureInvariant')
}

function Get-GIWatcherLogPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$RunId
    )
    Join-Path $Config.Paths.Logs "$RunId.watcher.log"
}

function ConvertFrom-GIWatcherLogLine {
    <# One watcher.log line -> @{ at; level; step; text }. Malformed lines become INFO / '-' / whole line. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    $f = $Line.Split("`t", 4)
    if ($f.Count -eq 4 -and $f[1] -cin @('INFO', 'WARN', 'ERROR', 'OUT')) {
        return @{ at = $f[0]; level = $f[1]; step = $f[2]; text = $f[3] }
    }
    @{ at = ''; level = 'INFO'; step = '-'; text = $Line }
}

function Read-GIWatcherLogSlice {
    <#
    .SYNOPSIS
        Complete log lines for one step from byte Offset on. Returns @{ Lines = @(@{at;level;step;text}); Offset }.
    .DESCRIPTION
        A trailing partial line is left for the next call (Offset stops before it). Offset beyond the file length means
        the file was replaced: read from 0. Missing file: no lines, Offset unchanged. Never throws on content.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$StepId,
        [Parameter(Mandatory)][int64]$Offset,
        [int]$MaxBytes = 262144
    )
    $empty = @{ Lines = @(); Offset = $Offset }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $empty }
    try {
        $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $start = $Offset
            if ($start -lt 0 -or $start -gt $fs.Length) { $start = 0 }
            $null = $fs.Seek($start, [System.IO.SeekOrigin]::Begin)
            $buf = [byte[]]::new([Math]::Max(1, $MaxBytes))
            $n = 0
            while ($n -lt $buf.Length) {
                $r = $fs.Read($buf, $n, $buf.Length - $n)
                if ($r -le 0) { break }
                $n += $r
            }
        } finally { $fs.Dispose() }
        if ($n -le 0) { return @{ Lines = @(); Offset = $start } }
        $last = [Array]::LastIndexOf($buf, [byte]10, $n - 1)
        if ($last -lt 0) {
            # No complete line yet. A single line longer than MaxBytes would stall forever, so take the buffer as is.
            if ($n -lt $buf.Length) { return @{ Lines = @(); Offset = $start } }
            $consumed = $n
            $i = $n - 1
            while ($i -gt 0 -and $n - $i -lt 4 -and ($buf[$i] -band 0xC0) -eq 0x80) { $i-- }
            if ($i -gt 0 -and $buf[$i] -ge 0xC0) { $consumed = $i }   # do not cut a multibyte character
        } else { $consumed = $last + 1 }
        $skip = 0
        if ($start -eq 0 -and $consumed -ge 3 -and $buf[0] -eq 0xEF -and $buf[1] -eq 0xBB -and $buf[2] -eq 0xBF) { $skip = 3 }
        $text = [System.Text.Encoding]::UTF8.GetString($buf, $skip, $consumed - $skip)
        $lines = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($raw in $text.Split("`n")) {
            $l = $raw.TrimEnd("`r")
            if ($l.Length -eq 0) { continue }
            $e = ConvertFrom-GIWatcherLogLine -Line $l
            if ($e.step -ceq $StepId) { $lines.Add($e) }
        }
        return @{ Lines = @($lines); Offset = ($start + $consumed) }
    } catch {
        Write-Warning "Could not read watcher log '$Path': $($_.Exception.Message)"
        return $empty
    }
}

function Get-GIWatcherStepLines {
    <#
    .SYNOPSIS
        The last N lines of one step plus the offset to continue polling from.
    .DESCRIPTION
        Offset is the end of the last complete line (not the raw file length), so a line the runner is still writing is
        delivered whole by the next Read-GIWatcherLogSlice call.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$StepId,
        [int]$Last = 200
    )
    $acc = [System.Collections.Generic.List[hashtable]]::new()
    $off = [int64]0
    for ($i = 0; $i -lt 1000; $i++) {
        $s = Read-GIWatcherLogSlice -Path $Path -StepId $StepId -Offset $off -MaxBytes 4194304
        foreach ($l in $s.Lines) { $acc.Add($l) }
        if ($s.Offset -le $off) { break }
        $off = $s.Offset
    }
    $lines = if ($acc.Count -gt $Last) { $acc.GetRange($acc.Count - $Last, $Last) } else { $acc }
    @{ Lines = @($lines); Offset = $off }
}

function Get-GIRunWatchingPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$RunId)
    Join-Path $Config.Paths.State "$RunId.watching"
}

function Set-GIRunWatching {
    <# Touches state/<RunId>.watching (created if missing). Never throws. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Touches a marker file; no ShouldProcess needed.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$RunId
    )
    try {
        if ($RunId -notmatch '^\d{8}-\d{6}$') { throw "invalid run id '$RunId'" }
        $p = Get-GIRunWatchingPath -Config $Config -RunId $RunId
        if (Test-Path -LiteralPath $p -PathType Leaf) { [System.IO.File]::SetLastWriteTimeUtc($p, [datetime]::UtcNow) }
        else { $null = New-Item -ItemType File -Path $p -Force }
    } catch {
        Write-Warning "Could not set the watching marker for run '$RunId': $($_.Exception.Message)"
    }
}

function Get-GIRunWatchingAge {
    <# Seconds since the watching marker was last touched; [double]::MaxValue when there is none. #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$RunId
    )
    try {
        $p = Get-GIRunWatchingPath -Config $Config -RunId $RunId
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return [double]::MaxValue }
        return [Math]::Max(0.0, ([datetime]::UtcNow - (Get-Item -LiteralPath $p).LastWriteTimeUtc).TotalSeconds)
    } catch { return [double]::MaxValue }
}

function Get-GIStepLogResponse {
    <#
    .SYNOPSIS
        Logic of GET /runs/:runId/steps/:stepId/log?offset=N. Returns @{ Status = <http code>; Body = <object to serialize> }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [AllowNull()][AllowEmptyString()][string]$RunId,
        [AllowNull()][AllowEmptyString()][string]$StepId,
        [AllowNull()][AllowEmptyString()][string]$Offset
    )
    if ([string]::IsNullOrEmpty($RunId) -or $RunId -notmatch '^\d{8}-\d{6}\z') { return @{ Status = 400; Body = @{ error = 'Bad run id' } } }
    # Route parameters may arrive still percent-encoded (Pkg%3AHorizon)
    if (-not [string]::IsNullOrEmpty($StepId) -and $StepId.Contains('%')) { try { $StepId = [uri]::UnescapeDataString($StepId) } catch { $StepId = '' } }
    if ([string]::IsNullOrEmpty($StepId) -or $StepId -cnotmatch '^[A-Za-z]+(:[A-Za-z]+)?\z') { return @{ Status = 400; Body = @{ error = 'Bad step id' } } }
    $off = [int64]0
    if (-not [string]::IsNullOrEmpty($Offset)) {
        if ($Offset -notmatch '^\d{1,18}\z' -or -not [int64]::TryParse($Offset, [System.Globalization.NumberStyles]::None, [cultureinfo]::InvariantCulture, [ref]$off)) {
            return @{ Status = 400; Body = @{ error = 'Bad offset' } }
        }
    }
    if (-not (Test-Path -LiteralPath (Get-GIRunPath $Config $RunId) -PathType Leaf)) { return @{ Status = 404; Body = @{ error = 'Run not found' } } }
    $run = Get-GIRun -Config $Config -RunId $RunId
    Set-GIRunWatching -Config $Config -RunId $RunId
    $slice = Read-GIWatcherLogSlice -Path (Get-GIWatcherLogPath -Config $Config -RunId $RunId) -StepId $StepId -Offset $off
    $running = $false
    $maintain = if ($run.PSObject.Properties['stages'] -and $run.stages) { $run.stages.PSObject.Properties['Maintain'] } else { $null }
    if ($maintain -and $maintain.Value -and $maintain.Value.PSObject.Properties['steps']) {
        foreach ($s in @($maintain.Value.steps)) {
            if ($s -and $s.id -ceq $StepId -and [string]$s.status -eq 'Running') { $running = $true }
        }
    }
    @{ Status = 200; Body = [ordered]@{ lines = @($slice.Lines); offset = $slice.Offset; running = $running } }
}

function Get-GIRunStepLogs {
    <# Hashtable step id -> @{ Lines; Offset } (last 200 lines) for the run's Maintain guest-watcher steps; for the run page. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)]$Run
    )
    $res = @{}
    $stages = $Run.PSObject.Properties['stages']
    if (-not $stages -or -not $stages.Value) { return $res }
    $m = $stages.Value.PSObject.Properties['Maintain']
    if (-not $m -or -not $m.Value -or -not $m.Value.PSObject.Properties['steps']) { return $res }
    $path = Get-GIWatcherLogPath -Config $Config -RunId ([string]$Run.runId)
    foreach ($s in @($m.Value.steps)) {
        if ($s -and (Test-GIWatcherStep -Id ([string]$s.id))) { $res[[string]$s.id] = Get-GIWatcherStepLines -Path $path -StepId ([string]$s.id) }
    }
    $res
}
