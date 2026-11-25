[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Route handlers; state changes are audited and role checked.')]
param()

# Page route handlers. Start-GIDashboard.ps1 registers one thin Pode route per handler; all logic is here so it can be tested
# with stubbed Pode response functions. Every handler calls Set-GINavContext first (role, user, token for the page shell).

function Send-GIHtml {
    param([string]$Html, [int]$Status = 200)
    Write-PodeHtmlResponse -Value $Html -StatusCode $Status
}

function Send-GIError {
    param([int]$Status, [string]$Message)
    Send-GIHtml -Html (New-GINotFoundPage -Message $Message) -Status $Status
}

function Get-GIRouteUser { param($Context, $WebEvent) Get-GIDashboardUser -Context $Context -WebEvent $WebEvent }

function Find-GIRunImageConfig {
    # Image config of the image that owns a run id (searches every image), or $null.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config, [string]$RunId)
    if (-not (Test-GIRunId $RunId)) { return $null }
    foreach ($e in (Get-GIImageEntries -Config $Config)) {
        $ic = Get-GIImageConfig -Config $Config -ImageId $e.Id
        if (Test-Path -LiteralPath (Get-GIRunPath $ic $RunId) -PathType Leaf) { return $ic }
    }
    return $null
}

function Send-GIHomeRoute {
    param($Context, $WebEvent)
    Set-GINavContext -Context $Context -WebEvent $WebEvent
    $cfg = Get-GIDashboardConfig $Context
    $ctx = Get-GIViewContext
    $summaries = @(foreach ($e in (Get-GIImageEntries -Config $cfg)) { Get-GIImageSummary -Config $cfg -ImageId $e.Id })
    $page = 1; [void][int]::TryParse([string]$WebEvent.Query['page'], [ref]$page)
    $refresh = 60
    if ($cfg.Dashboard -and $cfg.Dashboard.ContainsKey('LiveRefreshSeconds')) { $refresh = [int]$cfg.Dashboard.LiveRefreshSeconds }
    $complete = $true
    if ($Context['SetupMode']) { try { $complete = [bool](Test-GISetupComplete -Config $cfg) } catch { $complete = $false } }
    $check = @{ 'vCenter connected' = [bool]$cfg.vCenter.Server; 'Horizon connected' = [bool]$cfg.Horizon.Server; 'PowerCLI installed' = [bool](Get-Module -ListAvailable -Name VMware.VimAutomation.Core) }
    Send-GIHtml (New-GIHomePage -Summaries $summaries -Ctx $ctx -Page $page -LiveRefreshSeconds $refresh -SetupComplete $complete -Checklist $check)
}

function Get-GIImageRouteData {
    # Image summary for a page, or sends a 404 and returns $null.
    param($Context, $WebEvent)
    $id = [string]$WebEvent.Parameters['id']
    $cfg = Get-GIDashboardConfig $Context
    if (-not (Test-GIImageId $id) -or -not (Get-GIImageEntry -Config $cfg -Id $id)) { Send-GIError 404 'Golden image not found.'; return $null }
    return @{ Config = $cfg; Id = $id; Summary = (Get-GIImageSummary -Config $cfg -ImageId $id); ImageConfig = (Get-GIImageConfig -Config $cfg -ImageId $id) }
}

function Send-GIImageRoute {
    param($Context, $WebEvent)
    Set-GINavContext -Context $Context -WebEvent $WebEvent
    $d = Get-GIImageRouteData $Context $WebEvent; if (-not $d) { return }
    $notice = if ($WebEvent.Query['created']) { "$($d.Summary.name) created. Start the first run when you are ready." } else { '' }
    Send-GIHtml (New-GIImageOverviewPage -Summary $d.Summary -Ctx (Get-GIViewContext) -SnapshotsKept ([int]$d.ImageConfig.Snapshots.Keep) -Notice $notice)
}

function Send-GIImageRunsRoute {
    param($Context, $WebEvent)
    Set-GINavContext -Context $Context -WebEvent $WebEvent
    $d = Get-GIImageRouteData $Context $WebEvent; if (-not $d) { return }
    $status = [string]$WebEvent.Query['status']
    if ($status -notin '', 'Succeeded', 'Failed', 'Active') { $status = '' }
    $page = 1; if (-not [int]::TryParse([string]$WebEvent.Query['page'], [ref]$page) -or $page -lt 1) { $page = 1 }
    $all = @(Get-GIRunList -Config $d.ImageConfig)
    $all = switch ($status) {
        'Succeeded' { @($all | Where-Object { $_.status -in 'Completed', 'Scheduled' }) }
        'Failed' { @($all | Where-Object { $_.status -eq 'Failed' }) }
        'Active' { @($all | Where-Object { $_.status -in 'Running', 'AwaitingApproval' }) }
        default { $all }
    }
    $slice = @($all | Select-Object -Skip (($page - 1) * 25) -First 25 | ForEach-Object { $s = Get-GIRunSummary $_; $s })
    $lkg = Get-GILastKnownGood -Config $d.ImageConfig
    Send-GIHtml (New-GIImageRunsPage -Summary $d.Summary -Ctx (Get-GIViewContext) -Runs $slice -Total $all.Count -Page $page -PageSize 25 -Status $status -LastKnownGoodRunId $(if ($lkg) { [string]$lkg.runId } else { '' }))
}

function Send-GICurrentRunRoute {
    param($Context, $WebEvent)
    Set-GINavContext -Context $Context -WebEvent $WebEvent
    $d = Get-GIImageRouteData $Context $WebEvent; if (-not $d) { return }
    $act = $d.Summary.activeRun
    $to = if ($act) { "/images/$($d.Id)/runs/$($act.runId)" } else { "/images/$($d.Id)/runs" }
    Move-PodeResponseUrl -Url $to
}

function Send-GIRunRoute {
    param($Context, $WebEvent)
    Set-GINavContext -Context $Context -WebEvent $WebEvent
    $d = Get-GIImageRouteData $Context $WebEvent; if (-not $d) { return }
    $runId = [string]$WebEvent.Parameters['runId']
    $res = Invoke-GIApiRequest -Config $d.Config -Method GET -Path "/api/images/$($d.Id)/runs/$runId" -Role Viewer
    if ($res.Code -ne 200) { Send-GIHtml (New-GIRunNotFoundPage -ImageId $d.Id) 404; return }
    Send-GIHtml (New-GIRunPage -Detail $res.Body -Summary $d.Summary -Ctx (Get-GIViewContext))
}

function Send-GILegacyRunRoute {
    # /runs/{runId} -> /images/{id}/runs/{runId}
    param($Context, $WebEvent)
    Set-GINavContext -Context $Context -WebEvent $WebEvent
    $runId = [string]$WebEvent.Parameters['runId']
    $ic = Find-GIRunImageConfig -Config (Get-GIDashboardConfig $Context) -RunId $runId
    if (-not $ic) { Send-GIHtml (New-GIRunNotFoundPage) 404; return }
    Move-PodeResponseUrl -Url "/images/$($ic.ImageId)/runs/$runId"
}

function Send-GIFileRoute {
    # /reports/{runId} (html) and /logs/{runId} (text) from the owning image's folders
    param($Context, $WebEvent, [ValidateSet('report', 'log')][string]$Kind)
    Set-GINavContext -Context $Context -WebEvent $WebEvent
    $id = [string]$WebEvent.Parameters['runId']
    $ic = Find-GIRunImageConfig -Config (Get-GIDashboardConfig $Context) -RunId $id
    $file = if ($ic) { if ($Kind -eq 'report') { Join-Path $ic.Paths.Reports "$id.html" } else { Join-Path $ic.Paths.Logs "$id.log" } }
    if (-not $file -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { Send-GIError 404 "$(if ($Kind -eq 'report') { 'Report' } else { 'Log' }) not found."; return }
    if ($Kind -eq 'report') {
        # Reports are generated HTML; lock down what they may load.
        Add-PodeHeader -Name 'Content-Security-Policy' -Value "default-src 'none'; style-src 'unsafe-inline'; img-src data:"
        Write-PodeHtmlResponse -Value (Get-Content -LiteralPath $file -Raw -Encoding UTF8)
    } else {
        Write-PodeTextResponse -Value (Get-Content -LiteralPath $file -Raw -Encoding UTF8) -ContentType 'text/plain; charset=utf-8'
    }
}

#----- Settings -----

function Get-GISectionNotice { param($WebEvent) switch ($WebEvent.Query['r']) { 'saved' { 'Saved. Changes apply from the next run.' } 'nochange' { 'Nothing changed.' } 'cred' { 'Credential stored.' } 'recheck' { 'Checked the installer folder again.' } default { '' } } }

function Get-GIImageSettingsBody {
    # Body HTML for one per-image section (also used to re-render with errors).
    param($Context, $WebEvent, $D, [string]$Section, $Errors = @{}, $Values = $null, [string]$Notice = '')
    $ctx = Get-GIViewContext
    $user = Get-GIRouteUser $Context $WebEvent
    $token = Get-GIFormToken -Secret $Context.FormSecret -User $user -RunId "imgset:$($D.Id)"
    if ($Section -eq 'General') {
        $runs = @(Get-GIRunList -Config $D.ImageConfig).Count
        $s = $D.Summary
        if ($Values) { $s = [pscustomobject]@{} ; foreach ($p in $D.Summary.GetEnumerator()) { Add-Member -InputObject $s -NotePropertyName $p.Key -NotePropertyValue $p.Value -Force }; foreach ($k in $Values.Keys) { Add-Member -InputObject $s -NotePropertyName ([string]$k).ToLowerInvariant() -NotePropertyValue $Values[$k] -Force } }
        return New-GIImageGeneralBody -Summary $s -Ctx $ctx -Token $token -Errors $Errors -RunCount $runs -Notice $Notice
    }
    if ($Section -eq 'AppVolumes') {
        $pk = if ($Values) { @($Values['TestPackages']) } else { @($D.ImageConfig.AppVolumes.TestPackages) }
        return New-GIImageAppVolumesBody -Summary $D.Summary -Ctx $ctx -Token $token -Packages $pk -Notice $Notice
    }
    $schema = Get-GISettingsSchema
    $data = Get-GISettingsSection -Config $D.ImageConfig -Section $Section
    if ($Values) { foreach ($k in $Values.Keys) { $data.Values[$k] = $Values[$k] } }
    $label = (@(Get-GIImageSettingsSections | Where-Object { $_.Key -eq $Section }) | Select-Object -First 1).Label
    $p = @{ Schema = $schema; SectionKey = $Section; SectionData = $data; Errors = $Errors; Token = $token; Notice = $Notice; IsHttps = [bool]$Context.IsHttps
        FormAction = "/images/$($D.Id)/settings/$Section"; CredAction = "/images/$($D.Id)/settings/$Section/credential"
        DescSuffix = "These settings apply to $($D.Summary.name) only and take effect from the next run."; BodyOnly = $true; ImageName = [string]$D.Summary.name }
    if (-not $ctx.IsAdmin) { $p.Disabled = $true }
    $body = New-GISettingsSectionPage @p
    if ($ctx.IsAdmin -and $schema[$Section]['Test']) { $body += New-GITestConnectionCard -Section $Section -ImageId $D.Id }
    return $body
}

function Send-GIImageSettingsRoute {
    param($Context, $WebEvent)
    Set-GINavContext -Context $Context -WebEvent $WebEvent
    $d = Get-GIImageRouteData $Context $WebEvent; if (-not $d) { return }
    $section = [string]$WebEvent.Parameters['section']; if (-not $section) { $section = 'General' }
    if ($section -notin @(Get-GIImageSettingsSections | ForEach-Object { $_.Key })) { Send-GIError 404 'Unknown settings section.'; return }
    $body = Get-GIImageSettingsBody -Context $Context -WebEvent $WebEvent -D $d -Section $section -Notice (Get-GISectionNotice $WebEvent)
    Send-GIHtml (New-GIImageSettingsPage -Summary $d.Summary -Ctx (Get-GIViewContext) -Section $section -BodyHtml $body)
}

function Receive-GIImageSettingsRoute {
    param($Context, $WebEvent)
    Set-GINavContext -Context $Context -WebEvent $WebEvent
    $d = Get-GIImageRouteData $Context $WebEvent; if (-not $d) { return }
    $section = [string]$WebEvent.Parameters['section']
    if ($section -notin @(Get-GIImageSettingsSections | ForEach-Object { $_.Key })) { Send-GIError 404 'Unknown settings section.'; return }
    $hdr = @{ Origin = $WebEvent.Request.Headers['Origin']; Host = $WebEvent.Request.Headers['Host'] }
    $why = Get-GIPostRejection -Context $Context -WebEvent $WebEvent -Role Admin -FormId "imgset:$($d.Id)" -Headers $hdr
    if ($why) { Send-GIError $why.Code $why.Message; return }
    $user = Get-GIRouteUser $Context $WebEvent
    $errors = @{}; $values = @{}
    try {
        if ($section -eq 'General') {
            $values = @{ Name = [string]$WebEvent.Data['Name']; Description = [string]$WebEvent.Data['Description']; Os = [string]$WebEvent.Data['Os'] }
            if ($values.Name.Trim() -notmatch '^[A-Za-z0-9][A-Za-z0-9 _-]*$') { $errors.Name = 'Use letters, numbers and dashes.' }
            if ($errors.Count -eq 0) { $res = Save-GIImageSection -Config $d.Config -ImageId $d.Id -Section General -Values $values -By $user }
        } elseif ($section -eq 'AppVolumes') {
            $values = @{ TestPackages = @(([string]$WebEvent.Data['TestPackages']) -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
            $res = Save-GIImageSection -Config $d.Config -ImageId $d.Id -Section AppVolumes -Values $values -By $user
        } else {
            $def = (Get-GISettingsSchema)[$section]
            $conv = ConvertFrom-GISettingsForm -Section $section -Form $WebEvent.Data
            foreach ($k in $conv.Errors.Keys) { $errors[$k] = $conv.Errors[$k] }
            $values = $conv.Values
            $checked = Test-GISettingsSection -Section $section -Values $values
            foreach ($k in $checked.Keys) { if (-not $errors.Contains($k)) { $errors[$k] = $checked[$k] } }
            $cur = Get-GISettingsSection -Config $d.ImageConfig -Section $section
            foreach ($f in $def.Fields) {
                if (-not $f['Confirm']) { continue }
                if ([bool]$cur.Values[$f.Key] -ne [bool]$values[$f.Key] -and -not $WebEvent.Data["confirm_$($f.Key)"]) { $errors[$f.Key] = 'Tick the confirmation box to change this setting.' }
            }
            if ($errors.Count -eq 0) { $res = Save-GIImageSection -Config $d.Config -ImageId $d.Id -Section $section -Values $values -By $user }
        }
    } catch { $errors['_'] = $_.Exception.Message }
    if ($errors.Count) {
        $body = Get-GIImageSettingsBody -Context $Context -WebEvent $WebEvent -D $d -Section $section -Errors $errors -Values $values -Notice 'Not saved: fix the highlighted fields.'
        Send-GIHtml (New-GIImageSettingsPage -Summary $d.Summary -Ctx (Get-GIViewContext) -Section $section -BodyHtml $body) 400
        return
    }
    $r = if (@($res.Changed).Count) { 'saved' } else { 'nochange' }
    Write-GIAudit -Config $d.ImageConfig -User $user -Role 'Admin' -Action 'settings.update' -Target $section -Detail @{ image = $d.Id; section = $section; keys = @($res.Changed) } -Result 'OK'
    Move-PodeResponseUrl -Url "/images/$($d.Id)/settings/$($section)?r=$r"
}

function Receive-GIImageCredentialRoute {
    param($Context, $WebEvent)
    Set-GINavContext -Context $Context -WebEvent $WebEvent
    $d = Get-GIImageRouteData $Context $WebEvent; if (-not $d) { return }
    $section = [string]$WebEvent.Parameters['section']
    $hdr = @{ Origin = $WebEvent.Request.Headers['Origin']; Host = $WebEvent.Request.Headers['Host'] }
    $why = Get-GIPostRejection -Context $Context -WebEvent $WebEvent -Role Admin -FormId "imgset:$($d.Id)" -Headers $hdr
    if ($why) { Send-GIError $why.Code $why.Message; return }
    if (-not $Context.IsHttps) { Send-GIError 403 'Credentials can only be entered over https.'; return }
    $user = Get-GIRouteUser $Context $WebEvent
    try {
        $name = Set-GIImageSecretName -Config $d.Config -ImageId $d.Id -Section $section -Key ([string]$WebEvent.Data['key']) -By $user
        Set-GISecretFromForm -Name $name -UserName ([string]$WebEvent.Data['username']) -Password ([string]$WebEvent.Data['password'])
        Write-GIAudit -Config $d.ImageConfig -User $user -Role 'Admin' -Action 'credential.set' -Target $name -Detail @{ image = $d.Id; section = $section; userName = ([string]$WebEvent.Data['username']).Trim() } -Result 'OK'
    } catch {
        $body = Get-GIImageSettingsBody -Context $Context -WebEvent $WebEvent -D $d -Section $section -Notice "Credential not stored: $($_.Exception.Message)"
        Send-GIHtml (New-GIImageSettingsPage -Summary $d.Summary -Ctx (Get-GIViewContext) -Section $section -BodyHtml $body) 400
        return
    }
    Move-PodeResponseUrl -Url "/images/$($d.Id)/settings/$($section)?r=cred"
}

function Get-GIGlobalSettingsBody {
    param($Context, $WebEvent, [string]$Section, $Errors = @{}, $Values = $null, [string]$Notice = '', $TestResult = $null)
    $cfg = Get-GIDashboardConfig $Context
    $ctx = Get-GIViewContext
    if ($Section -eq 'Dashboard') { return New-GIDashboardSettingsBody -Dashboard $cfg.Dashboard }
    if ($Section -eq 'Fixes') { return New-GIFixesBody -Fixes @(Get-GIFixCatalogView -Config $cfg) }
    $user = Get-GIRouteUser $Context $WebEvent
    $schema = Get-GISettingsSchema
    if ($Section -eq 'AppVolumes') {
        # Test packages moved to each image
        $copy = [ordered]@{}; foreach ($k in $schema.Keys) { $copy[$k] = $schema[$k] }
        $sec = @{}; foreach ($k in $schema.AppVolumes.Keys) { $sec[$k] = $schema.AppVolumes[$k] }
        $sec.Fields = @($schema.AppVolumes.Fields | Where-Object { $_.Key -ne 'TestPackages' })
        $sec.Description = 'App Volumes Manager REST API.'
        $copy['AppVolumes'] = $sec; $schema = $copy
    }
    $data = Get-GISettingsSection -Config $cfg -Section $Section
    if ($Values) { foreach ($k in $Values.Keys) { $data.Values[$k] = $Values[$k] } }
    $n = @(Get-GIImageEntries -Config $cfg).Count
    $status = ''
    if ($schema[$Section]['Test']) {
        $cs = Get-GIConnectionStatus -Config $cfg -Section $Section
        $status = New-GIConnectionChipHtml -State $cs.State -At $cs.At
    }
    $p = @{ Schema = $schema; SectionKey = $Section; SectionData = $data; Errors = $Errors; Notice = $Notice; IsHttps = [bool]$Context.IsHttps; BodyOnly = $true; StatusHtml = $status
        Token = (Get-GIFormToken -Secret $Context.FormSecret -User $user -RunId "settings:$Section")
        DescSuffix = "Used by $(if ($n -eq 1) { 'the golden image' } else { "all $n golden images" }). Changes apply from the next run." }
    if (-not $ctx.IsAdmin) { $p.Disabled = $true }
    $body = New-GISettingsSectionPage @p
    if ($ctx.IsAdmin -and $schema[$Section]['Test']) { $body += New-GITestConnectionCard -Section $Section }
    return $body
}

function Send-GIGlobalSettingsRoute {
    param($Context, $WebEvent)
    Set-GINavContext -Context $Context -WebEvent $WebEvent
    $section = [string]$WebEvent.Parameters['section']; if (-not $section) { $section = 'vCenter' }
    if ($section -notin @(Get-GIGlobalSettingsSections | ForEach-Object { $_.Key })) { Send-GIError 404 'Unknown settings section.'; return }
    $body = Get-GIGlobalSettingsBody -Context $Context -WebEvent $WebEvent -Section $section -Notice (Get-GISectionNotice $WebEvent)
    Send-GIHtml (New-GIGlobalSettingsPage -Ctx (Get-GIViewContext) -Section $section -BodyHtml $body)
}

function Receive-GIGlobalSettingsRoute {
    param($Context, $WebEvent)
    Set-GINavContext -Context $Context -WebEvent $WebEvent
    $sk = [string]$WebEvent.Parameters['section']
    if ($sk -notin 'vCenter', 'Horizon', 'AppVolumes', 'Email') { Send-GIError 400 'This section is read-only.'; return }
    $hdr = @{ Origin = $WebEvent.Request.Headers['Origin']; Host = $WebEvent.Request.Headers['Host'] }
    $why = Get-GIPostRejection -Context $Context -WebEvent $WebEvent -Role Admin -FormId "settings:$sk" -Headers $hdr
    if ($why) { Send-GIError $why.Code $why.Message; return }
    $user = Get-GIRouteUser $Context $WebEvent
    $cfg = Get-GIDashboardConfig $Context
    $schema = Get-GISettingsSchema
    $conv = ConvertFrom-GISettingsForm -Section $sk -Form $WebEvent.Data
    $errors = @{}; foreach ($k in $conv.Errors.Keys) { $errors[$k] = $conv.Errors[$k] }
    $values = $conv.Values
    if ($sk -eq 'AppVolumes') { $null = $values.Remove('TestPackages') }
    $checked = Test-GISettingsSection -Section $sk -Values $(if ($sk -eq 'AppVolumes') { $v = @{}; foreach ($k in $values.Keys) { $v[$k] = $values[$k] }; $v['TestPackages'] = @(); $v } else { $values })
    foreach ($k in $checked.Keys) { if (-not $errors.Contains($k)) { $errors[$k] = $checked[$k] } }
    if ($errors.Count -eq 0) {
        try { $res = Save-GISettingsSection -Config $cfg -Section $sk -Values $values -By $user } catch { $errors['_'] = $_.Exception.Message }
    }
    if ($errors.Count) {
        $body = Get-GIGlobalSettingsBody -Context $Context -WebEvent $WebEvent -Section $sk -Errors $errors -Values $values -Notice 'Not saved: fix the highlighted fields.'
        Send-GIHtml (New-GIGlobalSettingsPage -Ctx (Get-GIViewContext) -Section $sk -BodyHtml $body) 400
        return
    }
    $r = if (@($res.Changed).Count) { 'saved' } else { 'nochange' }
    if (@($res.Changed).Count) { Write-GIAudit -Config $cfg -User $user -Role 'Admin' -Action 'settings.update' -Target $sk -Detail @{ section = $sk; keys = @($res.Changed) } -Result 'OK' }
    Move-PodeResponseUrl -Url "/settings/$($sk)?r=$r"
}

#----- Wizard, audit -----

function Send-GIWizardRoute {
    param($Context, $WebEvent)
    Set-GINavContext -Context $Context -WebEvent $WebEvent
    if (-not (Get-GIViewContext).IsAdmin) { Send-GIError 403 'Only Admins can add golden images.'; return }
    $cfg = Get-GIDashboardConfig $Context
    $dummy = @{ GoldenImage = @{ Actions = @(); InstallerSourceDir = '' } }
    Send-GIHtml (New-GIWizardPage -Ctx (Get-GIViewContext) -Installers (Get-GIInstallerStatus -Config (Merge-GIHashtable -Base $cfg -Overlay $dummy)))
}

function Get-GIAuditFilter {
    param($WebEvent)
    $f = @{}
    foreach ($k in 'image', 'category', 'user', 'from', 'to') { $v = [string]$WebEvent.Query[$k]; if ($v) { $f[$k] = $v } }
    if ($f.ContainsKey('category') -and $f.category -notin 'approval', 'run', 'poolvm', 'settings', 'signin') { $null = $f.Remove('category') }
    foreach ($k in 'from', 'to') { if ($f.ContainsKey($k)) { $d = [datetime]::MinValue; if (-not [datetime]::TryParse($f[$k], [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$d)) { $null = $f.Remove($k) } } }
    return $f
}

function Invoke-GIAuditSearch {
    param($Config, [hashtable]$Filter, [int]$Page, [switch]$All)
    $p = @{ Config = $Config; Page = $Page; PageSize = 50 }
    if ($Filter.ContainsKey('image')) { $p.Image = $Filter.image }
    if ($Filter.ContainsKey('category')) { $p.Category = $Filter.category }
    if ($Filter.ContainsKey('user')) { $p.User = $Filter.user }
    if ($Filter.ContainsKey('from')) { $p.From = [datetime]::Parse($Filter.from, [cultureinfo]::InvariantCulture) }
    if ($Filter.ContainsKey('to')) { $p.To = [datetime]::Parse($Filter.to, [cultureinfo]::InvariantCulture) }
    if ($All) { $p.All = $true }
    Search-GIAudit @p
}

function Send-GIAuditRoute {
    param($Context, $WebEvent)
    Set-GINavContext -Context $Context -WebEvent $WebEvent
    $cfg = Get-GIDashboardConfig $Context
    $filter = Get-GIAuditFilter $WebEvent
    $page = 1; if (-not [int]::TryParse([string]$WebEvent.Query['page'], [ref]$page) -or $page -lt 1) { $page = 1 }
    $res = Invoke-GIAuditSearch -Config $cfg -Filter $filter -Page $page
    $users = @(Get-GIAudit -Config $cfg -Last 5000 | ForEach-Object { [string]$_.user } | Where-Object { $_ } | Sort-Object -Unique)
    $images = @(Get-GIImageEntries -Config $cfg | ForEach-Object { $_.Id })
    Send-GIHtml (New-GIAuditLogPage -Entries $res.Entries -Total $res.Total -Page $res.Page -PageSize $res.PageSize -Images $images -Users $users -Filter $filter)
}

function Send-GIAuditCsvRoute {
    param($Context, $WebEvent)
    Set-GINavContext -Context $Context -WebEvent $WebEvent
    $res = Invoke-GIAuditSearch -Config (Get-GIDashboardConfig $Context) -Filter (Get-GIAuditFilter $WebEvent) -Page 1 -All
    Add-PodeHeader -Name 'Content-Disposition' -Value 'attachment; filename="audit-log.csv"'
    Write-PodeTextResponse -Value (ConvertTo-GIAuditCsv -Entries $res.Entries) -ContentType 'text/csv; charset=utf-8'
}
