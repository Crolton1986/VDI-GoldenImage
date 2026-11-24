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
    $tmp = "$Path.tmp"
    $InputObject | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
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
        goldenVm       = $Config.GoldenImage.VmName
        createdAt      = $now.ToString('o')
        updatedAt      = $now.ToString('o')
        status         = 'Running'
        currentStage   = $null
        progress       = ''
        stages         = $stages
        safetySnapshot = $null
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
        [Parameter(Mandatory)][string]$Message
    )
    $Run.progress = $Message
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
