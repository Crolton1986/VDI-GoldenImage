[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Helpers return heterogeneous values by design.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '', Justification = 'Internal view helpers.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-* functions only build strings; nothing is changed.')]
param()

# Golden image pages: home (cards), image page (Overview, Runs, Settings), run page, add wizard, audit log, global settings.
# Pure view functions. Needs DashboardViews.ps1 and Components.ps1 loaded first. First paint comes from stored data only;
# live values (VM power, pool snapshots) are filled in by the page script from /api/images/{id}/live.

function Get-GIViewContext {
    # Role flags and the CSRF token of the current request (set by Set-GINavContext).
    [CmdletBinding()]
    param()
    $c = @{ IsAdmin = $false; IsApprover = $false; Role = 'Viewer'; Token = ''; UserName = '' }
    $g = Get-Variable -Name GINavContext -Scope Global -ErrorAction SilentlyContinue
    if ($g -and $g.Value -is [System.Collections.IDictionary]) { foreach ($k in $g.Value.Keys) { $c[[string]$k] = $g.Value[$k] } }
    return $c
}

function Format-GIAgo {
    [CmdletBinding()]
    [OutputType([string])]
    param($Since, [datetime]$Now = (Get-Date))
    $d = ConvertTo-GIDateTime $Since
    if ($null -eq $d) { return '' }
    $ts = $Now - $d
    if ($ts.TotalSeconds -lt 0) { $ts = [timespan]::Zero }
    if ($ts.TotalMinutes -lt 1) { return "$([int]$ts.TotalSeconds) seconds" }
    if ($ts.TotalHours -lt 1) { return "$([int]$ts.TotalMinutes)m" }
    if ($ts.TotalDays -lt 1) { return '{0}h {1:00}m' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes }
    return '{0} days' -f [int][math]::Floor($ts.TotalDays)
}

function Get-GIImageChipSpec {
    <# State chip from stored data only. Idle images render as 'Checking...' until the live check answers (the page script then sets the final chip). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Summary, [switch]$Final)
    if ($Summary.paused) { return @{ Text = 'Paused'; Variant = 'idle' } }
    $act = $Summary.activeRun
    if ($act -and $act.status -eq 'AwaitingApproval') { return @{ Text = 'Awaiting approval'; Variant = 'warn' } }
    if ($act -and $act.status -eq 'Running') { return @{ Text = 'Running'; Variant = 'run' } }
    $last = $Summary.lastRun
    if (-not $last) { return @{ Text = 'Never run'; Variant = 'idle' } }
    if ($last.status -in 'Failed') { return @{ Text = 'Failed'; Variant = 'bad' } }
    if ($last.status -eq 'RolledBack') { return @{ Text = 'Rolled back'; Variant = 'warn' } }
    if ($Final) { return @{ Text = 'Up to date'; Variant = 'ok' } }
    return @{ Text = 'Checking...'; Variant = 'idle' }
}

function Get-GIStageTrackerHtml {
    <# Eight segments from the run summary's stage states, aria-hidden (the caption carries the same words). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run)
    $names = Get-GIViewStageOrder
    $st = @($Run.stages)
    $segs = for ($i = 0; $i -lt 8; $i++) {
        $s = if ($i -lt $st.Count) { [string]$st[$i] } else { 'Pending' }
        $cls = switch ($s) { 'Succeeded' { 'done' } 'Running' { 'running' } 'Failed' { 'failed' } 'Skipped' { 'done' } default { '' } }
        if ($names[$i] -eq 'Approval' -and $Run.status -eq 'AwaitingApproval') { $cls = 'waiting' }
        "<span class=""$cls""></span>"
    }
    "<div class=""bars"" aria-hidden=""true"">$(@($segs) -join '')</div>"
}

function Get-GIStageCaption {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Run)
    $names = Get-GIViewStageOrder
    $idx = [array]::IndexOf($names, [string]$Run.currentStage)
    if ($Run.status -eq 'AwaitingApproval') { return "Stage 6 of 8: Approval. Waiting $(Format-GIAgo $Run.updatedAt)." }
    if ($Run.status -eq 'Failed') { return "Failed at $($Run.currentStage)$(if ($Run.error) { ': ' + $Run.error })" }
    if ($idx -lt 0) { return 'Starting' }
    $t = "Stage $($idx + 1) of 8: $($Run.currentStage)."
    if ($Run.currentStage -eq 'Maintain' -and $Run.stepsTotal -gt 0) { $t += " Step $([math]::Min($Run.stepsDone + 1, $Run.stepsTotal)) of $($Run.stepsTotal)$(if ($Run.progress) { ', ' + $Run.progress })." }
    return $t
}

