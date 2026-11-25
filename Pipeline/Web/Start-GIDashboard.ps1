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

# Several request threads so one slow request (a connection test waiting on MFA) doesn't block every page.
# The request timeout (150 s, above the 120 s test limit) lives in server.psd1 next to this script.
Start-PodeServer -Quiet -Threads 4 {
    # Make the context, module and view functions available in every route runspace.
    Set-PodeState -Name 'GIContext' -Value $ctx | Out-Null
    Import-PodeModule -Path $manifest
    Use-PodeScript -Path $viewsPath
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
        New-PodeAuthScheme -Basic -Realm 'VDI Golden Image Pipeline' |
            Add-PodeAuthWindowsAd -Name 'AD' -Groups $groups -Sessionless
        $auth = @{ Authentication = 'AD' }
    }

    Add-PodeRoute -Method Get -Path '/' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Set-GINavContext -Context $c -WebEvent $WebEvent
        $runs = @(Get-GIRunList -Config (Get-GIDashboardConfig $c) -Last 50)
        Write-PodeHtmlResponse -Value (New-GIRunListPage -Runs $runs -RefreshSeconds $c.RefreshSeconds)
    }

    Add-PodeRoute -Method Get -Path '/runs/:runId' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Set-GINavContext -Context $c -WebEvent $WebEvent
        $id = $WebEvent.Parameters['runId']
        if (-not (Test-GIRunId $id) -or -not (Test-Path -LiteralPath (Join-Path (Get-GIDashboardConfig $c).Paths.State "$id.json"))) {
            Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message 'Run not found.') -StatusCode 404
            return
        }
        $run = Get-GIRun -Config (Get-GIDashboardConfig $c) -RunId $id
        $form = ''
        $refresh = $c.RefreshSeconds
        $user = Get-GIDashboardUser -Context $c -WebEvent $WebEvent
        if ($run.status -eq 'AwaitingApproval' -and (Test-GIDashboardApprover -Context $c -WebEvent $WebEvent)) {
            $token = Get-GIFormToken -Secret $c.FormSecret -User $user -RunId $id
            $form = New-GIApprovalForm -RunId $id -Token $token -DefaultStart (Get-GINextMaintenanceWindow -Config (Get-GIDashboardConfig $c))
            $refresh = 0   # don't wipe a half-filled form
        }
        $notice = switch ($WebEvent.Query['result']) {
            'approved' { 'Approved. Production push scheduled.' }
            'rejected' { 'Run rejected.' }
            default { '' }
        }
        $isAdmin = Test-GIDashboardAdmin -Context $c -WebEvent $WebEvent
        if ($isAdmin) {
            $cfg = Get-GIDashboardConfig $c
            $lock = Get-GIPipelineLock -Config $cfg
            $busy = ($lock -and -not $lock.stale) -or [bool](Get-GIPendingRunRequest -Config $cfg)
            $runToken = Get-GIFormToken -Secret $c.FormSecret -User $user -RunId 'run'
            $notice += New-GIRunActionsHtml -Run $run -Token $runToken -Busy $busy
        }
        $stepLogs = Get-GIRunStepLogs -Config (Get-GIDashboardConfig $c) -Run $run
        Write-PodeHtmlResponse -Value (New-GIRunDetailPage -Run $run -RefreshSeconds $refresh -ApprovalFormHtml $form -NoticeHtml $notice -StepLogs $stepLogs)
    }

    # Live log of one guest-watcher step; polled by the run page while the step is Running.
    Add-PodeRoute -Method Get -Path '/runs/:runId/steps/:stepId/log' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        $r = Get-GIStepLogResponse -Config (Get-GIDashboardConfig $c) -RunId ([string]$WebEvent.Parameters['runId']) -StepId ([string]$WebEvent.Parameters['stepId']) -Offset ([string]$WebEvent.Query['offset'])
        Write-PodeJsonResponse -Value (ConvertTo-Json -InputObject $r.Body -Depth 6 -Compress) -StatusCode $r.Status
    }

    Add-PodeRoute -Method Post -Path '/runs/:runId/decision' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Set-GINavContext -Context $c -WebEvent $WebEvent
        $id = $WebEvent.Parameters['runId']
        $deny = { param($code, $msg) Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message $msg) -StatusCode $code }
        if (-not (Test-GIRunId $id)) { & $deny 404 'Run not found.'; return }
        $hdr = @{ Origin = $WebEvent.Request.Headers['Origin']; Host = $WebEvent.Request.Headers['Host'] }
        $why = Get-GIPostRejection -Context $c -WebEvent $WebEvent -Role Approver -FormId $id -Headers $hdr
        if ($why) { & $deny $why.Code $why.Message; return }
        $user = Get-GIDashboardUser -Context $c -WebEvent $WebEvent
        $comment = [string]$WebEvent.Data['comment']
        if ($comment.Length -gt 500) { $comment = $comment.Substring(0, 500) }
        try {
            if ($WebEvent.Data['decision'] -eq 'approve') {
                $start = [datetime]::ParseExact([string]$WebEvent.Data['startTime'], 'yyyy-MM-ddTHH:mm', [cultureinfo]::InvariantCulture)
                $cfg = Get-GIDashboardConfig $c
                Approve-GIRun -Config $cfg -RunId $id -By $user -StartTime $start -Comment $comment | Out-Null
                Write-GIAudit -Config $cfg -User $user -Action 'approval.approve' -Target $id -Detail @{ startTime = $start.ToString('o'); comment = $comment }
                Move-PodeResponseUrl -Url "/runs/$id?result=approved"
            } elseif ($WebEvent.Data['decision'] -eq 'reject') {
                $cfg = Get-GIDashboardConfig $c
                Deny-GIRun -Config $cfg -RunId $id -By $user -Comment $comment | Out-Null
                Write-GIAudit -Config $cfg -User $user -Action 'approval.reject' -Target $id -Detail @{ comment = $comment }
                Move-PodeResponseUrl -Url "/runs/$id?result=rejected"
            } else {
                & $deny 400 'Unknown decision.'
            }
        } catch {
            & $deny 409 "Not done: $($_.Exception.Message)"
        }
    }

    #----- Admin: settings -----

    Add-PodeRoute -Method Get -Path '/settings' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Set-GINavContext -Context $c -WebEvent $WebEvent
        if (-not (Test-GIDashboardAdmin -Context $c -WebEvent $WebEvent)) { Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message 'Settings are for the admin group.') -StatusCode 403; return }
        $first = @((Get-GISettingsSchema).Keys)[0]
        Move-PodeResponseUrl -Url "/settings/$first"
    }

    Add-PodeRoute -Method Get -Path '/settings/:section' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Set-GINavContext -Context $c -WebEvent $WebEvent
        if (-not (Test-GIDashboardAdmin -Context $c -WebEvent $WebEvent)) { Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message 'Settings are for the admin group.') -StatusCode 403; return }
        $schema = Get-GISettingsSchema
        $sk = [string]$WebEvent.Parameters['section']
        if (-not $schema.Contains($sk)) { Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message 'Unknown settings section.') -StatusCode 404; return }
        $cfg = Get-GIDashboardConfig $c
        $user = Get-GIDashboardUser -Context $c -WebEvent $WebEvent
        $notice = switch ($WebEvent.Query['r']) { 'saved' { 'Saved. Changes apply to the next run.' } 'nochange' { 'Nothing changed.' } 'cred' { 'Credential stored.' } default { '' } }
        $page = New-GISettingsSectionPage -Schema $schema -SectionKey $sk -SectionData (Get-GISettingsSection -Config $cfg -Section $sk) `
            -Token (Get-GIFormToken -Secret $c.FormSecret -User $user -RunId "settings:$sk") -Notice $notice -IsHttps $c.IsHttps
        Write-PodeHtmlResponse -Value $page
    }

    Add-PodeRoute -Method Post -Path '/settings/:section' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Set-GINavContext -Context $c -WebEvent $WebEvent
        $schema = Get-GISettingsSchema
        $sk = [string]$WebEvent.Parameters['section']
        if (-not $schema.Contains($sk)) { Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message 'Unknown settings section.') -StatusCode 404; return }
        $hdr = @{ Origin = $WebEvent.Request.Headers['Origin']; Host = $WebEvent.Request.Headers['Host'] }
        $why = Get-GIPostRejection -Context $c -WebEvent $WebEvent -Role Admin -FormId "settings:$sk" -Headers $hdr
        if ($why) { Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message $why.Message) -StatusCode $why.Code; return }
        $user = Get-GIDashboardUser -Context $c -WebEvent $WebEvent
        $cfg = Get-GIDashboardConfig $c
        $section = $schema[$sk]
        if ($section['ReadOnly']) { Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message 'This section is read-only.') -StatusCode 400; return }

        $current = Get-GISettingsSection -Config $cfg -Section $sk
        $conv = ConvertFrom-GISettingsForm -Section $sk -Form $WebEvent.Data
        $errors = @{}
        foreach ($k in $conv.Errors.Keys) { $errors[$k] = $conv.Errors[$k] }
        $checked = Test-GISettingsSection -Section $sk -Values $conv.Values
        foreach ($k in $checked.Keys) { if (-not $errors.Contains($k)) { $errors[$k] = $checked[$k] } }
        # Fields marked Confirm (AutoPromote, ProtectAncestors) need the confirmation box when they change
        foreach ($f in $section.Fields) {
            if (-not $f['Confirm']) { continue }
            $old = [bool]$current.Values[$f.Key]; $new = [bool]$conv.Values[$f.Key]
            if ($old -ne $new -and -not $WebEvent.Data["confirm_$($f.Key)"]) { $errors[$f.Key] = 'Tick the confirmation box to change this setting.' }
        }
        if ($errors.Count) {
            $shown = @{ Section = $sk; Values = @{} }
            foreach ($k in $current.Values.Keys) { $shown.Values[$k] = $current.Values[$k] }
            foreach ($k in $conv.Values.Keys) { $shown.Values[$k] = $conv.Values[$k] }
            if ($current.ContainsKey('Installers')) { $shown.Installers = $current.Installers }
            $page = New-GISettingsSectionPage -Schema $schema -SectionKey $sk -SectionData $shown -Errors $errors `
                -Token (Get-GIFormToken -Secret $c.FormSecret -User $user -RunId "settings:$sk") -Notice 'Not saved: fix the highlighted fields.' -IsHttps $c.IsHttps
            Write-PodeHtmlResponse -Value $page -StatusCode 400
            return
        }
        try {
            $res = Save-GISettingsSection -Config $cfg -Section $sk -Values $conv.Values -By $user
        } catch {
            Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message "Not saved: $($_.Exception.Message)") -StatusCode 400
            return
        }
        $r = if (@($res.Changed).Count) { 'saved' } else { 'nochange' }
        if ($sk -eq 'Promotion' -and @($res.Changed | Where-Object { $_ -like 'PipelineSchedule.*' }).Count) {
            $t = Set-GIPipelineScheduleTask -Config (Get-GIDashboardConfig $c)
            Write-GIAudit -Config $cfg -User $user -Action 'settings.save' -Target 'PipelineScheduleTask' -Detail @{ ok = $t.ok; detail = $t.detail }
            if (-not $t.ok) {
                $page = New-GISettingsSectionPage -Schema $schema -SectionKey $sk -SectionData (Get-GISettingsSection -Config (Get-GIDashboardConfig $c) -Section $sk) `
                    -Token (Get-GIFormToken -Secret $c.FormSecret -User $user -RunId "settings:$sk") -Notice $t.detail -IsHttps $c.IsHttps
                Write-PodeHtmlResponse -Value $page
                return
            }
        }
        Move-PodeResponseUrl -Url "/settings/$($sk)?r=$r"
    }

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
        } catch {
            $page = New-GISettingsSectionPage -Schema $schema -SectionKey $sk -SectionData (Get-GISettingsSection -Config $cfg -Section $sk) `
                -Token (Get-GIFormToken -Secret $c.FormSecret -User $user -RunId "settings:$sk") -Notice "Credential not stored: $($_.Exception.Message)" -IsHttps $c.IsHttps
            Write-PodeHtmlResponse -Value $page -StatusCode 400
            return
        }
        Move-PodeResponseUrl -Url "/settings/$($sk)?r=cred"
    }

    Add-PodeRoute -Method Post -Path '/settings/:section/test' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Set-GINavContext -Context $c -WebEvent $WebEvent
        $schema = Get-GISettingsSchema
        $sk = [string]$WebEvent.Parameters['section']
        if (-not $schema.Contains($sk) -or -not $schema[$sk]['Test']) { Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message 'Nothing to test here.') -StatusCode 404; return }
        $hdr = @{ Origin = $WebEvent.Request.Headers['Origin']; Host = $WebEvent.Request.Headers['Host'] }
        $why = Get-GIPostRejection -Context $c -WebEvent $WebEvent -Role Admin -FormId "settings:$sk" -Headers $hdr
        if ($why) { Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message $why.Message) -StatusCode $why.Code; return }
        $user = Get-GIDashboardUser -Context $c -WebEvent $WebEvent
        $cfg = Get-GIDashboardConfig $c
        Write-GIAudit -Config $cfg -User $user -Action 'connection.test.start' -Target $sk
        # Separate process with a hard limit: an MFA push or a hung login can't block the web server
        $result = Invoke-GIConnectionTest -ConfigPath $c.ConfigPath -System $schema[$sk]['Test']
        Write-GIAudit -Config $cfg -User $user -Action 'connection.test' -Target $sk -Detail @{ ok = $result.ok; detail = $result.detail; seconds = $result.seconds }
        $page = New-GISettingsSectionPage -Schema $schema -SectionKey $sk -SectionData (Get-GISettingsSection -Config $cfg -Section $sk) `
            -Token (Get-GIFormToken -Secret $c.FormSecret -User $user -RunId "settings:$sk") -TestResult $result -IsHttps $c.IsHttps
        Write-PodeHtmlResponse -Value $page
    }

    #----- Admin: run controls -----

    Add-PodeRoute -Method Get -Path '/run' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Set-GINavContext -Context $c -WebEvent $WebEvent
        if (-not (Test-GIDashboardAdmin -Context $c -WebEvent $WebEvent)) { Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message 'Run controls are for the admin group.') -StatusCode 403; return }
        $cfg = Get-GIDashboardConfig $c
        $user = Get-GIDashboardUser -Context $c -WebEvent $WebEvent
        $lkg = Get-GILastKnownGood -Config $cfg
        $notice = switch ($WebEvent.Query['r']) {
            'queued'    { 'Queued. The runner task picks it up within a few seconds; the run appears in the run list.' }
            'norunner'  { 'Queued, but the VDI-GI-Runner task could not be started. Check that it is registered (Register-GIPipelineTasks.ps1).' }
            'started'   { 'Started in a local process (local mode, no scheduled task). The run appears in the run list; output is in logs/runner-*.log.' }
            'runfailed' { 'Queued, but the local runner process stopped right away. See the newest logs/runner-*.log.err.' }
            'cancelled' { 'Queued request cancelled.' }
            default { '' }
        }
        $page = New-GIRunControlPage -Runs @(Get-GIRunList -Config $cfg -Last 20) -Lock (Get-GIPipelineLock -Config $cfg) `
            -PendingRequest (Get-GIPendingRunRequest -Config $cfg) -Token (Get-GIFormToken -Secret $c.FormSecret -User $user -RunId 'run') `
            -Stages @('Preflight', 'Maintain', 'Snapshot', 'TestPush', 'Validate') -TestPool ([string]$cfg.Pools.Test.Name) `
            -ProdPools @($cfg.Pools.Production | ForEach-Object { [string]$_['Name'] }) -LastKnownGood $(if ($lkg) { [string]$lkg.snapshotName } else { '' }) -Notice $notice
        Write-PodeHtmlResponse -Value $page
    }

    Add-PodeRoute -Method Post -Path '/run/start' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Set-GINavContext -Context $c -WebEvent $WebEvent
        $hdr = @{ Origin = $WebEvent.Request.Headers['Origin']; Host = $WebEvent.Request.Headers['Host'] }
        $why = Get-GIPostRejection -Context $c -WebEvent $WebEvent -Role Admin -FormId 'run' -Headers $hdr
        if ($why) { Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message $why.Message) -StatusCode $why.Code; return }
        $user = Get-GIDashboardUser -Context $c -WebEvent $WebEvent
        $cfg = Get-GIDashboardConfig $c
        $action = [string]$WebEvent.Data['action']
        $p = @{ Config = $cfg; RequestedBy = $user; Action = $action }
        if ($action -in 'FromStage', 'Stage') {
            $p.Stage = [string]$WebEvent.Data['stage']; $p.RunId = [string]$WebEvent.Data['runId']
            if ([string]$WebEvent.Data['step']) { $p.Step = [string]$WebEvent.Data['step'] }
        }
        try {
            New-GIRunRequest @p | Out-Null
        } catch {
            Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message "Not started: $($_.Exception.Message)") -StatusCode 409
            return
        }
        $r = Start-GIQueuedRun -Config $cfg -ConfigPath $c.ConfigPath -Local:([bool]$c.LocalAdmin)
        Move-PodeResponseUrl -Url "/run?r=$r"
    }

    Add-PodeRoute -Method Post -Path '/run/rollback' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Set-GINavContext -Context $c -WebEvent $WebEvent
        $hdr = @{ Origin = $WebEvent.Request.Headers['Origin']; Host = $WebEvent.Request.Headers['Host'] }
        $why = Get-GIPostRejection -Context $c -WebEvent $WebEvent -Role Admin -FormId 'run' -Headers $hdr
        if ($why) { Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message $why.Message) -StatusCode $why.Code; return }
        $user = Get-GIDashboardUser -Context $c -WebEvent $WebEvent
        $cfg = Get-GIDashboardConfig $c
        $pool = [string]$WebEvent.Data['pool']
        if ([string]$WebEvent.Data['confirmPool'] -cne $pool) {
            Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message 'Rollback not started: the confirmation must match the pool name exactly.') -StatusCode 400
            return
        }
        $p = @{ Config = $cfg; RequestedBy = $user; Action = 'Rollback'; Pool = $pool; SnapshotName = [string]$WebEvent.Data['snapshotName']; ForceLogoff = [bool]$WebEvent.Data['forceLogoff'] }
        try {
            New-GIRunRequest @p | Out-Null
        } catch {
            Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message "Rollback not started: $($_.Exception.Message)") -StatusCode 409
            return
        }
        $r = Start-GIQueuedRun -Config $cfg -ConfigPath $c.ConfigPath -Local:([bool]$c.LocalAdmin)
        Move-PodeResponseUrl -Url "/run?r=$r"
    }

    Add-PodeRoute -Method Post -Path '/run/cancel-request' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Set-GINavContext -Context $c -WebEvent $WebEvent
        $hdr = @{ Origin = $WebEvent.Request.Headers['Origin']; Host = $WebEvent.Request.Headers['Host'] }
        $why = Get-GIPostRejection -Context $c -WebEvent $WebEvent -Role Admin -FormId 'run' -Headers $hdr
        if ($why) { Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message $why.Message) -StatusCode $why.Code; return }
        Remove-GIRunRequest -Config (Get-GIDashboardConfig $c) -By (Get-GIDashboardUser -Context $c -WebEvent $WebEvent) | Out-Null
        Move-PodeResponseUrl -Url '/run?r=cancelled'
    }

    Add-PodeRoute -Method Get -Path '/audit' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Set-GINavContext -Context $c -WebEvent $WebEvent
        if (-not (Test-GIDashboardAdmin -Context $c -WebEvent $WebEvent)) { Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message 'The audit log is for the admin group.') -StatusCode 403; return }
        Write-PodeHtmlResponse -Value (New-GIAuditPage -Entries @(Get-GIAudit -Config (Get-GIDashboardConfig $c) -Last 200))
    }


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

    Add-PodeRoute -Method Get -Path '/reports/:runId' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Set-GINavContext -Context $c -WebEvent $WebEvent
        $id = $WebEvent.Parameters['runId']
        $file = if (Test-GIRunId $id) { Join-Path (Get-GIDashboardConfig $c).Paths.Reports "$id.html" }
        if (-not $file -or -not (Test-Path -LiteralPath $file -PathType Leaf)) {
            Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message 'Report not found.') -StatusCode 404
            return
        }
        # Reports are generated HTML; lock down what they may load.
        Add-PodeHeader -Name 'Content-Security-Policy' -Value "default-src 'none'; style-src 'unsafe-inline'; img-src data:"
        Write-PodeHtmlResponse -Value (Get-Content -LiteralPath $file -Raw -Encoding UTF8)
    }

    Add-PodeRoute -Method Get -Path '/logs/:runId' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Set-GINavContext -Context $c -WebEvent $WebEvent
        $id = $WebEvent.Parameters['runId']
        $file = if (Test-GIRunId $id) { Join-Path (Get-GIDashboardConfig $c).Paths.Logs "$id.log" }
        if (-not $file -or -not (Test-Path -LiteralPath $file -PathType Leaf)) {
            Write-PodeTextResponse -Value 'Log not found.' -ContentType 'text/plain' -StatusCode 404
            return
        }
        $text = (Get-Content -LiteralPath $file -Tail 2000 -Encoding UTF8) -join "`n"
        Write-PodeTextResponse -Value $text -ContentType 'text/plain'
    }

    Add-PodeRoute -Method Get -Path '/pools' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Set-GINavContext -Context $c -WebEvent $WebEvent
        $runs = @(Get-GIRunList -Config (Get-GIDashboardConfig $c) -Last 50)
        $lkg = Get-GILastKnownGood -Config (Get-GIDashboardConfig $c)
        Write-PodeHtmlResponse -Value (New-GIPoolsPage -LastKnownGood $lkg -Runs $runs -TestPoolName ([string](Get-GIDashboardConfig $c).Pools.Test.Name) -RefreshSeconds $c.RefreshSeconds)
    }

    Add-PodeRoute -Method Get -Path '/api/runs' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Set-GINavContext -Context $c -WebEvent $WebEvent
        $runs = @(Get-GIRunList -Config (Get-GIDashboardConfig $c) -Last 50)
        Write-PodeJsonResponse -Value (ConvertTo-Json -InputObject $runs -Depth 10)
    }

    Add-PodeRoute -Method Get -Path '/api/runs/:runId' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        Set-GINavContext -Context $c -WebEvent $WebEvent
        $id = $WebEvent.Parameters['runId']
        if (-not (Test-GIRunId $id) -or -not (Test-Path -LiteralPath (Join-Path (Get-GIDashboardConfig $c).Paths.State "$id.json"))) {
            Write-PodeJsonResponse -Value '{"error":"Run not found"}' -StatusCode 404
            return
        }
        Write-PodeJsonResponse -Value (ConvertTo-Json -InputObject (Get-GIRun -Config (Get-GIDashboardConfig $c) -RunId $id) -Depth 10)
    }
}
