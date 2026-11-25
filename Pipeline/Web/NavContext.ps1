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
    $isAdmin = [bool](Test-GIDashboardAdmin -Context $Context -WebEvent $WebEvent)
    $isApprover = [bool](Test-GIDashboardApprover -Context $Context -WebEvent $WebEvent)
    $global:GINavContext = @{
        Path          = if ($WebEvent) { [string]$WebEvent.Path } else { '' }
        IsAdmin       = $isAdmin
        IsApprover    = $isApprover
        UserName      = Get-GIDashboardUser -Context $Context -WebEvent $WebEvent
        Token         = $(try { Get-GIFormToken -Secret $Context.FormSecret -User (Get-GIDashboardUser -Context $Context -WebEvent $WebEvent) -RunId 'api' } catch { '' })
        Role          = if ($isAdmin) { 'Admin' } elseif ($isApprover) { 'Approver' } else { 'Viewer' }
        SetupMode     = [bool]$Context['SetupMode']
        SetupComplete = $complete
    }
}

function Invoke-GIApiRoute {
    <# Pode glue for /api/*: caller identity and role, CSRF check for writes, dispatch, response. All logic lives in Invoke-GIApiRequest. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)] $WebEvent)
    $cfg = Get-GIDashboardConfig $Context
    $user = Get-GIDashboardUser -Context $Context -WebEvent $WebEvent
    $role = if (Test-GIDashboardAdmin -Context $Context -WebEvent $WebEvent) { 'Admin' } elseif (Test-GIDashboardApprover -Context $Context -WebEvent $WebEvent) { 'Approver' } else { 'Viewer' }
    $method = [string]$WebEvent.Method
    $respond = {
        param($r)
        if ($r.File) {
            try {
                Add-PodeHeader -Name 'Content-Disposition' -Value ('attachment; filename="{0}"' -f ($r.FileName -replace '[^A-Za-z0-9._-]', '_'))
                Write-PodeFileResponse -Path $r.File -ContentType $r.ContentType
            } finally { if ($r.DeleteAfter) { Remove-Item -LiteralPath $r.File -Force -ErrorAction SilentlyContinue } }
            return
        }
        Write-PodeJsonResponse -Value (ConvertTo-Json -InputObject $r.Body -Depth 10) -StatusCode $r.Code
    }
    if ($method -ne 'GET') {
        $hdr = $WebEvent.Request.Headers
        $origin = if ($hdr) { [string]$hdr['Origin'] } else { '' }
        $hostHdr = if ($hdr) { [string]$hdr['Host'] } else { '' }
        $bad = $null
        if ($Context.NoAuth -and -not $Context['LocalAdmin']) { $bad = 'The dashboard is read-only when it runs without authentication.' }
        elseif ($origin -and $origin -ne 'null') {
            try { $a = ([uri]$origin).Authority } catch { $a = '' }
            if ($a -ne $hostHdr) { $bad = 'Cross-origin request refused.' }
        }
        if (-not $bad) {
            $tok = if ($hdr -and $hdr['X-GI-Token']) { [string]$hdr['X-GI-Token'] } elseif ($WebEvent.Data -and $WebEvent.Data['token']) { [string]$WebEvent.Data['token'] } else { '' }
            if (-not (Test-GIFormToken -Secret $Context.FormSecret -User $user -RunId 'api' -Token $tok)) { $bad = 'Session token expired. Reload the page and try again.' }
        }
        if ($bad) {
            Write-GIAudit -Config $cfg -User $user -Role $role -Action 'auth.denied' -Target "$method $($WebEvent.Path)" -Detail @{ reason = $bad; result = 'Denied' }
            & $respond @{ Code = 403; Body = @{ error = $bad } }
            return
        }
    }
    $body = $null
    if ($method -ne 'GET' -and $WebEvent.Data) { $body = $WebEvent.Data }
    $q = @{}
    foreach ($k in @($WebEvent.Query.Keys)) { $q[[string]$k] = [string]$WebEvent.Query[$k] }
    $opts = @{ ConfigPath = $Context['ConfigPath']; StartRunner = { param($c) Start-GIQueuedRun -Config $c -ConfigPath $Context['ConfigPath'] -Local:([bool]$Context['LocalAdmin']) } }
    & $respond (Invoke-GIApiRequest -Config $cfg -Method $method -Path ([string]$WebEvent.Path) -Query $q -Body $body -User $user -Role $role -Options $opts)
}
