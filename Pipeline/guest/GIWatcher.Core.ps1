<#
.SYNOPSIS
  Pure helpers of the guest watcher (Windows PowerShell 5.1 compatible).
.DESCRIPTION
  Dot-sourced by Invoke-GIWatcher.ps1, Invoke-GIFixRunner.ps1 and Pester. Defines functions only: no side effects at
  dot-source time and no process starts, so every function here can be tested on its own.
  The spec is Pipeline/docs/CONTRACT.md, section "Guest watcher".
#>

#----- Names and paths -----

function Get-GIStepFileId {
    <#
    .SYNOPSIS  File-name form of a step id: 'Pkg:Horizon' -> 'Pkg_Horizon'.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Id)
    return ($Id -replace ':', '_')
}

function Get-GIWatcherPaths {
    <#
    .SYNOPSIS  All well-known paths under the guest work dir <W>.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $WorkDir)
    return @{
        WorkDir     = $WorkDir
        Plan        = Join-Path $WorkDir 'plan.json'
        Watcher     = Join-Path $WorkDir 'watcher.json'
        Log         = Join-Path $WorkDir 'watcher.log'
        Steps       = Join-Path $WorkDir 'steps'
        Fixes       = Join-Path $WorkDir 'fixes'
        FixesRun    = Join-Path $WorkDir 'fixes-run'
    }
}

function ConvertTo-GIHashtable {
    <#
    .SYNOPSIS  Recursively turns ConvertFrom-Json objects into hashtables/arrays so they can be edited in place.
    #>
    [CmdletBinding()]
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string] -or $InputObject -is [ValueType]) { return $InputObject }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in $InputObject.Keys) { $h[[string]$k] = ConvertTo-GIHashtable -InputObject $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $list = @()
        foreach ($i in $InputObject) { $list += , (ConvertTo-GIHashtable -InputObject $i) }
        return , $list
    }
    $h = [ordered]@{}
    foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-GIHashtable -InputObject $p.Value }
    return $h
}

#----- Atomic JSON, log -----

function Write-GIWatcherJson {
    <#
    .SYNOPSIS  Atomic JSON write: <Path>.tmp then File.Replace/File.Move, retried because a reader may hold the file.
    .DESCRIPTION
      Move-Item -Force is avoided on purpose: Windows PowerShell 5.1 deletes the target first, which leaves a window
      where the host sees no file.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] $InputObject)
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = ConvertTo-Json -InputObject $InputObject -Depth 8
    $tmp = "$Path.tmp"
    $utf8 = New-Object System.Text.UTF8Encoding $false
    for ($i = 1; $i -le 10; $i++) {
        try {
            [System.IO.File]::WriteAllText($tmp, $json, $utf8)
            if (Test-Path -LiteralPath $Path) { [System.IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [System.IO.File]::Move($tmp, $Path) }
            return
        } catch [System.IO.IOException] {
            if ($i -eq 10) { throw }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Read-GIWatcherJson {
    <#
    .SYNOPSIS  Reads a JSON file; missing, empty or unparsable content returns $null. Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        # Share Delete too, so the writer's File.Replace is not blocked by this read
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        try {
            $sr = New-Object System.IO.StreamReader($fs, (New-Object System.Text.UTF8Encoding $false), $true)
            $text = $sr.ReadToEnd()
        } finally { $fs.Dispose() }
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Write-GIWatcherLog {
    <#
    .SYNOPSIS  Appends one line to watcher.log: <o timestamp> TAB LEVEL TAB stepId-or-dash TAB message, CRLF, UTF-8 no BOM.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OUT')] [string] $Level = 'INFO',
        [string] $StepId,
        [string] $Message
    )
    $clean = ([string]$Message) -replace "[`t`r`n]+", ' '
    $step = if ($StepId) { ($StepId -replace "[`t`r`n]+", ' ') } else { '-' }
    $line = '{0}{1}{2}{1}{3}{1}{4}{5}' -f (Get-Date).ToString('o'), "`t", $Level, $step, $clean, "`r`n"
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    for ($i = 1; $i -le 5; $i++) {
        try { [System.IO.File]::AppendAllText($Path, $line, $utf8); return }
        catch [System.IO.IOException] { if ($i -eq 5) { throw }; Start-Sleep -Milliseconds 50 }
    }
}

function Get-GIOutEncoding {
    <#
    .SYNOPSIS  Encoding of a child's redirected output: the OEM code page on Windows (what a console child writes), UTF-8 elsewhere.
    #>
    [CmdletBinding()]
    param()
    try {
        if ($env:OS -eq 'Windows_NT') {
            $cp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
            if ($cp -gt 0) { return [System.Text.Encoding]::GetEncoding($cp) }
        }
    } catch { Write-Verbose "OEM code page lookup failed: $($_.Exception.Message)" }
    return (New-Object System.Text.UTF8Encoding $false)
}

function Read-GIOutTail {
    <#
    .SYNOPSIS  New complete lines of an output file since a byte offset; a trailing partial line waits for the next call unless -Final.
    .OUTPUTS   @{ Lines = string[]; NextOffset = long }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path, [long] $Offset = 0, [switch] $Final)
    $res = @{ Lines = @(); NextOffset = $Offset }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $res }
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        try {
            if ($fs.Length -lt $Offset) { $Offset = 0 }
            $count = [int]($fs.Length - $Offset)
            if ($count -le 0) { return $res }
            $null = $fs.Seek($Offset, [System.IO.SeekOrigin]::Begin)
            $buf = New-Object byte[] $count
            $read = $fs.Read($buf, 0, $count)
        } finally { $fs.Dispose() }
        $end = $read
        if (-not $Final) {
            $end = [Array]::LastIndexOf($buf, [byte]10, $read - 1) + 1
            if ($end -le 0) { return $res }
        }
        $text = (Get-GIOutEncoding).GetString($buf, 0, $end)
        $lines = @($text -split "\r?\n" | Where-Object { $_ -ne '' })
        $res.Lines = $lines
        $res.NextOffset = $Offset + $end
    } catch { Write-Verbose "Tail failed: $($_.Exception.Message)" }
    return $res
}

