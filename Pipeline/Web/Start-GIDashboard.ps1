<#
.SYNOPSIS
    Pode dashboard for the golden image pipeline: status, approvals, settings and run controls.
.DESCRIPTION
    Server-rendered HTML over the pipeline module. Settings save to config/settings.json,
    credentials go to the SecretManagement vault of the account the dashboard runs as, and run
    controls queue a request for the VDI-GI-Runner scheduled task, or with -LocalAdmin start a separate
    pwsh process for it (stages never run inside a web request).
.PARAMETER ConfigPath
    Optional pipeline config file (defaults to pipeline.config.psd1 next to the module).
.PARAMETER Port
    Listen port (default Dashboard.Port from config).
.PARAMETER NoTls
    Serve plain http (lab/testing). Without it, Dashboard.CertificateThumbprint is used for https.
.PARAMETER NoAuth
    Skip AD authentication (lab/testing, and non-Windows hosts). The dashboard is then strictly
    read-only: approve/reject is disabled.
.PARAMETER Setup
    First-run setup mode (started by Start-GIPipeline.ps1): 127.0.0.1 only, no sign-in, and every page
    redirects to /setup until setup is complete. Combined with -LocalAdmin, setup is locked to Lab mode.
.PARAMETER LocalAdmin
    Lab and smoke tests only: plain http on 127.0.0.1, no authentication, and the caller is treated
    as admin and approver. Refuses any other bind address.
.NOTES
    Auth: HTTP Basic over HTTPS, validated against Active Directory (Windows host only).
    Viewers = Dashboard.ViewerGroup, ApproverGroup or AdminGroup.
    Approve/Reject = ApproverGroup. Settings, credentials, Test connection, run controls = AdminGroup. Forms carry a per-user, per-run
    HMAC token and the Origin header is checked, so a third-party page can't submit them.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [int]$Port,
    [switch]$NoTls,
    [switch]$NoAuth,
    [switch]$LocalAdmin,
    [switch]$Setup
)

$ErrorActionPreference = 'Stop'
$webRoot = $PSScriptRoot
$pipelineRoot = Split-Path -Parent $webRoot
$manifest = Join-Path $pipelineRoot 'VDI-GIPipeline.psd1'

$modeLocked = [bool]$LocalAdmin   # launched for a lab/test run: setup can only choose Lab
if ($Setup) { $LocalAdmin = [switch]$true }
if ($LocalAdmin) { $NoAuth = [switch]$true; $NoTls = [switch]$true }
Import-Module $manifest -Force
Import-Module Pode -MaximumVersion 2.99.99 -ErrorAction Stop

$configArgs = @{}
if ($ConfigPath) { $configArgs.Path = $ConfigPath }
$config = Get-GIConfig @configArgs
if ((Invoke-GIConfigMigration -Config $config).Migrated) { $config = Get-GIConfig @configArgs }
$dash = $config.Dashboard
if (-not $dash) { $dash = @{} }
if (-not $PSBoundParameters.ContainsKey('Port')) { $Port = if ($dash.Port) { [int]$dash.Port } else { 8443 } }
$refresh = if ($dash.RefreshSeconds) { [int]$dash.RefreshSeconds } else { 20 }
$thumb = [string]$dash.CertificateThumbprint

