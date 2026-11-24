<#
.SYNOPSIS
  Runs one background setup step (Prerequisites, Modules, PowerCLI, Vault) and records the result in
  config/setup.json. Started by the /setup page; not meant to be run by hand.
  Output goes to config/setup-<Step>.transcript.log (plus .log / .log.err from the launching process).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Prerequisites', 'Modules', 'PowerCLI', 'Vault')] [string] $Step,
    [string] $ConfigPath
)
$ErrorActionPreference = 'Stop'
$transcriptDir = if ($ConfigPath) { Join-Path (Split-Path -Parent $ConfigPath) 'config' } else { Join-Path $PSScriptRoot 'config' }
try { Start-Transcript -Path (Join-Path $transcriptDir "setup-$Step.transcript.log") -Force | Out-Null } catch { Write-Warning "No transcript: $($_.Exception.Message)" }

$config = $null
try {
    Import-Module (Join-Path $PSScriptRoot 'VDI-GIPipeline.psd1') -Force
    $config = if ($ConfigPath) { Get-GIConfig -Path $ConfigPath } else { Get-GIConfig }

    # Record our pid so the page can tell a crashed step from a running one
    $state = Get-GISetupState -Config $config
    if ($state.steps.$Step.status -ne 'running') { throw "Step $Step is not marked running; start it from the /setup page." }
    $state.steps.$Step.pid = $PID
    Save-GISetupState -Config $config -State $state
    Write-GISetupProgress -Config $config -Step $Step -Line "Runner started (pid $PID, PowerShell $($PSVersionTable.PSVersion), user $(Get-GICurrentUserName))"

    $ok = Invoke-GISetupStepCore -Config $config -Step $Step
    $code = if ($ok) { 0 } else { 1 }
} catch {
    # Anything that fails before or around the step itself (module import, config, state file) still marks it failed
    $msg = "Setup runner error: $($_.Exception.Message)"
    Write-Error $msg -ErrorAction Continue
    if ($config) {
        try { Set-GISetupStep -Config $config -Step $Step -Status failed -Message $msg } catch { Write-Error "Could not record the failure: $($_.Exception.Message)" -ErrorAction Continue }
    }
    $code = 1
} finally {
    try { Stop-Transcript | Out-Null } catch { Write-Verbose 'No transcript to stop.' }
}
exit $code
