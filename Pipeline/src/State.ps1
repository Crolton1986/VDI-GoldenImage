$script:GIStageOrder = @('Preflight', 'Maintain', 'Snapshot', 'TestPush', 'Validate', 'Approval', 'Promote', 'PostCheck')

function ConvertTo-GIDateString {
    # ConvertFrom-Json turns ISO strings into [datetime] on pwsh 7.4; keep them as strings.
    param($InputObject)
    if ($InputObject -is [datetime]) { return $InputObject.ToString('o') }
    if ($InputObject -is [pscustomobject]) {
        foreach ($p in @($InputObject.PSObject.Properties)) {
            $InputObject.($p.Name) = ConvertTo-GIDateString $p.Value
        }
        return $InputObject
    }
    if ($InputObject -is [array]) {
        $arr = @(foreach ($e in $InputObject) { ConvertTo-GIDateString $e })
        return , $arr
    }
    return $InputObject
}

function Read-GIJsonFile {
    param([Parameter(Mandatory)][string]$Path)
    $obj = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 10
    ConvertTo-GIDateString $obj
}

function Write-GIJsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$InputObject
    )
    # Unique temp name: two writers (web server + setup runner) never share a temp file
    $tmp = "$Path.$PID.$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"
    $InputObject | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tmp -Encoding UTF8
    # On Windows the replace fails while another process has the file open for reading (the setup page
    # polls it every 2 s); retry briefly instead of losing the write
    for ($i = 1; ; $i++) {
        try {
            Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
            return
        } catch {
            if ($i -ge 10) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; throw }
            Start-Sleep -Milliseconds (100 * $i)
        }
    }
}

function Get-GIRunPath {
    param([hashtable]$Config, [string]$RunId)
    Join-Path $Config.Paths.State "$RunId.json"
}

function New-GIRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [string]$RunId
    )
    $now = Get-Date
    if (-not $RunId) { $RunId = $now.ToString('yyyyMMdd-HHmmss') }
    $stages = [ordered]@{}
    foreach ($s in $script:GIStageOrder) {
        $stages[$s] = [ordered]@{ status = 'Pending'; startedAt = $null; endedAt = $null; message = ''; data = @{} }
    }
    $table = [ordered]@{
        schemaVersion  = 1
        runId          = $RunId
        imageId        = $(if ($Config.ContainsKey('ImageId')) { [string]$Config.ImageId } else { '' })
        goldenVm       = $Config.GoldenImage.VmName
        createdAt      = $now.ToString('o')
        updatedAt      = $now.ToString('o')
        status         = 'Running'
        currentStage   = $null
        progress       = ''
        stages         = $stages
        safetySnapshot = $null
        retention      = $null
        snapshot       = $null
        validation     = [ordered]@{ passed = $false; checks = @() }
        approval       = [ordered]@{ decision = $null; by = $null; at = $null; startTime = $null; comment = $null }
        promotion      = [ordered]@{ pools = @() }
        error          = $null
    }
    # Round-trip so the object shape matches runs loaded from disk
    $run = ConvertTo-GIDateString ($table | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 10)
    Save-GIRun -Config $Config -Run $run
    return $run
}

function Get-GIRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$RunId
    )
    $path = Get-GIRunPath $Config $RunId
    if (-not (Test-Path -LiteralPath $path)) { throw "Run '$RunId' not found at $path" }
    Read-GIJsonFile -Path $path
}

function Get-GIRunList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [int]$Last
    )
    $files = @(Get-ChildItem -LiteralPath $Config.Paths.State -Filter '*.json' -File |
            Where-Object { $_.BaseName -match '^\d{8}-\d{6}' } |
            Sort-Object -Property BaseName -Descending)
    if ($PSBoundParameters.ContainsKey('Last')) { $files = @($files | Select-Object -First $Last) }
    foreach ($f in $files) { Read-GIJsonFile -Path $f.FullName }
}

function Save-GIRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)]$Run
    )
    $Run.updatedAt = (Get-Date).ToString('o')
    Write-GIJsonAtomic -Path (Get-GIRunPath $Config $Run.runId) -InputObject $Run
}

function Set-GIStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][ValidateSet('Preflight', 'Maintain', 'Snapshot', 'TestPush', 'Validate', 'Approval', 'Promote', 'PostCheck')][string]$Stage,
        [Parameter(Mandatory)][ValidateSet('Pending', 'Running', 'Succeeded', 'Failed', 'Skipped')][string]$Status,
        [string]$Message,
        [hashtable]$Data
    )
    $st = $Run.stages.$Stage
    $now = (Get-Date).ToString('o')
    $st.status = $Status
    switch ($Status) {
        'Pending' { $st.startedAt = $null; $st.endedAt = $null }
        'Running' { $st.startedAt = $now; $st.endedAt = $null }
        default   { $st.endedAt = $now }
    }
    if ($PSBoundParameters.ContainsKey('Message')) { $st.message = $Message }
    if ($Data) {
        foreach ($k in $Data.Keys) {
            Add-Member -InputObject $st.data -NotePropertyName $k -NotePropertyValue $Data[$k] -Force
        }
    }
    $Run.currentStage = $Stage
    if ($Status -eq 'Failed') {
        $Run.status = 'Failed'
        $Run.error = $Message
    }
    Save-GIRun -Config $Config -Run $Run
}

function Set-GIProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message
    )
    $Run.progress = $Message
    # Inside Maintain, show the detail on the running step too (e.g. Windows Update pass 2 of 5)
    if ($Message) {
        $running = @(Get-GIStepList -Run $Run) | Where-Object { $_.status -eq 'Running' } | Select-Object -First 1
        if ($running) { $running.message = $Message }
    }
    Save-GIRun -Config $Config -Run $Run
}

