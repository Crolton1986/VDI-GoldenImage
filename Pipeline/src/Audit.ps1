function Get-GIAuditPath {
    param([Parameter(Mandatory)][hashtable]$Config)
    # One audit log for everything, even when the config is scoped to one image
    $dir = if ($Config.Paths.ContainsKey('RootState') -and $Config.Paths.RootState) { $Config.Paths.RootState } else { $Config.Paths.State }
    Join-Path $dir 'audit.jsonl'
}

function Write-GIAudit {
    <#
    .SYNOPSIS
        Appends one JSON line to state/audit.jsonl. Never throws (warns on failure).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [string]$User = 'unknown',
        [Parameter(Mandatory)][string]$Action,
        [string]$Target = '',
        [hashtable]$Detail = @{},
        [string]$Role = '',
        [string]$Image = '',
        [string]$Result = ''
    )
    try {
        $entry = [ordered]@{
            at     = (Get-Date).ToString('o')
            user   = $User
            action = $Action
            target = $Target
            detail = $Detail
        }
        # Optional fields (role, image, result); image falls back to the config's image, then the detail
        $img = $Image
        if (-not $img -and $Config.ContainsKey('ImageId')) { $img = [string]$Config.ImageId }
        if (-not $img -and $Detail.ContainsKey('image')) { $img = [string]$Detail.image }
        $res = $Result
        if (-not $res -and $Detail.ContainsKey('result')) { $res = [string]$Detail.result }
        if ($Role) { $entry.role = $Role }
        if ($img) { $entry.image = $img }
        if ($res) { $entry.result = $res }
        $line = ($entry | ConvertTo-Json -Depth 10 -Compress) + [Environment]::NewLine
        $path = Get-GIAuditPath -Config $Config
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        [System.IO.File]::AppendAllText($path, $line, [System.Text.UTF8Encoding]::new($false))
    } catch {
        Write-Warning "Could not write audit entry '$Action': $($_.Exception.Message)"
    }
}

function Get-GIAudit {
    <#
    .SYNOPSIS
        Returns audit entries, newest first (at most -Last). Unparseable lines are skipped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [int]$Last = 200
    )
    $path = Get-GIAuditPath -Config $Config
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    $lines = @([System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8) | Where-Object { $_.Trim() })
    $out = [System.Collections.Generic.List[object]]::new()
    for ($i = $lines.Count - 1; $i -ge 0 -and $out.Count -lt $Last; $i--) {
        try {
            $obj = $lines[$i] | ConvertFrom-Json -Depth 10
            if ($obj.at -is [datetime]) { $obj.at = $obj.at.ToString('o') }
            $out.Add($obj)
        } catch {
            Write-Verbose "Skipping unparseable audit line $($i + 1)"
        }
    }
    return @($out)
}

function Get-GIAuditCategory {
    # Filter category of an action: approval, run, poolvm, settings, signin, other
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Action)
    switch -Wildcard ($Action) {
        'approval.*' { 'approval' } 'run.*' { 'run' } 'rollback.*' { 'run' }
        'vm.*' { 'poolvm' } 'pool.*' { 'poolvm' }
        'settings.*' { 'settings' } 'schedule.*' { 'settings' } 'image.*' { 'settings' } 'credential.*' { 'settings' } 'connection.*' { 'settings' } 'setup.*' { 'settings' }
        'auth.signin*' { 'signin' }
        default { 'other' }
    }
}

function Get-GIAuditResult {
    # Result text for the audit table: the stored result, else a sensible default for old entries.
    [CmdletBinding()]
    [OutputType([string])]
    param($Entry)
    $r = if ($Entry.PSObject.Properties['result']) { [string]$Entry.result } else { '' }
    if ($r) { return $r }
    $d = if ($Entry.PSObject.Properties['detail']) { $Entry.detail } else { $null }
    switch -Wildcard ([string]$Entry.action) {
        'auth.denied' { 'Denied' } 'auth.signin.failed' { 'Failed' } 'auth.signin' { 'Allowed' }
        'approval.approve' { 'Approved' } 'run.request' { 'Started' } 'run.start' { 'Started' } 'rollback.request' { 'Started' }
        'settings.*' { 'Saved' } 'credential.*' { 'Saved' } 'image.*' { 'Saved' }
        'connection.test' { if ($d -and $d.PSObject.Properties['ok'] -and -not $d.ok) { 'Failed' } else { 'Passed' } }
        default { 'Done' }
    }
}