#----- Fix catalog -----

function Test-GIFixMetadata {
    <#
    .SYNOPSIS  Validates a $GIFix hashtable against the contract; returns error strings (empty = valid).
    #>
    [CmdletBinding()]
    param($Meta)
    $errs = New-Object System.Collections.Generic.List[string]
    if ($Meta -isnot [System.Collections.IDictionary]) { return @('$GIFix is not a hashtable') }
    $isInt = { param($v) $v -is [int] -or $v -is [long] }
    if (-not ($Meta.Contains('Id') -and $Meta.Id -is [string] -and $Meta.Id -match '^[A-Za-z][A-Za-z0-9]+$')) { $errs.Add("Id must match ^[A-Za-z][A-Za-z0-9]+`$") }
    if (-not ($Meta.Contains('Description') -and $Meta.Description -is [string] -and $Meta.Description.Trim())) { $errs.Add('Description must be a non-empty string') }
    if (-not ($Meta.Contains('Priority') -and (& $isInt $Meta.Priority) -and $Meta.Priority -ge 0)) { $errs.Add('Priority must be an integer >= 0') }
    $actions = @($Meta['Actions'])
    if (-not $Meta.Contains('Actions') -or $actions.Count -eq 0 -or @($actions | Where-Object { $_ -isnot [string] -or -not $_ }).Count -gt 0) { $errs.Add('Actions must be a non-empty array of strings') }
    if (-not ($Meta.Contains('MaxAttempts') -and (& $isInt $Meta.MaxAttempts) -and $Meta.MaxAttempts -ge 1 -and $Meta.MaxAttempts -le 5)) { $errs.Add('MaxAttempts must be an integer 1..5') }
    if (-not ($Meta.Contains('RebootFromAttempt') -and (& $isInt $Meta.RebootFromAttempt) -and $Meta.RebootFromAttempt -ge 0)) { $errs.Add('RebootFromAttempt must be an integer >= 0') }
    $m = $Meta['Match']
    if ($m -isnot [System.Collections.IDictionary]) {
        $errs.Add('Match must be a hashtable')
    } else {
        $pats = @($m['Patterns'])
        if (-not $m.Contains('Patterns') -or $pats.Count -eq 0 -or @($pats | Where-Object { $_ -isnot [string] -or -not $_ }).Count -gt 0) {
            $errs.Add('Match.Patterns must be a non-empty array of strings')
        } else {
            foreach ($p in $pats) {
                try { $null = [regex]::new($p) } catch { $errs.Add("Match.Patterns has an invalid regex '$p'") }
            }
        }
        if ($m.Contains('ExitCodes') -and @($m.ExitCodes | Where-Object { -not (& $isInt $_) }).Count -gt 0) { $errs.Add('Match.ExitCodes must be integers') }
        if ($m.Contains('Sources')) {
            $bad = @(@($m.Sources) | Where-Object { $_ -notin 'Errors', 'Output', 'Log' })
            if ($bad.Count -gt 0) { $errs.Add("Match.Sources has unknown source(s): $($bad -join ', ')") }
        }
    }
    return @($errs)
}

