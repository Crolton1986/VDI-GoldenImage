Set-StrictMode -Version Latest

# Dot-source every file in src/ in a deterministic (sorted) order.
$script:GIModuleRoot = $PSScriptRoot
Get-ChildItem -Path (Join-Path $PSScriptRoot 'src') -Filter '*.ps1' -File |
    Sort-Object -Property Name |
    ForEach-Object { . $_.FullName }

Export-ModuleMember -Function *-GI*