function Get-GIAuditDetailText {
    # One line of details. Anything that looks like a secret is dropped, never shown.
    [CmdletBinding()]
    [OutputType([string])]
    param($Entry)
    if (-not $Entry.PSObject.Properties['detail'] -or $null -eq $Entry.detail) { return '' }
    $d = $Entry.detail
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $d.PSObject.Properties) {
        if ($p.Name -match '(?i)pass|secret|token|credential|key$' -or $p.Name -in 'result', 'image') { continue }
        if ($p.Name -eq 'changes') {
            $keys = @(@($p.Value) | ForEach-Object { [string]$_.key } | Where-Object { $_ })
            if ($keys) { $parts.Add("changed $($keys -join ', ')") }
            continue
        }
        $v = $p.Value
        if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) { $v = (@($v) | ForEach-Object { [string]$_ }) -join ', ' }
        $t = [string]$v
        if ($t) { $parts.Add("$($p.Name) $t") }
    }
    $s = $parts -join '; '
    if ($s.Length -gt 220) { $s = $s.Substring(0, 217) + '...' }
    return $s
}

function Search-GIAudit {
    <#
    .SYNOPSIS
      Filtered, paged audit entries (newest first). Filters: Image, Category (approval, run, poolvm, settings, signin),
      User (exact), From and To (dates, inclusive). Returns @{ Entries; Total; Page; PageSize }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [string]$Image, [string]$Category, [string]$User,
        [Nullable[datetime]]$From, [Nullable[datetime]]$To,
        [int]$Page = 1, [int]$PageSize = 50, [switch]$All
    )
    $rows = @(Get-GIAudit -Config $Config -Last 20000)
    if ($Image) { $rows = @($rows | Where-Object { ($_.PSObject.Properties['image'] -and $_.image -ceq $Image) -or ($_.detail -and $_.detail.PSObject.Properties['image'] -and $_.detail.image -ceq $Image) }) }
    if ($Category) { $rows = @($rows | Where-Object { (Get-GIAuditCategory $_.action) -eq $Category }) }
    if ($User) { $rows = @($rows | Where-Object { $_.user -ceq $User }) }
    if ($From) { $rows = @($rows | Where-Object { [datetime]$_.at -ge $From.Date }) }
    if ($To) { $rows = @($rows | Where-Object { [datetime]$_.at -lt $To.Date.AddDays(1) }) }
    $total = $rows.Count
    if ($Page -lt 1) { $Page = 1 }
    $slice = if ($All) { $rows } else { @($rows | Select-Object -Skip (($Page - 1) * $PageSize) -First $PageSize) }
    @{ Entries = $slice; Total = $total; Page = $Page; PageSize = $PageSize }
}

function ConvertTo-GIAuditCsv {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object[]]$Entries = @())
    $q = { param($v) '"' + ([string]$v -replace '"', '""') + '"' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('When,User,Role,Action,Golden image,Details,Result')
    foreach ($e in @($Entries)) {
        $img = if ($e.PSObject.Properties['image']) { [string]$e.image } else { '' }
        $role = if ($e.PSObject.Properties['role']) { [string]$e.role } else { '' }
        $cells = @($e.at, $e.user, $role, $e.action, $img, (Get-GIAuditDetailText $e), (Get-GIAuditResult $e)) | ForEach-Object {
            $t = [string]$_
            # Spreadsheet formula injection guard
            if ($t -match '^[=+\-@]') { $t = "'" + $t }
            & $q $t
        }
        $lines.Add($cells -join ',')
    }
    return ($lines -join "`r`n") + "`r`n"
}

function Write-GISignIn {
    <#
    .SYNOPSIS
      Records auth.signin once per user per 8 hours (the dashboard uses stateless basic authentication, so there is no
      explicit sign-in request; the first authenticated request of a period counts). Returns $true when written.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$User, [string]$Role = '', [int]$WindowHours = 8)
    if ($User -in 'anonymous', 'local-admin', '') { return $false }
    $recent = @(Get-GIAudit -Config $Config -Last 300 | Where-Object { $_.action -eq 'auth.signin' -and $_.user -ceq $User } | Select-Object -First 1)
    if ($recent.Count -and ((Get-Date) - [datetime]$recent[0].at).TotalHours -lt $WindowHours) { return $false }
    Write-GIAudit -Config $Config -User $User -Role $Role -Action 'auth.signin' -Target '' -Detail @{} -Result 'Allowed'
    return $true
}