function Read-GIFixCatalog {
    <#
    .SYNOPSIS  Loads fix metadata from a folder without executing any fix file.
    .DESCRIPTION
      Each file is parsed with the PowerShell parser; the top-level `$GIFix = ...` assignment is evaluated with
      SafeGetValue (literals, arrays, hashtables only, so code in the hashtable makes the file invalid) and the file
      must define `function Invoke-GIFix`. Invalid files are returned with Valid = $false and are never selected.
    .OUTPUTS   @{ Id; File; Valid; Errors; Meta } sorted by Priority, then file name (ordinal); invalid ones last.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return @() }
    $items = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $Path -Filter '*.ps1' -File)) {
        $errs = New-Object System.Collections.Generic.List[string]
        $meta = $null
        try {
            $tokens = $null; $perr = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$perr)
            if ($perr -and $perr.Count -gt 0) { $errs.Add("Syntax error: $($perr[0].Message)") }
            else {
                $assign = $null
                foreach ($st in $ast.EndBlock.Statements) {
                    if ($st -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $st.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                        $st.Left.VariablePath.UserPath -eq 'GIFix') { $assign = $st; break }
                }
                if (-not $assign) { $errs.Add('No top-level $GIFix assignment') }
                else {
                    try {
                        $expr = $assign.Right
                        if ($expr -is [System.Management.Automation.Language.CommandExpressionAst]) { $expr = $expr.Expression }
                        $meta = $expr.SafeGetValue()
                    } catch { $errs.Add("`$GIFix is not a plain literal: $($_.Exception.Message)") }
                }
                $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-GIFix' }, $true)
                if (@($fn).Count -eq 0) { $errs.Add('Missing function Invoke-GIFix') }
            }
            if ($meta) {
                foreach ($e in @(Test-GIFixMetadata -Meta $meta)) { $errs.Add($e) }
                if ($meta -is [System.Collections.IDictionary] -and $meta['Id'] -and $meta['Id'] -cne $f.BaseName) { $errs.Add("Id '$($meta['Id'])' does not match file name '$($f.BaseName)'") }
            }
        } catch { $errs.Add("Unreadable: $($_.Exception.Message)") }
        $valid = ($errs.Count -eq 0)
        $items += [pscustomobject]@{ Id = $f.BaseName; File = $f.FullName; Valid = $valid; Errors = @($errs); Meta = $(if ($valid) { $meta } else { $null }) }
    }
    if ($items.Count -le 1) { return @($items) }
    # Ordinal sort key: valid fixes by Priority then name, invalid ones after them. Insertion sort keeps
    # the comparison ordinal (Sort-Object would be culture-aware) and the lists are tiny.
    $keyed = @($items | ForEach-Object {
        $k = if ($_.Valid) { '0{0:D10}|{1}' -f [long]$_.Meta.Priority, $_.Id } else { "1|$($_.Id)" }
        [pscustomobject]@{ Key = $k; Item = $_ }
    })
    for ($i = 1; $i -lt $keyed.Count; $i++) {
        $cur = $keyed[$i]; $j = $i - 1
        while ($j -ge 0 -and [string]::CompareOrdinal($keyed[$j].Key, $cur.Key) -gt 0) { $keyed[$j + 1] = $keyed[$j]; $j-- }
        $keyed[$j + 1] = $cur
    }
    return @($keyed | ForEach-Object { $_.Item })
}

