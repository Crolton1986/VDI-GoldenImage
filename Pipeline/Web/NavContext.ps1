#----------------[ Per-request navigation context ]----------------
# Each HTML route calls Set-GINavContext first (after authentication has run, so the user's groups are
# known). New-GIPage reads $global:GINavContext to render the side menu. Pode handles one request at a
# time per runspace, so a runspace-global value is safe; it's reset on every request.

function Set-GINavContext {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Per-runspace request context read by New-GIPage')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Sets an in-memory variable only')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context, $WebEvent)
    $complete = $true
    if ($Context['SetupMode']) {
        try { $complete = [bool](Test-GISetupComplete -Config (Get-GIDashboardConfig $Context)) } catch { $complete = $false }
    }
    $global:GINavContext = @{
        Path          = if ($WebEvent) { [string]$WebEvent.Path } else { '' }
        IsAdmin       = [bool](Test-GIDashboardAdmin -Context $Context -WebEvent $WebEvent)
        IsApprover    = [bool](Test-GIDashboardApprover -Context $Context -WebEvent $WebEvent)
        SetupMode     = [bool]$Context['SetupMode']
        SetupComplete = $complete
    }
}