# Shared context for all routes (also the hook for the future auth/approval code).
$script:DashboardContext = @{
    Config         = $config
    RefreshSeconds = $refresh
    ViewerGroup    = [string]$dash.ViewerGroup
    ApproverGroup  = [string]$dash.ApproverGroup
    ManifestPath   = $manifest
    ViewsPath      = Join-Path $webRoot 'DashboardViews.ps1'
    SettingsViewsPath = Join-Path $webRoot 'SettingsViews.ps1'
    SetupViewsPath = Join-Path $webRoot 'SetupViews.ps1'
    SetupMode      = [bool]$Setup
    ModeLocked     = $modeLocked
    StopAt         = $null      # set after a production setup finishes; a timer then stops this server
    ConfigPath     = $ConfigPath
    NoAuth         = [bool]$NoAuth
    LocalAdmin     = [bool]$LocalAdmin
    IsHttps        = (-not $NoTls) -or [bool]$LocalAdmin   # credential forms need https (LocalAdmin is loopback only)
    AdminShort     = ([string]$dash['AdminGroup'] -split '\\')[-1]
    # Pode returns group names without the domain prefix
    ApproverShort  = ([string]$dash.ApproverGroup -split '\\')[-1]
    ViewerShort    = ([string]$dash.ViewerGroup -split '\\')[-1]
    FormSecret     = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
}
if (-not $NoAuth -and -not $IsWindows) { throw 'AD authentication needs a Windows host. Use -NoAuth for a read-only lab dashboard.' }
if (-not $NoAuth -and $NoTls) { Write-Warning 'Basic auth over plain http sends passwords in clear text. Use https outside the lab.' }

$ctx = $script:DashboardContext
if ($Setup -and -not (Test-GISetupComplete -Config $config)) {
    # Persist the Lab lock before any request can choose a mode
    Initialize-GISetupState -Config $config -ModeLocked:$modeLocked | Out-Null
}
$viewsPath = $ctx.ViewsPath
$settingsViewsPath = $ctx.SettingsViewsPath
$setupViewsPath = $ctx.SetupViewsPath
$navContextPath = Join-Path $webRoot 'NavContext.ps1'
$authSetupPath = Join-Path $webRoot 'AuthSetup.ps1'
. $authSetupPath   # Add-GIDashboardAuth, called inside Start-PodeServer
$componentsPath = Join-Path $webRoot 'Components.ps1'
$extraViewPaths = @('ImageViews.ps1', 'ImageScripts.ps1', 'RunViews.ps1', 'AdminViews.ps1', 'Routes.ps1') | ForEach-Object { Join-Path $webRoot $_ }