function Select-GIFix {
    <#
    .SYNOPSIS  Picks the first catalog fix that matches the failure and still has attempts left for this step.
    .PARAMETER Applied  The step's fixApplied entries so far (their count per id is the fix attempts used).
    .OUTPUTS   @{ Fix; FixAttempt; RebootBeforeRetry } or $null
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Catalog,
        [Parameter(Mandatory)] [string] $Action,
        [int] $ExitCode,
        $ErrorText,
        [AllowNull()] [object[]] $Applied = @()
    )
    foreach ($entry in @($Catalog)) {
        if (-not $entry.Valid) { continue }
        $meta = $entry.Meta
        if (@($meta.Actions) -notcontains '*' -and @($meta.Actions) -notcontains $Action) { continue }
        $codes = @()
        if ($meta.Match.Contains('ExitCodes')) { $codes = @($meta.Match.ExitCodes) }
        if ($codes.Count -eq 0) { if ($ExitCode -eq 0) { continue } } elseif ($codes -notcontains $ExitCode) { continue }
        $sources = if ($meta.Match.Contains('Sources') -and @($meta.Match.Sources).Count -gt 0) { @($meta.Match.Sources) } else { @('Errors', 'Output', 'Log') }
        $hit = $false
        foreach ($s in $sources) {
            $text = ''
            if ($ErrorText -is [System.Collections.IDictionary]) { if ($ErrorText.Contains($s)) { $text = [string]$ErrorText[$s] } }
            elseif ($ErrorText -and $ErrorText.PSObject.Properties[$s]) { $text = [string]$ErrorText.$s }
            if (-not $text) { continue }
            foreach ($p in @($meta.Match.Patterns)) {
                if ([regex]::IsMatch($text, $p, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) { $hit = $true; break }
            }
            if ($hit) { break }
        }
        if (-not $hit) { continue }
        $used = @(@($Applied) | Where-Object { $_ -and $_.id -eq $entry.Id }).Count
        if ($used -ge [int]$meta.MaxAttempts) { continue }
        $fixAttempt = $used + 1
        $rfa = [int]$meta.RebootFromAttempt
        return @{ Fix = $entry; FixAttempt = $fixAttempt; RebootBeforeRetry = ($rfa -gt 0 -and $fixAttempt -ge $rfa) }
    }
    return $null
}

#----- Plan and step state -----

function Test-GIWatcherPlan {
    <#
    .SYNOPSIS  Validates plan.json content; returns error strings (empty = valid).
    #>
    [CmdletBinding()]
    param($Plan)
    $errs = New-Object System.Collections.Generic.List[string]
    if (-not $Plan) { return @('plan.json is missing or unreadable') }
    foreach ($k in 'runId', 'attemptId', 'launchId', 'scriptPath', 'workDir') {
        if (-not $Plan.PSObject.Properties[$k] -or -not $Plan.$k) { $errs.Add("Missing '$k'") }
    }
    if (-not $Plan.PSObject.Properties['steps']) { $errs.Add("Missing 'steps'") }
    foreach ($s in @($Plan.steps)) {
        if (-not $s -or $s.id -notmatch '^[A-Za-z]+(:[A-Za-z0-9]+)?$') { $errs.Add("Bad step id '$($s.id)'"); continue }
        if ($s.kind -eq 'Action') { if ($s.action -notmatch '^[A-Za-z0-9]+$') { $errs.Add("Step '$($s.id)': bad action") } }
        elseif ($s.kind -ne 'WindowsUpdate') { $errs.Add("Step '$($s.id)': unknown kind '$($s.kind)'") }
    }
    return @($errs)
}

function Get-GIWatcherSetting {
    <#
    .SYNOPSIS  A plan.settings value with the contract default when absent.
    #>
    [CmdletBinding()]
    param($Plan, [Parameter(Mandatory)] [string] $Name)
    $defaults = @{ heartbeatSec = 15; maxStepAttempts = 4; fixTimeoutSec = 600 }
    if ($Plan -and $Plan.PSObject.Properties['settings'] -and $Plan.settings -and $Plan.settings.PSObject.Properties[$Name] -and $null -ne $Plan.settings.$Name) {
        $v = [int]$Plan.settings.$Name
        if ($v -gt 0) { return $v }
    }
    return $defaults[$Name]
}