function New-GIPoolRowsHtml {
    # Pool rows from config, live fields as skeletons. Rows past the third start hidden; the page script re-sorts after the live answer.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Summary)
    $pools = @(@($Summary.testPool) + @($Summary.productionPools) | Where-Object { $_ })
    $rows = for ($i = 0; $i -lt $pools.Count; $i++) {
        $isTest = ($i -eq 0)
        $extra = if ($i -ge 3) { ' hidden data-extra' } else { '' }
        "<tr data-pool=""$(ConvertTo-GIHtml $pools[$i])"" data-test=""$($isTest.ToString().ToLower())""$extra><td>$(ConvertTo-GIHtml $pools[$i])</td><td class=""mono"" data-col=""snapshot"">$(New-GISkeleton -Label 'Snapshot' -Width 110)</td><td data-col=""state"">$(New-GISkeleton -Label 'State' -Width 52)</td></tr>"
    }
    $more = ''
    if ($pools.Count -gt 3) { $more = "<button type=""button"" class=""linkbtn"" data-more-pools aria-expanded=""false"" data-n=""$($pools.Count - 3)"">Show $($pools.Count - 3) more pools</button>" }
    "<table class=""pooltable""><thead><tr><th scope=""col"">Pool</th><th scope=""col"">Snapshot</th><th scope=""col"">State</th></tr></thead><tbody>$(@($rows) -join '')</tbody></table>$more"
}

function New-GIImageCard {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Summary, [Parameter(Mandatory)]$Ctx)
    $id = ConvertTo-GIHtml $Summary.id
    $name = ConvertTo-GIHtml $Summary.name
    $chip = Get-GIImageChipSpec $Summary
    $act = $Summary.activeRun; $last = $Summary.lastRun
    $sub = ConvertTo-GIHtml ((@($Summary.os, $Summary.vm) | Where-Object { $_ }) -join ' · ')
    $facts = "<div><dt>Guest VM</dt><dd data-live=""power"">$(New-GISkeleton -Label 'Power state' -Width 90)</dd></div>"
    if ($act) { $facts += "<div><dt>Run</dt><dd>$(Format-GIDate $act.createdAt)</dd></div>" }
    elseif ($last) {
        $res = if ($last.status -eq 'Completed' -or $last.status -eq 'Scheduled') { 'succeeded' } else { ([string]$last.status).ToLower() }
        $facts += "<div><dt>Last run</dt><dd>$(Format-GIDate $last.createdAt), $(ConvertTo-GIHtml $res)</dd></div>"
        $facts += "<div><dt>Next run</dt><dd>$(ConvertTo-GIHtml $Summary.schedule.day) $(ConvertTo-GIHtml $Summary.schedule.time)</dd></div>"
    } else { $facts += '<div><dt>Last run</dt><dd class="muted">Never run</dd></div>' }
    $tracker = ''
    if ($act) { $tracker = "$(Get-GIStageTrackerHtml $act)<p class=""caption"">$(ConvertTo-GIHtml (Get-GIStageCaption $act))</p>" }
    elseif ($last -and $last.status -eq 'Failed') { $tracker = "$(Get-GIStageTrackerHtml $last)<p class=""caption bad"">$(ConvertTo-GIHtml (Get-GIStageCaption $last))</p>" }

    $base = "/images/$id"
    $runLink = if ($act) { "$base/runs/$(ConvertTo-GIHtml $act.runId)" } else { '' }
    $row1 = ''; $row2 = @()
    if ($Summary.paused) {
        $row2 += New-GIButton -Label 'History' -Href "$base/runs"
        $row2 += New-GIButton -Label 'Settings' -Href "$base/settings"
    } elseif ($act -and $act.status -eq 'AwaitingApproval') {
        if ($Ctx.IsApprover -or $Ctx.IsAdmin) { $row1 = New-GIButton -Label 'Review and approve' -Variant pri -Href "$runLink#approval" }
        $row2 += New-GIButton -Label 'Current run' -Href $runLink
        $row2 += New-GIButton -Label 'History' -Href "$base/runs"
        $row2 += New-GIButton -Label 'Settings' -Href "$base/settings"
    } elseif ($act) {
        $row2 += New-GIButton -Label 'Current run' -Variant pri -Href $runLink
        $row2 += New-GIButton -Label 'History' -Href "$base/runs"
        $row2 += New-GIButton -Label 'Settings' -Href "$base/settings"
    } elseif ($last -and $last.status -eq 'Failed') {
        $row1 = New-GIButton -Label 'View failed run' -Href "$base/runs/$(ConvertTo-GIHtml $last.runId)#failed"
        if ($Ctx.IsAdmin) { $row2 += New-GIButton -Label 'Start run' -OpensDialog "dlg-start-$($Summary.id)" -Id "start-$($Summary.id)" -Disabled:$false }
        $row2 += New-GIButton -Label 'History' -Href "$base/runs"
        $row2 += New-GIButton -Label 'Settings' -Href "$base/settings"
    } else {
        if ($Ctx.IsAdmin) { $row1 = "<span data-live-btn>$(New-GIButton -Label $(if ($last) { 'Start run' } else { 'Start first run' }) -OpensDialog "dlg-start-$($Summary.id)" -Id "start-$($Summary.id)" -Disabled -Reason 'Checking vCenter and Horizon')</span>" }
        $row2 += New-GIButton -Label 'Current run' -Disabled -Reason 'No active run'
        $row2 += New-GIButton -Label 'History' -Href "$base/runs"
        $row2 += New-GIButton -Label 'Settings' -Href "$base/settings"
    }
    $cls = if ($last -and $last.status -eq 'Failed' -and -not $act) { 'gicard failed' } else { 'gicard' }
    $dlg = ''
    if ($Ctx.IsAdmin) { $dlg = New-GIStartRunDialog -Summary $Summary }
    @"
