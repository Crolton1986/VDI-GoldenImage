<#
.SYNOPSIS
  Approves (or rejects) a validated run and schedules the production image push.
.EXAMPLE
  # Approve for the next configured maintenance window
  PS> .\Approve-GIPromotion.ps1 -RunId 20261124-213005
.EXAMPLE
  PS> .\Approve-GIPromotion.ps1 -RunId 20261124-213005 -StartTime '2026-11-28 22:00' -Comment 'CAB-1234'
.EXAMPLE
  PS> .\Approve-GIPromotion.ps1 -RunId 20261124-213005 -Reject -Comment 'Teams regression'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [ValidatePattern('^\d{8}-\d{6}$')] [string] $RunId,
    [datetime] $StartTime,
    [string] $Comment = '',
    [switch] $Reject,
    [string] $ConfigPath
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'VDI-GIPipeline.psd1') -Force
$config = if ($ConfigPath) { Get-GIConfig -Path $ConfigPath } else { Get-GIConfig }
$by = "$env:USERDOMAIN\$env:USERNAME"

if ($Reject) {
    $run = Deny-GIRun -Config $config -RunId $RunId -By $by -Comment $Comment -WhatIf:$WhatIfPreference
} else {
    $p = @{ Config = $config; RunId = $RunId; By = $by; Comment = $Comment; WhatIf = $WhatIfPreference }
    if ($PSBoundParameters.ContainsKey('StartTime')) { $p.StartTime = $StartTime }
    $run = Approve-GIRun @p
}
$run | Select-Object runId, status, @{ n = 'decision'; e = { $_.approval.decision } }, @{ n = 'startTime'; e = { $_.approval.startTime } } | Format-List | Out-Host