function Get-GIStepStartDecision {
    <#
    .SYNOPSIS  What to do with a plan step on (re)launch, from its existing status file.
    .OUTPUTS   'Skip' | 'Reset' | 'Resume' | 'AfterReboot' | 'Stop'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Plan, $StepFile)
    if (-not $StepFile) { return 'Reset' }
    if ($StepFile.runId -eq $Plan.runId -and $StepFile.status -eq 'Succeeded') { return 'Skip' }
    if ($StepFile.attemptId -ne $Plan.attemptId) { return 'Reset' }
    switch ($StepFile.status) {
        'Running'        { return 'Resume' }
        'Fixing'         { return 'Resume' }
        'Pending'        { return 'Resume' }
        'RebootRequired' { return 'AfterReboot' }
        'Failed'         { return 'Stop' }
        default          { return 'Reset' }
    }
}

function Test-GIAttemptAllowed {
    <#
    .SYNOPSIS  $true while one more attempt stays within maxStepAttempts.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $StepFile, [Parameter(Mandatory)] [int] $MaxAttempts)
    return (([int]$StepFile.attempt + 1) -le $MaxAttempts)
}

function Get-GIAttemptOutcome {
    <#
    .SYNOPSIS  Evaluates one finished child process (contract step 6).
    .PARAMETER Kind    'Action' or 'WindowsUpdate'
    .PARAMETER Result  The parsed result file, or $null when it is missing.
    .PARAMETER Pass    WindowsUpdate: number of this pass (default 1).
    .OUTPUTS
      @{ Status = Succeeded|Failed|RebootRequired|NextPass; Message; Data; RebootAfter; PassEntry }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Action', 'WindowsUpdate')] [string] $Kind,
        [int] $ExitCode,
        $Result,
        [int] $MaxPasses = 5,
        [int] $Pass = 1
    )
    $out = @{ Status = 'Failed'; Message = ''; Data = @{}; RebootAfter = $false; PassEntry = $null }
    $prop = { param($o, $n) if ($o -and $o.PSObject.Properties[$n]) { $o.$n } else { $null } }

    if ($Kind -eq 'Action') {
        if (-not $Result) { $out.Message = "No result file (exit code $ExitCode)"; return $out }
        $ok = ($ExitCode -eq 0 -and (& $prop $Result 'success') -eq $true)
        if (-not $ok) { $out.Message = "Action failed (exit code $ExitCode)"; return $out }
        $reboot = [bool](& $prop $Result 'rebootRequired')
        $versions = & $prop $Result 'versions'
        $action = [string](& $prop $Result 'action')
        $ver = if ($versions -and $action -and $versions.PSObject.Properties[$action]) { [string]$versions.$action } else { '' }
        $out.Status = 'Succeeded'
        $out.Message = if ($ver) { "Installed version $ver" } else { 'Done' }
        $out.Data = @{ versions = $versions; rebootRequired = $reboot }
        $out.RebootAfter = $reboot
        return $out
    }

    # WindowsUpdate
    if (-not $Result) { $out.Message = "No result file (exit code $ExitCode)"; return $out }
    $err = & $prop $Result 'error'
    if ($err) { $out.Message = "Windows Update pass $Pass error: $err"; return $out }
    $found = [int](& $prop $Result 'found')
    $reboot = [bool](& $prop $Result 'rebootRequired')
    $out.PassEntry = @{ pass = $Pass; found = $found; installed = [int](& $prop $Result 'installed'); failed = [int](& $prop $Result 'failed'); reboot = $reboot }
    $out.Data = @{ pass = $Pass }
    if ($reboot) {
        $out.Status = 'RebootRequired'
        $out.Message = "Windows Update pass ${Pass}: $($out.PassEntry.installed) installed, reboot requested"
    } elseif ($found -eq 0 -or $Pass -ge $MaxPasses) {
        $out.Status = 'Succeeded'
        $out.Message = "Windows Update finished after $Pass pass(es)."
        if ($found -gt 0) { $out.Message += " Updates still pending after $MaxPasses passes." }
    } else {
        $out.Status = 'NextPass'
        $out.Message = "Windows Update pass ${Pass}: $($out.PassEntry.installed) installed, $found found"
    }
    return $out
}