<section class="card $cls" aria-label="$name" data-image="$id" data-test-pool="$(ConvertTo-GIHtml $Summary.testPool)" data-state="$(ConvertTo-GIHtml $chip.Text)">
<div class="cardhead"><div><h2><a class="cardlink" href="$base">$name</a></h2><div class="muted small">$sub</div></div><span class="chipslot" aria-live="polite">$(New-GIChip -Text $chip.Text -Variant $chip.Variant)</span></div>
<dl class="facts">$facts</dl>
<div class="livemsg" data-live-msg hidden></div>
$tracker
$(New-GIPoolRowsHtml $Summary)
<div class="cardactions"><div class="row1">$row1</div><div class="row2">$(@($row2) -join '')</div></div>
$dlg
</section>
"@
}

function New-GIStartRunDialog {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Summary)
    $body = "<p>This powers on $(ConvertTo-GIHtml $Summary.vm), installs updates and packages, and pushes the new snapshot to the test pool $(ConvertTo-GIHtml $Summary.testPool). Nothing reaches production until someone approves.</p>"
    New-GIModal -Id "dlg-start-$($Summary.id)" -Title "Start a full run for $($Summary.name)?" -BodyHtml $body -ConfirmLabel 'Start run' -Api "POST /api/images/$($Summary.id)/runs" -Then 'reload'
}

