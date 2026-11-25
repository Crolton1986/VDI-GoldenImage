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