#----- Maintain sub-steps (run.stages.Maintain.steps) -----

function Get-GIStepList {
    # The Maintain step array of a run, or @() when the run has none yet.
    param([Parameter(Mandatory)]$Run)
    $st = $Run.stages.Maintain
    # Unrolled on output: callers wrap with @()
    if ($null -eq $st -or -not $st.PSObject.Properties['steps'] -or $null -eq $st.steps) { return }
    $st.steps
}

function Get-GIStep {
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][string]$Id)
    @(Get-GIStepList -Run $Run) | Where-Object { $_.id -ceq $Id } | Select-Object -First 1
}

function Initialize-GIMaintainSteps {
    <#
    .SYNOPSIS
        Builds run.stages.Maintain.steps from the step plan for this config, keeping earlier progress when resuming.
    .DESCRIPTION
        Resume happens when -ResumeFrom is given, or when the previous attempt left a step Failed or Running.
        Then resumable steps (safety snapshot, updates, packages) that Succeeded before the resume point keep
        their result and are skipped; every other step goes back to Pending. A previous attempt that finished
        cleanly, or no previous attempt, starts fresh. Steps that don't apply to this config are Skipped.
        Returns the step id work starts from ('' when fresh).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][object[]]$Plan,
        [AllowEmptyString()][string]$ResumeFrom = ''
    )
    $prev = @(Get-GIStepList -Run $Run)
    $byId = @{}
    foreach ($p in $prev) { $byId[[string]$p.id] = $p }
    $interrupted = @($prev | Where-Object { $_.status -in 'Failed', 'Running' }).Count -gt 0
    $resume = [bool]$ResumeFrom -or $interrupted
    $planIds = @($Plan | ForEach-Object { $_.Id })
    $cut = if ($ResumeFrom) { [array]::IndexOf($planIds, $ResumeFrom) } else { $planIds.Count }
    if ($ResumeFrom -and $cut -lt 0) { throw "Maintain has no step '$ResumeFrom'. Steps: $($planIds -join ', ')." }

    $steps = for ($i = 0; $i -lt $Plan.Count; $i++) {
        $p = $Plan[$i]
        $old = $byId[$p.Id]
        $row = [ordered]@{ id = $p.Id; label = $p.Label; resumable = [bool]$p.Resumable; status = 'Pending'; startedAt = $null; endedAt = $null; message = '' }
        if (-not $p.Applies) {
            $row.status = 'Skipped'; $row.message = [string]$p.SkipReason
        } elseif ($resume -and $p.Resumable -and $i -lt $cut -and $old -and $old.status -eq 'Succeeded') {
            $row.status = 'Succeeded'; $row.startedAt = $old.startedAt; $row.endedAt = $old.endedAt
            $row.message = ([string]$old.message -replace ' \(earlier attempt\)$', '') + ' (earlier attempt)'
            if ($old.PSObject.Properties['attempt']) { $row.attempt = $old.attempt }
            if ($old.PSObject.Properties['fixes']) { $row.fixes = $old.fixes }
        }
        [pscustomobject]$row
    }
    Add-Member -InputObject $Run.stages.Maintain -NotePropertyName steps -NotePropertyValue @($steps) -Force
    Save-GIRun -Config $Config -Run $Run
    if (-not $resume) { return '' }
    $first = @($steps | Where-Object { $_.status -notin 'Succeeded', 'Skipped' }) | Select-Object -First 1
    if ($first) { return [string]$first.id } else { return '' }
}

function Set-GIStep {
    <#
    .SYNOPSIS
        Updates one Maintain step. Without -Status only the message changes (live progress while a step runs).
        Also mirrors the step into run.progress so the existing progress line keeps working.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][string]$Id,
        [ValidateSet('Pending', 'Running', 'Succeeded', 'Failed', 'Skipped')][string]$Status,
        [AllowEmptyString()][string]$Message,
        [int]$Attempt,
        [AllowEmptyCollection()][object[]]$Fixes
    )
    $step = Get-GIStep -Run $Run -Id $Id
    if (-not $step) { throw "Unknown Maintain step '$Id'." }
    $now = (Get-Date).ToString('o')
    if ($Status) {
        $step.status = $Status
        switch ($Status) {
            'Pending' { $step.startedAt = $null; $step.endedAt = $null }
            'Running' { $step.startedAt = $now; $step.endedAt = $null }
            default   { $step.endedAt = $now }
        }
    }
    if ($PSBoundParameters.ContainsKey('Message')) { $step.message = $Message }
    if ($PSBoundParameters.ContainsKey('Attempt')) { Add-Member -InputObject $step -NotePropertyName attempt -NotePropertyValue $Attempt -Force }
    if ($PSBoundParameters.ContainsKey('Fixes')) { Add-Member -InputObject $step -NotePropertyName fixes -NotePropertyValue @($Fixes) -Force }
    $Run.progress = if ($step.message -and $step.status -eq 'Running') { "$($step.label): $($step.message)" } else { [string]$step.label }
    Save-GIRun -Config $Config -Run $Run
}

function Get-GILastKnownGood {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)
    $path = Join-Path $Config.Paths.State 'lastKnownGood.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    Read-GIJsonFile -Path $path
}

function Set-GILastKnownGood {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)]$Run
    )
    $lkg = [ordered]@{
        goldenVm     = $Run.goldenVm
        snapshotId   = $Run.snapshot.id
        snapshotName = $Run.snapshot.name
        runId        = $Run.runId
        promotedAt   = (Get-Date).ToString('o')
    }
    Write-GIJsonAtomic -Path (Join-Path $Config.Paths.State 'lastKnownGood.json') -InputObject $lkg
}