function New-GIHomePage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][object[]]$Summaries = @(),
        [Parameter(Mandatory)]$Ctx,
        [int]$Page = 1,
        [int]$LiveRefreshSeconds = 60,
        [bool]$SetupComplete = $true,
        [hashtable]$Checklist = @{}
    )
    $all = @($Summaries | Where-Object { $null -ne $_ })
    $pageSize = 9
    $pages = [math]::Max(1, [int][math]::Ceiling($all.Count / $pageSize))
    $Page = [math]::Min([math]::Max(1, $Page), $pages)
    $shown = @($all | Select-Object -Skip (($Page - 1) * $pageSize) -First $pageSize)
    $add = if ($Ctx.IsAdmin) { New-GIButton -Label 'Add golden image' -Variant pri -Href '/images/new' } else { '' }
    $head = "<div class=""pagehead""><div><h1>Golden images</h1><p class=""muted"" id=""gi-updated"" role=""status"">Checking vCenter and Horizon...</p></div><div class=""headbtns"">$(New-GIButton -Label 'Refresh' -Id 'gi-refresh')$add</div></div>"
    if ($all.Count -eq 0) {
        $items = ''
        if ($Checklist.Count) { $items = '<ul class="checklist">' + ((@('vCenter connected', 'Horizon connected', 'PowerCLI installed') | ForEach-Object { $ok = [bool]$Checklist[$_]; "<li>$(if ($ok) { '&#10004;' } else { '&#9675;' }) $(ConvertTo-GIHtml $_)</li>" }) -join '') + '</ul>' }
        $cta = if (-not $SetupComplete -and $Ctx.IsAdmin) { "<p>Finish setup first.</p>$(New-GIButton -Label 'Open Setup' -Variant pri -Href '/setup')" }
        elseif ($Ctx.IsAdmin) { New-GIButton -Label 'Add golden image' -Variant pri -Href '/images/new' }
        else { '<p class="muted">An Admin needs to add the first golden image.</p>' }
        $empty = "<section class=""card empty""><h2>No golden images yet</h2><p>A golden image is the VM you patch each month, plus the pools it feeds. Add your first one to start.</p>$items$cta</section>"
        return New-GIPage -Title 'Golden images' -BodyHtml "$head$empty"
    }
    # Approval banner: only for roles that can approve, one line per waiting image, up to 3
    $banner = ''
    if ($Ctx.IsApprover -or $Ctx.IsAdmin) {
        $wait = @($all | Where-Object { $_.activeRun -and $_.activeRun.status -eq 'AwaitingApproval' })
        if ($wait.Count) {
            $lines = foreach ($w in ($wait | Select-Object -First 3)) {
                "<div class=""banner""><span class=""banner-text""><strong>$(ConvertTo-GIHtml $w.name)</strong> is waiting for approval. Test pool validation passed $(Format-GIAgo $w.activeRun.updatedAt) ago.</span><a href=""/images/$(ConvertTo-GIHtml $w.id)/runs/$(ConvertTo-GIHtml $w.activeRun.runId)#approval"">Review and approve</a></div>"
            }
            $more = if ($wait.Count -gt 3) { "<p class=""muted"">and $($wait.Count - 3) more</p>" } else { '' }
            $banner = "<div class=""banners"">$(@($lines) -join '')$more</div>"
        }
    }
    $cards = @($shown | ForEach-Object { New-GIImageCard -Summary $_ -Ctx $Ctx })
    if ($Ctx.IsAdmin -and $all.Count -lt $pageSize -and $Page -eq $pages) {
        $cards += "<section class=""card addtile"" aria-label=""Add a golden image""><h2>Add a golden image</h2><p class=""muted"">Pick a guest VM and its pools, choose what to install, and set a schedule.</p>$(New-GIButton -Label 'Add golden image' -Variant pri -Href '/images/new')</section>"
    }
    $pager = ''
    if ($pages -gt 1) {
        $prev = if ($Page -gt 1) { New-GIButton -Label 'Previous' -Variant sec -Small -Href "/?page=$($Page - 1)" } else { New-GIButton -Label 'Previous' -Variant sec -Small -Disabled -Reason 'First page' }
        $next = if ($Page -lt $pages) { New-GIButton -Label 'Next' -Variant sec -Small -Href "/?page=$($Page + 1)" } else { New-GIButton -Label 'Next' -Variant sec -Small -Disabled -Reason 'Last page' }
        $pager = "<nav class=""pager"" aria-label=""Pages"">$prev<span>Page $Page of $pages</span>$next</nav>"
    }
    $foot = "<p class=""muted small"">Showing $($shown.Count) of $($all.Count) golden images. Nine fit per page. Cards show up to 3 pools, then ""Show N more pools"".</p>"
    $body = "$head<div id=""gi-banner-slot"">$banner</div><div class=""cardgrid"" data-refresh=""$LiveRefreshSeconds"">$(@($cards) -join '')</div>$pager$foot<script>$(Get-GIHomeScript)</script>"
    New-GIPage -Title 'Golden images' -BodyHtml $body
}

#----- Image page -----

function New-GIImageHeader {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Summary, [Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][ValidateSet('overview', 'runs', 'settings')][string]$Tab)
    $id = ConvertTo-GIHtml $Summary.id
    $chip = Get-GIImageChipSpec $Summary
    $sub = ConvertTo-GIHtml ((@($Summary.os, $Summary.vm) | Where-Object { $_ }) -join ' · ')
    $start = ''
    if ($Ctx.IsAdmin -and -not $Summary.paused) {
        $label = if ($Summary.lastRun) { 'Start run' } else { 'Start first run' }
        $busy = [bool]$Summary.activeRun
        $start = New-GIButton -Label $label -OpensDialog "dlg-start-$($Summary.id)" -Id 'hdr-start' -Disabled:$busy -Reason $(if ($busy) { 'A run is in progress' } else { '' })
    }
    $tabs = New-GITabs -Tabs @(@{ Label = 'Overview'; Href = "/images/$id"; Key = 'overview' }, @{ Label = 'Runs'; Href = "/images/$id/runs"; Key = 'runs' }, @{ Label = 'Settings'; Href = "/images/$id/settings"; Key = 'settings' }) -Selected $Tab -AriaLabel 'Image sections'
    $dlg = if ($Ctx.IsAdmin) { New-GIStartRunDialog -Summary $Summary } else { '' }
    $runBanner = ''
    if ($Summary.activeRun) { $runBanner = New-GIBanner -Text "Run $($Summary.activeRun.runId) is in progress." -LinkText 'Current run' -LinkHref "/images/$($Summary.id)/runs/$($Summary.activeRun.runId)" }
    @"
