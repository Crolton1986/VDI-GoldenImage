function Get-GIAuditPath {
    param([Parameter(Mandatory)][hashtable]$Config)
    Join-Path $Config.Paths.State 'audit.jsonl'
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
        [hashtable]$Detail = @{}
    )
    try {
        $entry = [ordered]@{
            at     = (Get-Date).ToString('o')
            user   = $User
            action = $Action
            target = $Target
            detail = $Detail
        }
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
