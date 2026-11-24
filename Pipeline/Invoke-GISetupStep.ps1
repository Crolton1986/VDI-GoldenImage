<#
.SYNOPSIS
  Runs one background setup step (Prerequisites, Modules, PowerCLI, Vault) and records the result in
  config/setup.json. Started by the /setup page; not meant to be run by hand.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Prerequisites', 'Modules', 'PowerCLI', 'Vault')] [string] $Step,
    [string] $ConfigPath
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'VDI-GIPipeline.psd1') -Force
$config = if ($ConfigPath) { Get-GIConfig -Path $ConfigPath } else { Get-GIConfig }

# Record our pid so the page can tell a crashed step from a running one
$state = Get-GISetupState -Config $config
if ($state.steps.$Step.status -ne 'running') { Write-Error "Step $Step is not marked running; start it from the /setup page."; exit 1 }
$state.steps.$Step.pid = $PID
Save-GISetupState -Config $config -State $state

$ok = Invoke-GISetupStepCore -Config $config -Step $Step
exit $(if ($ok) { 0 } else { 1 })