<div><a class="btn small" href="/" id="gi-back"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" aria-hidden="true"><path d="m15 5-7 7 7 7"/></svg> Back to all images</a></div>
<div class="pagehead"><div><h1>$(ConvertTo-GIHtml $Summary.name) <span class="chipslot" aria-live="polite" id="gi-statechip">$(New-GIChip -Text $chip.Text -Variant $chip.Variant)</span></h1><p class="muted" id="gi-sub">$sub · <span id="gi-updated">checking...</span></p></div><div class="headbtns">$start</div></div>
$runBanner
$tabs
$dlg
"@
}

function Get-GIImageSettingsLink { param($Summary, [string]$Section = '') "/images/$(ConvertTo-GIHtml $Summary.id)/settings$(if ($Section) { '/' + $Section })" }

function New-GIImageOverviewPage {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Summary, [Parameter(Mandatory)]$Ctx, [int]$SnapshotsKept = 0, [string]$Notice = '')
    $id = ConvertTo-GIHtml $Summary.id
    $act = $Summary.activeRun; $last = $Summary.lastRun
    $head = New-GIImageHeader -Summary $Summary -Ctx $Ctx -Tab overview
    $busyReason = 'A run is in progress'
    $locked = [bool]$act
    # Last run strip
    if ($act) {
        $strip = "<div class=""strip""><span>Run <a class=""mono"" href=""/images/$id/runs/$(ConvertTo-GIHtml $act.runId)"">$(ConvertTo-GIHtml $act.runId)</a> $(New-GIChip -Text $(if ($act.status -eq 'AwaitingApproval') { 'Awaiting approval' } else { 'Running' }) -Variant $(if ($act.status -eq 'AwaitingApproval') { 'warn' } else { 'run' })) $(ConvertTo-GIHtml (Get-GIStageCaption $act))</span>$(New-GIButton -Label 'Current run' -Small -Href "/images/$id/runs/$(ConvertTo-GIHtml $act.runId)")</div>"
    } elseif ($last) {
        $variant = switch ($last.status) { 'Failed' { 'bad' } 'Rejected' { 'bad' } 'RolledBack' { 'warn' } default { 'ok' } }
        $text = switch ($last.status) { 'Completed' { 'Succeeded' } 'Scheduled' { 'Scheduled' } 'RolledBack' { 'Rolled back' } default { [string]$last.status } }
        $strip = "<div class=""strip""><span>Last run <a class=""mono"" href=""/images/$id/runs/$(ConvertTo-GIHtml $last.runId)"">$(ConvertTo-GIHtml $last.runId)</a> $(New-GIChip -Text $text -Variant $variant) $(Format-GIDate $last.updatedAt)</span><span>Next run $(ConvertTo-GIHtml $Summary.schedule.day) $(ConvertTo-GIHtml $Summary.schedule.time)</span></div>"
    } else {
        $strip = "<div class=""strip""><span>No runs yet. The first run patches the guest, takes a snapshot, and pushes it to the test pool. Pools show ""No image pushed yet"" until then.</span></div>"
    }
    $notice = if ($Notice) { "<div class=""notice"" role=""status"">$(ConvertTo-GIHtml $Notice)</div>" } else { '<div id="gi-action-status" role="status" aria-live="polite" class="muted"></div>' }
    $liveErr = New-GIBanner -Text 'Live check failed.' -Variant error -Id 'gi-live-error' -Hidden
    # Pools table: rows are filled by the page script (live), each with Roll back for admins
    $poolRows = @(@($Summary.testPool) + @($Summary.productionPools) | Where-Object { $_ }) | ForEach-Object -Begin { $i = 0 } -Process {
        $test = ($i -eq 0); $i++
        $pn = ConvertTo-GIHtml $_
        $act2 = ''
        if ($Ctx.IsAdmin) { $act2 = New-GIButton -Label 'Roll back' -Variant dangerline -Small -OpensDialog 'dlg-rollback' -Disabled:$locked -Reason $busyReason -AriaLabel "Roll back $_" }
        $act2 = $act2 -replace '<button ', "<button data-fill-pool=""$pn"" data-fill-match=""$pn"" data-fill-api=""POST /api/images/$id/pools/$([uri]::EscapeDataString($_))/rollback"" "
        "<tr data-pool=""$pn"" data-test=""$($test.ToString().ToLower())""><td>$pn$(if ($test) { ' <span class="muted">(test)</span>' })</td><td class=""mono"" data-col=""snapshot"">$(New-GISkeleton -Label 'Snapshot' -Width 120)</td><td data-col=""state"">$(New-GISkeleton -Label 'State' -Width 60)</td><td data-col=""pushed"" class=""muted"">-</td><td class=""right"">$act2</td></tr>"
    }
    $pools = New-GICard -Title 'Pools' -BodyHtml "<div class=""tablewrap""><table class=""poolsfull""><thead><tr><th scope=""col"">Pool</th><th scope=""col"">Snapshot</th><th scope=""col"">State</th><th scope=""col"">Last pushed</th><th scope=""col""><span class=""sr-only"">Actions</span></th></tr></thead><tbody>$(@($poolRows) -join '')</tbody></table></div>"
    $keep = if ($SnapshotsKept -gt 0) { "Retention keeps the last $SnapshotsKept golden image snapshots. Older ones are removed after each run." } else { 'Retention settings are on the Snapshots section of this image''s settings.' }
    $snaps = New-GICard -Title 'Snapshots' -BodyHtml "<div class=""tablewrap""><table><thead><tr><th scope=""col"">Snapshot</th><th scope=""col"">Created</th><th scope=""col"">Used by</th><th scope=""col"">Tag</th><th scope=""col""><span class=""sr-only"">Actions</span></th></tr></thead><tbody id=""gi-snap-rows""><tr><td colspan=""5"">$(New-GISkeleton -Label 'Snapshots' -Width 200)</td></tr></tbody></table></div><p class=""muted small"">$(ConvertTo-GIHtml $keep)</p>"
    # Right column
    $pw = ''
    if ($Ctx.IsAdmin) {
        $pw = "<div class=""btnrow""><span data-power-on hidden>$(New-GIButton -Label 'Power on' -OpensDialog 'dlg-power-on' -Disabled:$locked -Reason $busyReason)</span><span data-power-off hidden>$(New-GIButton -Label 'Power off' -OpensDialog 'dlg-power-off' -Disabled:$locked -Reason $busyReason)</span></div>"
    }
    $vmCard = New-GICard -Title 'Guest VM' -BodyHtml "<dl class=""kv""><dt>Name</dt><dd>$(ConvertTo-GIHtml $Summary.vm)</dd><dt>Power</dt><dd data-live=""power"">$(New-GISkeleton -Label 'Power state' -Width 90)</dd><dt>Current snapshot</dt><dd class=""mono"" data-live=""vmsnap"">$(New-GISkeleton -Label 'Snapshot' -Width 110)</dd></dl>$pw<p class=""muted small"">Power and revert are available only when no run is active. Every action is written to the audit log.</p>"
    $win = "$(ConvertTo-GIHtml (@($Summary.maintenanceWindow.days | ForEach-Object { ([string]$_).Substring(0, 3) }) -join ', ')) $(ConvertTo-GIHtml $Summary.maintenanceWindow.startTime)"
    $auto = if ($Summary.autoPromote) { "On $(New-GIChip -Text 'No approval needed' -Variant warn)" } else { 'Off' }
    $sched = New-GICard -Title 'Schedule' -BodyHtml "<dl class=""kv""><dt>Next run</dt><dd>$(ConvertTo-GIHtml $Summary.schedule.day) $(ConvertTo-GIHtml $Summary.schedule.time)</dd><dt>Promotion window</dt><dd>$win</dd><dt>Auto-approve</dt><dd>$auto</dd></dl><p><a href=""$(Get-GIImageSettingsLink $Summary 'Promotion')"">Change in Settings</a></p>"
    # Dialogs
    $dialogs = ''
    if ($Ctx.IsAdmin) {
        $dialogs += New-GIModal -Id 'dlg-power-on' -Title "Power on $($Summary.vm)?" -BodyHtml '<p>The guest VM starts. Nothing else changes.</p><input type="hidden" name="action" value="on">' -ConfirmLabel 'Power on' -Api "POST /api/images/$id/vm/power"
        $dialogs += New-GIModal -Id 'dlg-power-off' -Title "Power off $($Summary.vm)?" -BodyHtml '<p>The guest operating system is asked to shut down. Unsaved work in the guest is lost.</p><input type="hidden" name="action" value="off">' -ConfirmLabel 'Power off' -ConfirmVariant danger -Api "POST /api/images/$id/vm/power"
        $dialogs += New-GIModal -Id 'dlg-revert' -Title "Revert $($Summary.vm) to a snapshot?" -ConfirmLabel 'Revert VM' -ConfirmVariant danger -Api "POST /api/images/$id/vm/revert" -BodyHtml "<p>Snapshot: <span class=""mono"" data-fill=""snapshot""></span>. The VM's current state and every change since that snapshot will be lost. This cannot be undone.</p><input type=""hidden"" name=""snapshot"" value=""""><div class=""field""><label for=""rv-confirm"">Type <strong>$(ConvertTo-GIHtml $Summary.name)</strong> to confirm</label><input type=""text"" id=""rv-confirm"" autocomplete=""off"" data-must-match=""$(ConvertTo-GIHtml $Summary.name)""></div>"
        $dialogs += New-GIModal -Id 'dlg-rollback' -Title 'Roll back a pool?' -ConfirmLabel 'Roll back' -ConfirmVariant danger -Api "POST /api/images/$id/pools/x/rollback" -BodyHtml "<p>Pool: <strong data-fill=""pool""></strong>. The pool is pushed to the snapshot you pick. This does not create a run.</p><div class=""field""><label for=""rb-snap"">Snapshot</label><select id=""rb-snap"" name=""snapshot""><option value="""">Last known good</option></select></div><div class=""field""><label><input type=""checkbox"" name=""forceLogoff"" value=""on""> Force logoff</label><div class=""help"">Ends active sessions on this pool.</div></div><div class=""field""><label for=""rb-start"">Start</label><input type=""datetime-local"" id=""rb-start"" name=""startTime""><div class=""help"">Leave empty to start now.</div></div><div class=""field""><label for=""rb-confirm"">Type the pool name to confirm</label><input type=""text"" id=""rb-confirm"" autocomplete=""off"" data-must-match=""""></div>"
    }
    $cols = "<div class=""twocol""><div class=""col main"">$pools$snaps</div><div class=""col side"">$vmCard$sched</div></div>"
    $body = "$head$notice$liveErr$strip$cols$dialogs<script>$(Get-GIOverviewScript -ImageId $Summary.id -IsAdmin ([bool]$Ctx.IsAdmin) -Locked $locked)</script>"
    New-GIPage -Title "$($Summary.name) - Overview" -BodyHtml $body
}

#----- Runs tab -----

function Get-GIRunResultText {
    [CmdletBinding()]
    [OutputType([string])]
    param($Run, [string]$LastKnownGoodRunId = '')
    switch ([string]$Run.status) {
        'AwaitingApproval' { 'Waiting for approval' }
        'Running' { "Running: $($Run.currentStage)" }
        'Failed' { "Failed at $(if ($Run.error) { $Run.currentStage + ': ' + $Run.error } else { $Run.currentStage })" }
        'Rejected' { 'Rejected' }
        'RolledBack' { if ($Run.progress) { [string]$Run.progress } else { 'Rolled back' } }
        'Scheduled' { 'Approved, waiting for the maintenance window' }
        default { if ($Run.runId -eq $LastKnownGoodRunId) { 'Promoted. Last known good.' } else { 'Promoted' } }
    }
}

function New-GIImageRunsPage {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Summary, [Parameter(Mandatory)]$Ctx, [AllowNull()][object[]]$Runs = @(), [int]$Total = 0, [int]$Page = 1, [int]$PageSize = 25, [string]$Status = '', [string]$LastKnownGoodRunId = '')
    $id = ConvertTo-GIHtml $Summary.id
    $head = New-GIImageHeader -Summary $Summary -Ctx $Ctx -Tab runs
    $opts = foreach ($o in @(@('', 'All'), @('Succeeded', 'Succeeded'), @('Failed', 'Failed'), @('Active', 'Active (Running or Awaiting approval)'))) { "<option value=""$($o[0])""$(if ($o[0] -eq $Status) { ' selected' })>$(ConvertTo-GIHtml $o[1])</option>" }
    $filter = "<form method=""get"" action=""/images/$id/runs"" class=""filterrow""><div class=""field inline""><label for=""f-status"">Status</label><select id=""f-status"" name=""status"" onchange=""this.form.submit()"">$($opts -join '')</select></div><noscript><button type=""submit"" class=""btn small"">Apply</button></noscript><span class=""muted"">Showing $(@($Runs).Count) of $Total runs</span></form>"
    if ($Total -eq 0 -and -not $Status) {
        $empty = "<section class=""card empty""><h2>No runs yet</h2><p>Runs of this image appear here after the first run.</p>$(if ($Ctx.IsAdmin -and -not $Summary.paused) { New-GIButton -Label 'Start first run' -Variant pri -OpensDialog "dlg-start-$($Summary.id)" })</section>"
        return New-GIPage -Title "$($Summary.name) - Runs" -BodyHtml "$head$empty"
    }
    $rows = foreach ($r in @($Runs)) {
        $rid = ConvertTo-GIHtml $r.runId
        $variant = switch ($r.status) { 'Failed' { 'bad' } 'Rejected' { 'bad' } 'AwaitingApproval' { 'warn' } 'RolledBack' { 'warn' } 'Running' { 'run' } default { 'ok' } }
        $text = switch ($r.status) { 'Completed' { 'Succeeded' } 'AwaitingApproval' { 'Awaiting approval' } 'RolledBack' { 'Rolled back' } default { [string]$r.status } }
        $active = if ($r.status -in 'Running', 'AwaitingApproval') { " data-active-run=""$rid""" } else { '' }
        $dur = Format-GIDuration $r.createdAt $(if ($r.status -in 'Running', 'AwaitingApproval') { $null } else { $r.updatedAt })
        $snap = if ($r.snapshot) { "<span class=""mono"">$(ConvertTo-GIHtml $r.snapshot)</span>" } else { '<span class="muted">None</span>' }
        $fragment = if ($r.status -eq 'Failed') { '#failed' } else { '' }
        "<tr$active><th scope=""row""><a class=""mono"" href=""/images/$id/runs/$rid$fragment"">$rid</a></th><td data-col=""stage"">$(ConvertTo-GIHtml $r.currentStage)</td><td data-col=""status"">$(New-GIChip -Text $text -Variant $variant)</td><td>$(Format-GIDate $r.createdAt)</td><td data-col=""duration"">$(ConvertTo-GIHtml $dur)</td><td>$snap</td><td data-col=""result"">$(ConvertTo-GIHtml (Get-GIRunResultText $r $LastKnownGoodRunId))</td><td><a href=""/api/images/$id/runs/$rid/logs.zip"" aria-label=""Download logs for run $rid"">Logs</a></td></tr>"
    }
    $table = "<div class=""tablewrap""><table><thead><tr><th scope=""col"">Run</th><th scope=""col"">Stage</th><th scope=""col"">Status</th><th scope=""col"">Started</th><th scope=""col"">Duration</th><th scope=""col"">Snapshot</th><th scope=""col"">Result</th><th scope=""col"">Logs</th></tr></thead><tbody>$(@($rows) -join '')$(if (-not $rows) { '<tr><td colspan="8" class="muted">No runs match this filter.</td></tr>' })</tbody></table></div>"
    $pages = [math]::Max(1, [int][math]::Ceiling($Total / $PageSize))
    $q = if ($Status) { "status=$([uri]::EscapeDataString($Status))&" } else { '' }
    $prev = if ($Page -gt 1) { New-GIButton -Label 'Previous' -Variant sec -Small -Href "/images/$id/runs?${q}page=$($Page - 1)" } else { New-GIButton -Label 'Previous' -Variant sec -Small -Disabled -Reason 'First page' }
    $next = if ($Page -lt $pages) { New-GIButton -Label 'Next' -Variant sec -Small -Href "/images/$id/runs?${q}page=$($Page + 1)" } else { New-GIButton -Label 'Next' -Variant sec -Small -Disabled -Reason 'Last page' }
    $pager = "<nav class=""pager"" aria-label=""Pages""><span>Page $Page of $pages</span>$prev$next</nav>"
    $js = if (@($Runs | Where-Object { $_.status -in 'Running', 'AwaitingApproval' }).Count) { "<script>$(Get-GIRunsTabScript -ImageId $Summary.id)</script>" } else { '' }
    New-GIPage -Title "$($Summary.name) - Runs" -BodyHtml "$head$(New-GICard -BodyHtml "$filter$table$pager")$js"
}