function Get-GIStepErrorText {
    <#
    .SYNOPSIS  Error text of a failed attempt: result errors, tail of the out file, tail of the newest install log.
    .OUTPUTS   @{ Errors; Output; Log } (strings)
    #>
    [CmdletBinding()]
    param($Result, [string] $OutFile, [string] $LogDir, $Since)
    $errors = ''
    if ($Result) {
        if ($Result.PSObject.Properties['errors'] -and @($Result.errors).Count -gt 0) { $errors = (@($Result.errors) | Where-Object { $_ }) -join '; ' }
        elseif ($Result.PSObject.Properties['error'] -and $Result.error) { $errors = [string]$Result.error }
    }
    $output = ''
    if ($OutFile -and (Test-Path -LiteralPath $OutFile -PathType Leaf)) {
        try { $output = (@(Get-Content -LiteralPath $OutFile -Tail 200 -Encoding UTF8) -join "`n") } catch { $output = '' }
    }
    $log = ''
    if ($LogDir -and (Test-Path -LiteralPath $LogDir -PathType Container)) {
        try {
            $files = @(Get-ChildItem -LiteralPath $LogDir -Filter '*.log' -File -ErrorAction SilentlyContinue)
            if ($Since) { $s = [datetime]$Since; $files = @($files | Where-Object { $_.LastWriteTime -ge $s }) }
            $newest = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($newest) { $log = (@(Get-Content -LiteralPath $newest.FullName -Tail 200 -Encoding UTF8) -join "`n") }
        } catch { $log = '' }
    }
    return @{ Errors = $errors; Output = $output; Log = $log }
}

function Get-GIOriginalError {
    <#
    .SYNOPSIS  The headline error of a failed attempt: Errors, else the last non-empty output line, else 'exit code <n>'.
    #>
    [CmdletBinding()]
    param($ErrorText, [int] $ExitCode)
    if ($ErrorText -and $ErrorText['Errors']) { return [string]$ErrorText['Errors'] }
    if ($ErrorText -and $ErrorText['Output']) {
        $last = @(([string]$ErrorText['Output']) -split "\r?\n" | Where-Object { $_.Trim() }) | Select-Object -Last 1
        if ($last) { return $last.Trim() }
    }
    return "exit code $ExitCode"
}

function New-GIStepArgumentList {
    <#
    .SYNOPSIS  powershell.exe arguments for one attempt of a plan step (Action: the in-guest script; WindowsUpdate: one WU pass).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Step, [Parameter(Mandatory)] $Plan,
        [Parameter(Mandatory)] [string] $ResultFile, [Parameter(Mandatory)] [string] $ScriptDir
    )
    $base = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File')
    if ($Step.kind -eq 'WindowsUpdate') {
        return @($base + ('"{0}"' -f (Join-Path $ScriptDir 'Invoke-GIWindowsUpdate.ps1')) + '-ResultFile' + ('"{0}"' -f $ResultFile))
    }
    return @($base + ('"{0}"' -f $Plan.scriptPath) + '-Action' + [string]$Step.action + '-Unattended' + '-ResultFile' + ('"{0}"' -f $ResultFile))
}

function Get-GIParentPidChain {
    <#
    .SYNOPSIS  The given pid plus its parent chain (so a fix can never stop the watcher's own process tree).
    #>
    [CmdletBinding()]
    param([int] $ProcessId = $PID)
    $chain = @($ProcessId)
    try {
        $cur = $ProcessId
        for ($i = 0; $i -lt 12; $i++) {
            $p = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$cur" -ErrorAction Stop
            if (-not $p -or -not $p.ParentProcessId -or $chain -contains [int]$p.ParentProcessId) { break }
            $chain += [int]$p.ParentProcessId
            $cur = [int]$p.ParentProcessId
        }
    } catch { Write-Verbose "Parent chain stopped: $($_.Exception.Message)" }
    return $chain
}

function Test-GIProcessStoppable {
    <#
    .SYNOPSIS  Allowlist for fixes: msiexec by name, or an image under InstallDir; never a protected pid.
    .PARAMETER InstallDirOnly  Only the InstallDir rule applies (msiexec is not stoppable by name).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $ProcessId, [string] $Name, [string] $Path, [string] $InstallDir,
        [int[]] $ProtectedPids = @(), [switch] $InstallDirOnly
    )
    if ($ProtectedPids -contains $ProcessId) { return $false }
    if (-not $InstallDirOnly -and $Name -and ($Name -replace '\.exe$', '') -ieq 'msiexec') { return $true }
    if ($Path -and $InstallDir) {
        $root = $InstallDir.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        $alt = $InstallDir.TrimEnd('\', '/') + '\'
        if ($Path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith($alt, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}