# Several request threads so one slow request (a connection test waiting on MFA) doesn't block every page.
# The request timeout (150 s, above the 120 s test limit) lives in server.psd1 next to this script.
Start-PodeServer -Quiet -Threads 4 {
    # Make the context, module and view functions available in every route runspace.
    Set-PodeState -Name 'GIContext' -Value $ctx | Out-Null
    Import-PodeModule -Path $manifest
    Use-PodeScript -Path $viewsPath
    Use-PodeScript -Path $componentsPath
    foreach ($p in $extraViewPaths) { Use-PodeScript -Path $p }
    Use-PodeScript -Path $settingsViewsPath
    Use-PodeScript -Path $setupViewsPath
    Use-PodeScript -Path $navContextPath

    # --- Setup mode: everything goes to /setup until setup is complete ---
    if ($ctx.SetupMode) {
        Add-PodeMiddleware -Name 'GISetupRedirect' -ScriptBlock {
            $c = (Get-PodeState -Name 'GIContext')
            if ($WebEvent.Path -like '/setup*') { return $true }
            if (Test-GISetupComplete -Config (Get-GIDashboardConfig $c)) { return $true }
            Move-PodeResponseUrl -Url '/setup'
            return $false
        }
        Add-PodeTimer -Name 'GISetupHandoff' -Interval 2 -ScriptBlock {
            $c = (Get-PodeState -Name 'GIContext')
            if ($c.StopAt -and (Get-Date) -ge $c.StopAt) { Close-PodeServer }
        }
    }

    # --- Logging: errors and requests (408s included) go to <Paths.Logs>/dashboard_*.log ---
    $logDir = [string]$ctx.Config.Paths.Logs
    if ($logDir) {
        if (-not (Test-Path -LiteralPath $logDir)) { $null = New-Item -ItemType Directory -Path $logDir -Force }
        New-PodeLoggingMethod -File -Path $logDir -Name 'dashboard_errors' -MaxDays 14 | Enable-PodeErrorLogging
        New-PodeLoggingMethod -File -Path $logDir -Name 'dashboard_requests' -MaxDays 14 | Enable-PodeRequestLogging
    }

    # --- Endpoint ---
    if ($ctx.LocalAdmin) {
        Add-PodeEndpoint -Address 127.0.0.1 -Port $Port -Protocol Http
    } elseif ($NoTls) {
        Add-PodeEndpoint -Address * -Port $Port -Protocol Http
    } elseif ($thumb) {
        Add-PodeEndpoint -Address * -Port $Port -Protocol Https -CertificateThumbprint $thumb
    } else {
        throw 'Dashboard.CertificateThumbprint is empty. Configure a certificate or start with -NoTls (lab only).'
    }

    # --- Authentication ---
    $auth = @{}
    if (-not $ctx.NoAuth) {
        $groups = @($ctx.ViewerShort, $ctx.ApproverShort, $ctx.AdminShort) | Where-Object { $_ } | Select-Object -Unique
        if (-not $groups) { throw 'Dashboard.ViewerGroup / ApproverGroup / AdminGroup must be set when authentication is on.' }
        $null = Add-GIDashboardAuth -Context $ctx -Groups $groups -Realm 'VDI Golden Image Pipeline'
        $auth = @{ Authentication = 'AD' }
    }



    # Live log of one guest-watcher step; polled by the run page while the step is Running.


    #----- Admin: settings -----




    Add-PodeRoute -Method Post -Path '/settings/:section/credential' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Set-GINavContext -Context $c -WebEvent $WebEvent
        $schema = Get-GISettingsSchema
        $sk = [string]$WebEvent.Parameters['section']
        if (-not $schema.Contains($sk)) { Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message 'Unknown settings section.') -StatusCode 404; return }
        $hdr = @{ Origin = $WebEvent.Request.Headers['Origin']; Host = $WebEvent.Request.Headers['Host'] }
        $why = Get-GIPostRejection -Context $c -WebEvent $WebEvent -Role Admin -FormId "settings:$sk" -Headers $hdr
        if ($why) { Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message $why.Message) -StatusCode $why.Code; return }
        if (-not $c.IsHttps) { Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message 'Credentials can only be entered over https.') -StatusCode 403; return }
        $key = [string]$WebEvent.Data['key']
        $field = @($schema[$sk].Fields | Where-Object { $_.Key -eq $key -and $_.Type -eq 'secret' }) | Select-Object -First 1
        if (-not $field) { Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message 'Unknown credential field.') -StatusCode 400; return }
        $user = Get-GIDashboardUser -Context $c -WebEvent $WebEvent
        $cfg = Get-GIDashboardConfig $c
        try {
            # Secret name: the configured one, or the field default (then recorded in settings.json)
            $name = Set-GISettingsSecretName -Config $cfg -Section $sk -Key $key -By $user
            Set-GISecretFromForm -Name $name -UserName ([string]$WebEvent.Data['username']) -Password ([string]$WebEvent.Data['password'])
            Write-GIAudit -Config $cfg -User $user -Action 'credential.set' -Target $name -Detail @{ section = $sk; userName = ([string]$WebEvent.Data['username']).Trim() }
            Set-GIConnectionStatus -Config $cfg -Section $sk -Clear
        } catch {
            $page = New-GISettingsSectionPage -Schema $schema -SectionKey $sk -SectionData (Get-GISettingsSection -Config $cfg -Section $sk) `
                -Token (Get-GIFormToken -Secret $c.FormSecret -User $user -RunId "settings:$sk") -Notice "Credential not stored: $($_.Exception.Message)" -IsHttps $c.IsHttps
            Write-PodeHtmlResponse -Value $page -StatusCode 400
            return
        }
        Move-PodeResponseUrl -Url "/settings/$($sk)?r=cred"
    }


    #----- Admin: run controls -----








    # --- Pages (handlers live in Web/Routes.ps1) ---
    Add-PodeRoute -Method Get -Path '/' @auth -ScriptBlock { Send-GIHomeRoute -Context (Get-PodeState -Name 'GIContext') -WebEvent $WebEvent }
    Add-PodeRoute -Method Get -Path '/images/new' @auth -ScriptBlock { Send-GIWizardRoute -Context (Get-PodeState -Name 'GIContext') -WebEvent $WebEvent }
    Add-PodeRoute -Method Get -Path '/images/:id' @auth -ScriptBlock { Send-GIImageRoute -Context (Get-PodeState -Name 'GIContext') -WebEvent $WebEvent }
    Add-PodeRoute -Method Get -Path '/images/:id/runs' @auth -ScriptBlock { Send-GIImageRunsRoute -Context (Get-PodeState -Name 'GIContext') -WebEvent $WebEvent }
    Add-PodeRoute -Method Get -Path '/images/:id/runs/current' @auth -ScriptBlock { Send-GICurrentRunRoute -Context (Get-PodeState -Name 'GIContext') -WebEvent $WebEvent }
    Add-PodeRoute -Method Get -Path '/images/:id/runs/:runId' @auth -ScriptBlock { Send-GIRunRoute -Context (Get-PodeState -Name 'GIContext') -WebEvent $WebEvent }
    Add-PodeRoute -Method Get -Path '/images/:id/settings' @auth -ScriptBlock { Send-GIImageSettingsRoute -Context (Get-PodeState -Name 'GIContext') -WebEvent $WebEvent }
    Add-PodeRoute -Method Get -Path '/images/:id/settings/:section' @auth -ScriptBlock { Send-GIImageSettingsRoute -Context (Get-PodeState -Name 'GIContext') -WebEvent $WebEvent }
    Add-PodeRoute -Method Post -Path '/images/:id/settings/:section' @auth -ScriptBlock { Receive-GIImageSettingsRoute -Context (Get-PodeState -Name 'GIContext') -WebEvent $WebEvent }
    Add-PodeRoute -Method Post -Path '/images/:id/settings/:section/credential' @auth -ScriptBlock { Receive-GIImageCredentialRoute -Context (Get-PodeState -Name 'GIContext') -WebEvent $WebEvent }
    Add-PodeRoute -Method Get -Path '/runs/:runId' @auth -ScriptBlock { Send-GILegacyRunRoute -Context (Get-PodeState -Name 'GIContext') -WebEvent $WebEvent }
    Add-PodeRoute -Method Get -Path '/settings' @auth -ScriptBlock { Send-GIGlobalSettingsRoute -Context (Get-PodeState -Name 'GIContext') -WebEvent $WebEvent }
    Add-PodeRoute -Method Get -Path '/settings/:section' @auth -ScriptBlock { Send-GIGlobalSettingsRoute -Context (Get-PodeState -Name 'GIContext') -WebEvent $WebEvent }
    Add-PodeRoute -Method Post -Path '/settings/:section' @auth -ScriptBlock { Receive-GIGlobalSettingsRoute -Context (Get-PodeState -Name 'GIContext') -WebEvent $WebEvent }
    Add-PodeRoute -Method Get -Path '/audit' @auth -ScriptBlock { Send-GIAuditRoute -Context (Get-PodeState -Name 'GIContext') -WebEvent $WebEvent }
    Add-PodeRoute -Method Get -Path '/audit.csv' @auth -ScriptBlock { Send-GIAuditCsvRoute -Context (Get-PodeState -Name 'GIContext') -WebEvent $WebEvent }
    Add-PodeRoute -Method Get -Path '/reports/:runId' @auth -ScriptBlock { Send-GIFileRoute -Context (Get-PodeState -Name 'GIContext') -WebEvent $WebEvent -Kind report }
    Add-PodeRoute -Method Get -Path '/logs/:runId' @auth -ScriptBlock { Send-GIFileRoute -Context (Get-PodeState -Name 'GIContext') -WebEvent $WebEvent -Kind log }

    #----- First-run setup -----

    Add-PodeRoute -Method Get -Path '/setup' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Set-GINavContext -Context $c -WebEvent $WebEvent
        $cfg = Get-GIDashboardConfig $c
        $complete = Test-GISetupComplete -Config $cfg
        if (-not $c.SetupMode -and -not (Test-GIDashboardAdmin -Context $c -WebEvent $WebEvent)) {
            Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message 'Setup status is for the admin group.') -StatusCode 403; return
        }
        $state = Get-GISetupState -Config $cfg -ModeLocked:$c.ModeLocked
        $user = Get-GIDashboardUser -Context $c -WebEvent $WebEvent
        $next = Get-GISetupNextStep -State $state
        $certs = if ($next -eq 'DashboardAccess') { @(Get-GIServerCertificate) } else { @() }
        $defs = if ($next -eq 'Tasks') {
            $a = @{ Root = $cfg.Root; Config = $cfg }; if ($c.ConfigPath) { $a.ConfigPath = $c.ConfigPath }
            @(Get-GIPipelineTaskDefinition @a)
        } else { @() }
        $tails = @{}; $stall = 0
        $runningStep = Get-GISetupRunningStep -State $state
        if ($runningStep) {
            $tf = Join-Path (Join-Path $cfg.Root 'config') "setup-$runningStep.transcript.log"
            if (Test-Path -LiteralPath $tf) { $tails[$runningStep] = (@(Get-Content -LiteralPath $tf -Tail 10 -ErrorAction SilentlyContinue)) -join "`n" }
            $age = Get-GISetupLastProgressAge -State $state -Step $runningStep
            if ($age) { $stall = [int][math]::Floor($age.TotalMinutes) }
        }
        $page = New-GISetupPage -State $state -Token (Get-GIFormToken -Secret $c.FormSecret -User $user -RunId 'setup') `
            -Notice ([string]$WebEvent.Query['n']) -Certificates $certs -TaskDefinitions $defs -CurrentUser (Get-GICurrentUserName) `
            -IsComplete $complete -ReadOnly ($complete -and -not $c.SetupMode) -LogTails $tails -StallMinutes $stall
        Write-PodeHtmlResponse -Value $page
    }

    Add-PodeRoute -Method Get -Path '/setup/log/:step' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Set-GINavContext -Context $c -WebEvent $WebEvent
        if (-not $c.SetupMode -and -not (Test-GIDashboardAdmin -Context $c -WebEvent $WebEvent)) {
            Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message 'Setup logs are for the admin group.') -StatusCode 403; return
        }
        $step = [string]$WebEvent.Parameters['step']
        if ($step -cnotin @('Mode', 'Prerequisites', 'Modules', 'PowerCLI', 'Vault', 'DashboardAccess', 'Tasks', 'Finish')) {
            Write-PodeTextResponse -Value 'Unknown setup step.' -ContentType 'text/plain' -StatusCode 404; return
        }
        Write-PodeTextResponse -Value (Get-GISetupLog -Config (Get-GIDashboardConfig $c) -Step $step) -ContentType 'text/plain; charset=utf-8'
    }

    Add-PodeRoute -Method Get -Path '/setup/status' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Set-GINavContext -Context $c -WebEvent $WebEvent
        $state = Get-GISetupState -Config (Get-GIDashboardConfig $c) -ModeLocked:$c.ModeLocked
        Write-PodeJsonResponse -Value (New-GISetupStatusJson -State $state)
    }

    Add-PodeRoute -Method Post -Path '/setup/:step' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Set-GINavContext -Context $c -WebEvent $WebEvent
        $step = [string]$WebEvent.Parameters['step']
        $hdr = @{ Origin = $WebEvent.Request.Headers['Origin']; Host = $WebEvent.Request.Headers['Host'] }
        $why = if (-not $c.SetupMode) { @{ Code = 403; Message = 'Setup changes are only possible from the setup server (Start-GIPipeline.ps1 -ResetSetup).' } }
               else { Get-GIPostRejection -Context $c -WebEvent $WebEvent -Role Admin -FormId 'setup' -Headers $hdr }
        if ($why) { Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message $why.Message) -StatusCode $why.Code; return }
        $cfg = Get-GIDashboardConfig $c
        $notice = ''
        try {
            $state = Get-GISetupState -Config $cfg -ModeLocked:$c.ModeLocked
            switch ($step) {
                'Mode' {
                    $action = [string]$WebEvent.Data['invalidCertAction']; if (-not $action) { $action = 'Warn' }
                    Set-GISetupMode -Config $cfg -Mode ([string]$WebEvent.Data['mode']) -InvalidCertAction $action -ModeLocked:$c.ModeLocked
                }
                { $_ -in 'Prerequisites', 'Modules', 'PowerCLI', 'Vault' } {
                    Start-GISetupStep -Config $cfg -Step $step -ConfigPath $c.ConfigPath | Out-Null
                }
                'DashboardAccess' {
                    Assert-GISetupCanStart -State $state -Step $step
                    $opts = @{
                        Port = [string]$WebEvent.Data['port']; CertThumbprint = [string]$WebEvent.Data['certificate']
                        ViewerGroup = [string]$WebEvent.Data['viewerGroup']; ApproverGroup = [string]$WebEvent.Data['approverGroup']; AdminGroup = [string]$WebEvent.Data['adminGroup']
                    }
                    Invoke-GISetupStepCore -Config $cfg -Step $step -Arguments @{ Options = $opts } | Out-Null
                }
                'Tasks' {
                    Assert-GISetupCanStart -State $state -Step $step
                    if ([string]$WebEvent.Data['action'] -eq 'skip') {
                        Invoke-GISetupStepCore -Config $cfg -Step $step -Arguments @{ Skip = $true } | Out-Null
                    } else {
                        $pw = [string]$WebEvent.Data['password']
                        $sec = if ($pw) { [System.Net.NetworkCredential]::new('', $pw).SecurePassword } else { $null }
                        $pw = $null
                        $a = @{}
                        if ($sec) { $a.Credential = [pscredential]::new((Get-GICurrentUserName), $sec) }
                        if ($c.ConfigPath) { $a.ConfigPath = $c.ConfigPath }
                        Invoke-GISetupStepCore -Config $cfg -Step $step -Arguments $a | Out-Null
                    }
                }
                'Finish' {
                    $done = Complete-GISetup -Config $cfg
                    if ($done.StartDashboardTask) {
                        try { Start-ScheduledTask -TaskName 'VDI-GI-Dashboard' -ErrorAction Stop }
                        catch { $notice = "Setup is complete, but the VDI-GI-Dashboard task didn't start: $($_.Exception.Message)" }
                        $c.StopAt = (Get-Date).AddSeconds(10)
                    }
                }
                default { throw "Unknown setup step '$step'." }
            }
        } catch {
            $notice = $_.Exception.Message
        }
        $q = if ($notice) { '?n=' + [uri]::EscapeDataString($notice) } else { '' }
        Move-PodeResponseUrl -Url "/setup$q"
    }




    # Legacy read endpoints, now across all images (use /api/images/{id}/runs for paging)
    Add-PodeRoute -Method Get -Path '/api/runs' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Set-GINavContext -Context $c -WebEvent $WebEvent
        $cfg = Get-GIDashboardConfig $c
        $runs = @(foreach ($e in (Get-GIImageEntries -Config $cfg)) { Get-GIRunList -Config (Get-GIImageConfig -Config $cfg -ImageId $e.Id) -Last 50 }) | Sort-Object runId -Descending | Select-Object -First 50
        Write-PodeJsonResponse -Value (ConvertTo-Json -InputObject @($runs) -Depth 10)
    }

    Add-PodeRoute -Method Get -Path '/api/runs/:runId' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Set-GINavContext -Context $c -WebEvent $WebEvent
        $id = $WebEvent.Parameters['runId']
        $ic = Find-GIRunImageConfig -Config (Get-GIDashboardConfig $c) -RunId $id
        if (-not $ic) { Write-PodeJsonResponse -Value '{"error":"Run not found"}' -StatusCode 404; return }
        Write-PodeJsonResponse -Value (ConvertTo-Json -InputObject (Get-GIRun -Config $ic -RunId $id) -Depth 10)
    }

    # Image API (see docs/CONTRACT.md): GET/POST/DELETE under /api; /api/runs stays as the legacy read endpoint
    Add-PodeRoute -Method Get, Post, Delete -Path '/api/*' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Invoke-GIApiRoute -Context $c -WebEvent $WebEvent
    }
}
