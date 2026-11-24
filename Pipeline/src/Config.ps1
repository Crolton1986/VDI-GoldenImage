function Get-GIConfig {
    <#
    .SYNOPSIS
        Loads, resolves and validates the pipeline configuration.
    #>
    [CmdletBinding()]
    param(
        [string]$Path
    )

    $moduleRoot = Split-Path -Parent $PSScriptRoot
    if (-not $Path) { $Path = Join-Path $moduleRoot 'pipeline.config.psd1' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Config file not found: $Path"
    }
    $Path = (Resolve-Path -LiteralPath $Path).ProviderPath
    $config = Import-PowerShellDataFile -LiteralPath $Path

    $required = @(
        'Paths.State', 'Paths.Reports', 'Paths.Logs',
        'vCenter.Server', 'Horizon.Server', 'GoldenImage.VmName',
        'Pools.Test.Name', 'Pools.Production', 'Snapshots.Keep',
        'Promotion.MaintenanceWindow'
    )
    $missing = foreach ($key in $required) {
        $node = $config
        $found = $true
        foreach ($part in $key.Split('.')) {
            if ($node -is [System.Collections.IDictionary] -and $node.Contains($part) -and $null -ne $node[$part]) {
                $node = $node[$part]
            } else {
                $found = $false
                break
            }
        }
        if ($found -and $node -is [string] -and [string]::IsNullOrWhiteSpace($node)) { $found = $false }
        if (-not $found) { $key }
    }
    if ($missing) {
        throw "Config '$Path' is missing required keys: $(@($missing) -join ', ')"
    }

    # Root = folder containing the config file (the Pipeline folder for the default config)
    $root = Split-Path -Parent $Path
    $config['Root'] = $root
    foreach ($name in @('State', 'Reports', 'Logs')) {
        $p = [string]$config.Paths[$name]
        if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $root $p }
        $p = [System.IO.Path]::GetFullPath($p)
        if (-not (Test-Path -LiteralPath $p)) { $null = New-Item -ItemType Directory -Path $p -Force }
        $config.Paths[$name] = $p
    }
    return $config
}

function Get-GISecretCredential {
    <#
    .SYNOPSIS
        Returns a [pscredential] from Microsoft.PowerShell.SecretManagement.
    #>
    [CmdletBinding()]
    [OutputType([pscredential])]
    param(
        [Parameter(Mandatory)][string]$Name
    )

    if (-not (Get-Command -Name Get-Secret -ErrorAction SilentlyContinue)) {
        Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction SilentlyContinue
    }
    if (-not (Get-Command -Name Get-Secret -ErrorAction SilentlyContinue)) {
        throw "Microsoft.PowerShell.SecretManagement is not installed; cannot read secret '$Name'. Install-Module Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore"
    }
    $secret = Get-Secret -Name $Name -AsPlainText:$false -ErrorAction Stop
    if ($secret -isnot [pscredential]) {
        throw "Secret '$Name' is not a PSCredential (found $($secret.GetType().Name))."
    }
    return $secret
}

function Get-GINextMaintenanceWindow {
    <#
    .SYNOPSIS
        Next maintenance window start (>= From) from Promotion.MaintenanceWindow.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [datetime]$From = (Get-Date)
    )

    $window = $Config.Promotion.MaintenanceWindow
    $days = @($window.Days | ForEach-Object { [System.DayOfWeek]([string]$_) })
    if ($days.Count -eq 0) { throw 'Promotion.MaintenanceWindow.Days is empty.' }
    $time = [timespan]::ParseExact([string]$window.StartTime, 'hh\:mm', [cultureinfo]::InvariantCulture)

    foreach ($offset in 0..7) {
        $candidate = $From.Date.AddDays($offset).Add($time)
        if ($days -contains $candidate.DayOfWeek -and $candidate -ge $From) {
            return $candidate
        }
    }
}
