[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Helpers return heterogeneous values by design.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '', Justification = 'Internal view helpers.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-* functions only build strings; nothing is changed.')]
param()

# The run page: /images/{id}/runs/{runId}. Built from the API's run detail (Get-GIApiRun body) and the image summary.
# Regions with a data-region attribute are swapped in place by the page script while the run is active.

$script:GIStaleRunMinutes = 10   # warning when a running run has not changed for this long

function Get-GIRunStatusSpec {
    [CmdletBinding()]
    param([string]$Status)
    switch ($Status) {
        'Running' { @{ Text = 'Running'; Variant = 'run' } }
        'AwaitingApproval' { @{ Text = 'Awaiting approval'; Variant = 'warn' } }
        'Scheduled' { @{ Text = 'Scheduled'; Variant = 'run' } }
        'Completed' { @{ Text = 'Succeeded'; Variant = 'ok' } }
        'Succeeded' { @{ Text = 'Succeeded'; Variant = 'ok' } }
        'Failed' { @{ Text = 'Failed'; Variant = 'bad' } }
        'Rejected' { @{ Text = 'Rejected'; Variant = 'bad' } }
        'RolledBack' { @{ Text = 'Rolled back'; Variant = 'warn' } }
        default { @{ Text = $(if ($Status) { $Status } else { 'Pending' }); Variant = 'idle' } }
    }
}

function Get-GIStagePendingText {
    # One line describing what a pending stage will do, from this image's config.
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Stage, $Summary)
    $prod = @($Summary.productionPools).Count
    switch ($Stage) {
        'Preflight' { "Checks vCenter, Horizon and the pools ($($prod + 1) pools)" }
        'Maintain' { "Updates and installs on $($Summary.vm)" }
        'Snapshot' { "Takes the golden image snapshot of $($Summary.vm)" }
        'TestPush' { "Pushes the snapshot to $($Summary.testPool)" }
        'Validate' { "Checks machines and services in $($Summary.testPool)" }
        'Approval' { 'Waits for an approver to approve the new image' }
        'Promote' { "Pushes to $prod production pool$(if ($prod -ne 1) { 's' }) in the promotion window" }
        'PostCheck' { 'Confirms pools are on the new image' }
        default { '' }
    }
}

function Format-GISpan {
    [CmdletBinding()]
    [OutputType([string])]
    param($Start, $End)
    $d = Format-GIDuration $Start $End
    if ($d) { return ('{0}' -f ((ConvertTo-GITimeSpanText $Start $End))) }
    return ''
}

function ConvertTo-GITimeSpanText {
    param($Start, $End)
    $s = ConvertTo-GIDateTime $Start; $e = ConvertTo-GIDateTime $End
    if ($null -eq $s) { return '' }
    if ($null -eq $e) { $e = if ($s.Kind -eq 'Utc') { [datetime]::UtcNow } else { Get-Date } }
    $t = $e - $s
    if ($t.TotalSeconds -lt 0) { return '' }
    '{0:00}:{1:00}:{2:00}' -f [int][math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds
}

function Get-GIRunPhase {
    # Final or active phase of a run for the page logic.
    param($Run)
    switch ([string]$Run.status) {
        'Running' { 'active' } 'AwaitingApproval' { 'active' } 'Scheduled' { 'waiting' }
        default { 'done' }
    }
}

function New-GIRunProgressHtml {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)]$Steps)
    $names = Get-GIViewStageOrder
    $stages = $Run.stages
    $items = foreach ($n in $names) {
        $st = Get-GIValue $stages $n $null
        $status = [string](Get-GIValue $st 'status' 'Pending')
        $cls = switch ($status) { 'Succeeded' { 'done' } 'Running' { 'running' } 'Failed' { 'failed' } 'Skipped' { 'done' } default { '' } }
        $line = switch ($status) {
            'Succeeded' { "Done $(ConvertTo-GITimeSpanText (Get-GIValue $st 'startedAt' $null) (Get-GIValue $st 'endedAt' $null))" }
            'Running' { if ($n -eq 'Approval') { 'Waiting' } else { 'Running' } }
            default { $status }
        }
        if ($n -eq 'Approval' -and $Run.status -eq 'AwaitingApproval') { $cls = 'waiting'; $line = 'Waiting' }
        $cur = if ([string]$Run.currentStage -eq $n -and (Get-GIRunPhase $Run) -ne 'done') { ' aria-current="step"' } else { '' }
        "<li class=""$cls""$cur><div class=""bar"" aria-hidden=""true""></div><strong>$n</strong><span>$(ConvertTo-GIHtml $line)</span></li>"
    }
    # Now line
    $all = @($Steps)
    $running = $all | Where-Object { $_.status -eq 'Running' } | Select-Object -First 1
    $idx = if ($running) { [array]::IndexOf($all, $running) + 1 } else { 0 }
    $ap = Get-GIValue $Run 'approval' $null
    $now = switch ([string]$Run.status) {
        'Running' {
            if ($running) { "Now: <strong>$(ConvertTo-GIHtml $running.label)</strong> (step $idx of $($all.Count), running $(ConvertTo-GITimeSpanText $running.startedAt $null))" }
            else { "Now: <strong>$(ConvertTo-GIHtml $Run.currentStage)</strong>" }
        }
        'AwaitingApproval' { "Waiting for approval for <strong>$(Format-GIAgo (Get-GIValue (Get-GIValue $stages 'Approval' $null) 'startedAt' (Get-GIValue $Run 'updatedAt')))</strong>." }
        'Scheduled' { "Approved by $(ConvertTo-GIHtml (Get-GIValue $ap 'by')). Promotes to the production pools $(Format-GIDate (Get-GIValue $ap 'startTime'))." }
        'Failed' {
            $f = $all | Where-Object { $_.status -eq 'Failed' } | Select-Object -First 1
            $where = if ($f) { "<strong>$(ConvertTo-GIHtml $f.label)</strong> (step $(([array]::IndexOf($all, $f)) + 1) of $($all.Count))" } else { "<strong>$(ConvertTo-GIHtml $Run.currentStage)</strong>" }
            "<span class=""bad"">Failed at $where$(if ($Run.error) { ': ' + (ConvertTo-GIHtml $Run.error) })</span>"
        }
        'Rejected' { "Rejected by $(ConvertTo-GIHtml (Get-GIValue $ap 'by')): $(ConvertTo-GIHtml (Get-GIValue $ap 'comment'))" }
        default { "Finished in $(ConvertTo-GITimeSpanText $Run.createdAt $Run.updatedAt). Snapshot <span class=""mono"">$(ConvertTo-GIHtml (Get-GIValue (Get-GIValue $Run 'snapshot' $null) 'name'))</span> is the last known good." }
    }
    $stale = ''
    if ($Run.status -eq 'Running') {
        $u = ConvertTo-GIDateTime $Run.updatedAt
        if ($u -and ((Get-Date) - $u).TotalMinutes -ge $script:GIStaleRunMinutes) { $stale = "<p class=""muted"" role=""status"">No update from the runner for $($script:GIStaleRunMinutes) minutes. Check the VDI-GI-Runner task on the server.</p>" }
    }
    "<section class=""card"" data-region=""progress""><ol class=""stages"" aria-label=""Stages"">$(@($items) -join '')</ol><div class=""nowline"">$now$stale</div></section>"
}

function New-GIStepTableHtml {
    param($Steps, [string]$ImageId, [string]$RunId)
    $rows = foreach ($s in $Steps) {
        $v = switch ($s.status) { 'Succeeded' { 'ok' } 'Failed' { 'bad' } 'Running' { 'run' } 'Skipped' { 'idle' } default { 'idle' } }
        $log = ''
        if ([int]$s.logLines -gt 0) { $log = "<details class=""steplog"" data-step-log=""$(ConvertTo-GIHtml $s.id)""><summary>Log ($($s.logLines) lines)</summary><pre class=""logbox"" tabindex=""0"" aria-label=""Log for $(ConvertTo-GIHtml $s.label)""></pre></details>" }
        $fix = ''
        foreach ($f in @($s.fixApplied)) { if ($f) { $fid = [string](Get-GIWatcherProp $f 'id' ''); if ($fid) { $fix += "<div class=""small"">Fixed by <a href=""/settings/Fixes"">$(ConvertTo-GIHtml $fid)</a>, attempt $(ConvertTo-GIHtml (Get-GIWatcherProp $f 'attempt' ''))</div>" } } }
        "<tr><th scope=""row"">$(ConvertTo-GIHtml $s.label)</th><td>$(New-GIChip -Text ([string]$s.status) -Variant $v)</td><td>$(Format-GIDate $s.startedAt)</td><td>$(ConvertTo-GITimeSpanText $s.startedAt $s.endedAt)</td><td>$(ConvertTo-GIHtml $s.message)$fix$log</td></tr>"
    }
    "<div class=""tablewrap""><table><thead><tr><th scope=""col"">Step</th><th scope=""col"">Status</th><th scope=""col"">Started</th><th scope=""col"">Duration</th><th scope=""col"">Message</th></tr></thead><tbody>$(@($rows) -join '')</tbody></table></div>"
}

function New-GIMaintainDetailHtml {
    param($Steps, [string]$ImageId, [string]$RunId, [string]$RunStatus)
    $all = @($Steps)
    if ($all.Count -eq 0) { return '<p class="muted">No step list yet.</p>' }
    $done = @($all | Where-Object { $_.status -in 'Succeeded', 'Skipped' -and $_.status -ne 'Running' })
    $ok = @($all | Where-Object { $_.status -eq 'Succeeded' }).Count
    $skip = @($all | Where-Object { $_.status -eq 'Skipped' }).Count
    $failed = @($all | Where-Object { $_.status -eq 'Failed' }) | Select-Object -First 1
    $running = @($all | Where-Object { $_.status -eq 'Running' }) | Select-Object -First 1
    $pending = @($all | Where-Object { $_.status -eq 'Pending' })
    $total = ConvertTo-GISpanTotal $done
    $h = ''
    $summaryText = "$ok step$(if ($ok -ne 1) { 's' }) succeeded$(if ($total) { " ($total)" })$(if ($skip) { ", $skip skipped" })"
    $h += "<details class=""finished"" data-keep=""fin""><summary>$(ConvertTo-GIHtml $summaryText)</summary>$(New-GIStepTableHtml -Steps $done -ImageId $ImageId -RunId $RunId)</details>"
    if ($failed) {
        $idx = [array]::IndexOf($all, $failed) + 1
        $h += "<div class=""stepcard failedstep"" id=""failed""><div class=""cardhead""><strong>$(ConvertTo-GIHtml $failed.label)</strong><span class=""bad"">Failed after $(ConvertTo-GITimeSpanText $failed.startedAt $failed.endedAt)</span></div><p>$(ConvertTo-GIHtml $failed.message)</p><div data-step-log=""$(ConvertTo-GIHtml $failed.id)"" data-open-tail=""200""><pre class=""logbox"" tabindex=""0"" aria-label=""Log for $(ConvertTo-GIHtml $failed.label)""></pre><p class=""small""><a href=""#"" data-full-log>Open full step log</a> · <a href=""#"" data-copy-log>Copy log</a></p></div></div>"
    }
    if ($running) {
        $idx = [array]::IndexOf($all, $running) + 1
        $h += "<div class=""stepcard""><div class=""cardhead""><strong>$(ConvertTo-GIHtml $running.label)</strong><span>Running $(ConvertTo-GITimeSpanText $running.startedAt $null)</span></div><div data-step-log=""$(ConvertTo-GIHtml $running.id)"" data-open-tail=""3""><pre class=""logbox"" tabindex=""0"" aria-label=""Log for $(ConvertTo-GIHtml $running.label)""></pre><p class=""small""><a href=""#"" data-full-log>Open full step log</a></p></div></div>"
    }
    if ($pending.Count) {
        $names = @($pending | ForEach-Object { $_.label })
        $list = if ($names.Count -gt 6) { (($names | Select-Object -First 6) -join ', ') + " and $($names.Count - 6) more" } else { $names -join ', ' }
        $word = if ($failed) { 'not run' } else { 'pending' }
        $h += "<p class=""muted"">$($pending.Count) step$(if ($pending.Count -ne 1) { 's' }) ${word}: $(ConvertTo-GIHtml $list)</p>"
    }
    return $h
}

function ConvertTo-GISpanTotal {
    param($Steps)
    $sec = 0
    foreach ($s in @($Steps)) {
        $a = ConvertTo-GIDateTime $s.startedAt; $b = ConvertTo-GIDateTime $s.endedAt
        if ($a -and $b -and $b -gt $a) { $sec += ($b - $a).TotalSeconds }
    }
    if ($sec -le 0) { return '' }
    '{0:00}:{1:00}:{2:00}' -f [int][math]::Floor($sec / 3600), [int][math]::Floor(($sec % 3600) / 60), [int]($sec % 60)
}

function New-GIApprovalPanelHtml {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Detail, [Parameter(Mandatory)]$Summary, [Parameter(Mandatory)]$Ctx)
    $run = $Detail.run; $ap = Get-GIValue $run 'approval' $null
    $decision = Get-GIValue $ap 'decision' $null
    $name = ConvertTo-GIHtml $Summary.name
    $stage = Get-GIValue (Get-GIValue $run 'stages' $null) 'Approval' $null
    if ($decision) {
        return "<section class=""card approval"" id=""approval"" tabindex=""-1"" data-region=""approval""><h2>Approval: $(ConvertTo-GIHtml $decision)</h2><dl class=""kv""><dt>Decision</dt><dd>$(ConvertTo-GIHtml $decision)</dd><dt>By</dt><dd>$(ConvertTo-GIHtml (Get-GIValue $ap 'by'))</dd><dt>At</dt><dd>$(Format-GIDate (Get-GIValue $ap 'at'))</dd><dt>Comment</dt><dd>$(ConvertTo-GIHtml (Get-GIValue $ap 'comment'))</dd></dl></section>"
    }
    if ($run.status -ne 'AwaitingApproval') { return '' }
    $checks = @(Get-GIValue (Get-GIValue $run 'validation' $null) 'checks' @())
    $rows = foreach ($c in $checks) {
        $p = [bool](Get-GIValue $c 'passed' $false)
        "<tr><td>$(ConvertTo-GIHtml (Get-GIValue $c 'name')): $(ConvertTo-GIHtml (Get-GIValue $c 'detail'))</td><td class=""right"">$(New-GIChip -Text $(if ($p) { 'Pass' } else { 'Fail' }) -Variant $(if ($p) { 'ok' } else { 'bad' }))</td></tr>"
    }
    $snap = ConvertTo-GIHtml (Get-GIValue (Get-GIValue $run 'snapshot' $null) 'name')
    $pools = @($Detail.approval.poolsToUpdate)
    $poolRows = foreach ($p in $pools) {
        $force = ($p.logoffPolicy -eq 'FORCE_LOGOFF')
        "<tr><td>$(ConvertTo-GIHtml $p.name)</td><td>$(if ($force) { 'Force logoff' } else { 'Wait for logoff' })</td></tr>"
    }
    $force = @($pools | Where-Object { $_.logoffPolicy -eq 'FORCE_LOGOFF' } | ForEach-Object { $_.name })
    $forceNote = if ($force.Count) { "<p class=""warnline"">Users on $(ConvertTo-GIHtml ($force -join ', ')) will be signed out.</p>" } else { '' }
    $next = $Detail.approval.nextWindow
    $nextText = if ($next) { ([datetime]$next).ToString('ddd yyyy-MM-dd HH:mm') } else { '' }
    $nextVal = if ($next) { ([datetime]$next).ToString('yyyy-MM-ddTHH:mm') } else { '' }
    $evidence = "<div class=""cols2""><div><h3>Test results on $(ConvertTo-GIHtml $Summary.testPool)</h3><p class=""muted"">Received <span class=""mono"">$snap</span></p><table><tbody>$(@($rows) -join '')</tbody></table></div><div><h3>Approving updates $($pools.Count) production pool$(if ($pools.Count -ne 1) { 's' })</h3><table><tbody>$(@($poolRows) -join '')</tbody></table>$forceNote</div></div>"
    $head = "<div class=""cardhead""><h2>Approval needed for $name</h2><span class=""muted"">Waiting $(Format-GIAgo (Get-GIValue $stage 'startedAt' (Get-GIValue $run 'updatedAt')))</span></div>"
    $canAct = $Ctx.IsApprover -or $Ctx.IsAdmin
    if ($Summary.autoPromote) {
        $settingsLink = if ($Ctx.IsAdmin) { " <a href=""/images/$(ConvertTo-GIHtml $Summary.id)/settings/Promotion"">Change in Settings</a>" } else { '' }
        $foot = "<p>Auto-approve is on. This run promotes automatically at $(ConvertTo-GIHtml $nextText).$settingsLink</p>"
        return "<section class=""card approval"" id=""approval"" tabindex=""-1"" data-region=""approval"">$head$evidence$foot</section>"
    }
    if (-not $canAct) { return "<section class=""card approval"" id=""approval"" tabindex=""-1"" data-region=""approval"">$head$evidence<p class=""muted"">An Approver or Admin decides this run.</p></section>" }
    $rid = ConvertTo-GIHtml $run.runId; $id = ConvertTo-GIHtml $Summary.id
    $fields = "<div class=""cols2""><div class=""field""><label for=""ap-start"">Start time</label><input type=""datetime-local"" id=""ap-start"" value=""$nextVal""><div class=""help"">Defaults to the next promotion window.</div></div><div class=""field""><label for=""ap-comment"">Comment (required to reject)</label><textarea id=""ap-comment"" maxlength=""500""></textarea></div></div>"
    $btns = "<div class=""btnrow"">$(New-GIButton -Label 'Approve' -Variant pri -OpensDialog 'dlg-approve')$(New-GIButton -Label 'Reject' -Variant dangerline -OpensDialog 'dlg-reject')</div>"
        $forceWarn = if ($force.Count) { "<p class=""warnline"">$(ConvertTo-GIHtml ($force -join ', ')) uses Force logoff. Users on that pool will be signed out.</p>" } else { '' }
    $approveBody = "<p>This updates $($pools.Count) production pool$(if ($pools.Count -ne 1) { 's' }) to <span class=""mono"">$snap</span>, starting $(ConvertTo-GIHtml $nextText). Active sessions follow each pool's logoff policy.</p>$forceWarn<input type=""hidden"" name=""startTime"" value=""$nextVal""><input type=""hidden"" name=""comment"" value="""">"
    $dialogs = (New-GIModal -Id 'dlg-approve' -Title "Approve $($Summary.name)?" -BodyHtml $approveBody -ConfirmLabel 'Approve and promote' -Api "POST /api/images/$id/runs/$rid/approve") +
    (New-GIModal -Id 'dlg-reject' -Title 'Reject this run?' -BodyHtml "<p>Production pools stay on their current snapshot. The run ends and the snapshot is kept for review.</p><div class=""field""><label for=""rj-reason"">Reason</label><textarea id=""rj-reason"" name=""comment"" data-required maxlength=""500""></textarea></div>" -ConfirmLabel 'Reject run' -ConfirmVariant danger -Api "POST /api/images/$id/runs/$rid/reject")
    "<section class=""card approval"" id=""approval"" tabindex=""-1"" data-region=""approval"" data-keep-focus>$head$evidence$fields$btns<p class=""muted small"">Auto-approve is off for this image.</p>$dialogs</section>"
}

function New-GIRunPage {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Detail, [Parameter(Mandatory)]$Summary, [Parameter(Mandatory)]$Ctx, [string]$Fragment = '')
    $run = $Detail.run
    $steps = @($Detail.steps)
    $id = ConvertTo-GIHtml $Summary.id; $rid = ConvertTo-GIHtml $run.runId
    $spec = Get-GIRunStatusSpec ([string]$run.status)
    $active = ((Get-GIRunPhase $run) -eq 'active')
    $crumb = "<nav aria-label=""Breadcrumb"" class=""crumbs""><a href=""/"">Golden images</a> / <a href=""/images/$id"">$(ConvertTo-GIHtml $Summary.name)</a> / <a href=""/images/$id/runs"">Runs</a> / <span aria-current=""page"">Run $rid</span></nav>"
    $btns = "$(New-GIButton -Label 'Report' -Small -Href "/reports/$rid")<a class=""btn small"" id=""dl-logs"" href=""/api/images/$id/runs/$rid/logs.zip"" title=""Includes logs from inside the guest VM."" data-preparing>Download all logs</a>$(New-GIButton -Label 'JSON' -Small -Href "/api/images/$id/runs/$rid")"
    $title = "<div class=""pagehead""><h1>Run $rid <span class=""chipslot"" aria-live=""polite"" data-region=""chip"">$(New-GIChip -Text $spec.Text -Variant $spec.Variant)</span></h1><div class=""headbtns"">$btns</div></div>"
    $elapsedEnd = if ($active) { $null } else { $run.updatedAt }
    $snapName = Get-GIValue (Get-GIValue $run 'snapshot' $null) 'name'
    $snap = if ($snapName) { "<span class=""mono"">$(ConvertTo-GIHtml $snapName)</span>" } else { '<span class="muted">Not created yet</span>' }
    $paused = if ($run.status -eq 'AwaitingApproval') { ' (paused for approval)' } else { '' }
    $startAttr = if ($active -and $run.status -eq 'Running') { " data-start=""$(ConvertTo-GIHtml $run.createdAt)""" } else { '' }
    $summaryHtml = "<section class=""card""><dl class=""summary""><div><dt>Guest VM</dt><dd>$(ConvertTo-GIHtml $Summary.vm)<span data-live=""power""></span></dd></div><div><dt>Started</dt><dd>$(Format-GIDate $run.createdAt)</dd></div><div><dt>Elapsed</dt><dd aria-hidden=""true""$startAttr><span data-elapsed>$(ConvertTo-GITimeSpanText $run.createdAt $elapsedEnd)</span>$paused</dd></div><div><dt>Snapshot</dt><dd>$snap</dd></div></dl></section>"
    $progress = New-GIRunProgressHtml -Run $run -Steps $steps
    # Failed alert
    $alert = ''; $dialogs = ''
    if ($run.status -eq 'Failed') {
        $f = $steps | Where-Object { $_.status -eq 'Failed' } | Select-Object -First 1
        $label = if ($f) { $f.label } else { [string]$run.currentStage }
        $fixes = @($f.fixApplied | Where-Object { $_ })
        $fixLine = if ($fixes.Count) { " $(ConvertTo-GIHtml ([string](Get-GIWatcherProp $fixes[0] 'id' ''))) was tried $($fixes.Count) time$(if ($fixes.Count -ne 1) { 's' })." } else { '' }
        $btnHtml = ''
        if ($Ctx.IsAdmin) {
            $stepIdx = if ($f) { [array]::IndexOf($steps, $f) + 1 } else { 1 }
            $btnHtml = "<div class=""btnrow"">$(New-GIButton -Label 'Retry from this step' -Variant dangerline -OpensDialog 'dlg-retry')$(New-GIButton -Label 'Start a new run' -OpensDialog "dlg-start-$($Summary.id)")</div><p class=""muted small"">A new run first reverts the VM to the safety snapshot taken at the start of this run.</p>"
            $stepInput = if ($f) { "<input type=""hidden"" name=""step"" value=""$(ConvertTo-GIHtml $f.id)"">" } else { '' }
            $dialogs += New-GIModal -Id 'dlg-retry' -Title "Retry from $label?" -BodyHtml "<p>The run continues from step $stepIdx. Steps that already succeeded keep their results and do not run again.</p>$stepInput" -ConfirmLabel 'Retry from this step' -Api "POST /api/images/$id/runs/$rid/retry"
            $dialogs += New-GIStartRunDialog -Summary $Summary
        }
        $alert = "<div class=""alert"" role=""alert"" data-region=""alert""><strong>Failed at $(ConvertTo-GIHtml $label)</strong> $(Format-GIDate $run.updatedAt). <a href=""#failed"">Jump to log</a><p>The installer exited with an error. The guest VM is still powered on with the installer files in place.$fixLine</p>$btnHtml</div>"
    }
    $approval = New-GIApprovalPanelHtml -Detail $Detail -Summary $Summary -Ctx $Ctx
    # Succeeded block
    $result = ''
    if ($run.status -in 'Completed', 'Scheduled') {
        $pp = @(Get-GIValue (Get-GIValue $run 'promotion' $null) 'pools' @())
        $result = "<section class=""card"" data-region=""result""><h2>Result</h2><dl class=""kv""><dt>Snapshot</dt><dd class=""mono"">$(ConvertTo-GIHtml $snapName)</dd><dt>Pools updated</dt><dd>$($pp.Count)</dd><dt>Promoted</dt><dd>$(Format-GIDate $run.updatedAt)</dd></dl></section>"
    }
    # Stage list
    $names = Get-GIViewStageOrder
    $rows = foreach ($n in $names) {
        $st = Get-GIValue $run.stages $n $null
        $status = [string](Get-GIValue $st 'status' 'Pending')
        $isWaiting = ($n -eq 'Approval' -and $run.status -eq 'AwaitingApproval')
        $variant = switch ($status) { 'Succeeded' { 'ok' } 'Running' { 'run' } 'Failed' { 'bad' } 'Skipped' { 'idle' } default { 'idle' } }
        $text = $status; if ($isWaiting) { $text = 'Waiting'; $variant = 'warn' }
        $cls = if ($isWaiting) { 'waiting' } elseif ($status -eq 'Running') { 'running' } elseif ($status -eq 'Failed') { 'failed' } else { '' }
        $open = if ($status -in 'Running', 'Failed' -or $isWaiting) { ' open' } else { '' }
        $msg = [string](Get-GIValue $st 'message' '')
        if (-not $msg -and $status -eq 'Pending') { $msg = Get-GIStagePendingText $n $Summary }
        if ($isWaiting) { $msg = 'Decision is made in the panel above' }
        $dur = if ($status -eq 'Pending') { '' } else { ConvertTo-GITimeSpanText (Get-GIValue $st 'startedAt' $null) (Get-GIValue $st 'endedAt' $null) }
        $inner = ''
        if ($n -eq 'Maintain' -and ($status -ne 'Pending')) { $inner = New-GIMaintainDetailHtml -Steps $steps -ImageId $Summary.id -RunId $run.runId -RunStatus $run.status }
        elseif ($status -ne 'Pending') { $inner = "<dl class=""kv""><dt>Started</dt><dd>$(Format-GIDate (Get-GIValue $st 'startedAt' $null))</dd><dt>Ended</dt><dd>$(Format-GIDate (Get-GIValue $st 'endedAt' $null))</dd><dt>Message</dt><dd>$(ConvertTo-GIHtml $msg)</dd></dl>" }
        "<details class=""stagerow $cls"" id=""stage-$n"" data-keep=""stage-$n""$open><summary><strong>$n</strong><span>$(New-GIChip -Text $text -Variant $variant)</span><span>$dur</span><span class=""msg"">$(ConvertTo-GIHtml $msg)</span></summary><div class=""inner"">$inner</div></details>"
    }
    $list = "<div class=""stagelist"" data-region=""stages"">$(@($rows) -join '')</div>"
    $notice = "<div id=""gi-action-status"" role=""status"" aria-live=""polite""></div>"
    $pollAttr = if ($active) { 'true' } else { 'false' }
    $js = "<script>$(Get-GIRunPageScript -ImageId $Summary.id -RunId $run.runId -Poll $active)</script>"
    $body = "$crumb$title$notice$summaryHtml$progress$alert$approval$result$list$dialogs$js"
    New-GIPage -Title "Run $($run.runId)" -BodyHtml $body
}

function New-GIRunNotFoundPage {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$ImageId = '')
    $link = if ($ImageId) { "<a href=""/images/$(ConvertTo-GIHtml $ImageId)/runs"">Back to the Runs tab</a>" } else { '<a href="/">Back to all golden images</a>' }
    New-GIPage -Title 'Run not found' -BodyHtml "<h1>Run not found</h1><p>This run does not exist, or it belongs to an image that was removed from the dashboard.</p><p>$link</p>"
}

function Get-GIRunPageScript {
    [CmdletBinding()]
    param([string]$ImageId, [string]$RunId, [bool]$Poll)
    $idj = ConvertTo-Json -InputObject $ImageId -Compress; $rj = ConvertTo-Json -InputObject $RunId -Compress
    $pl = if ($Poll) { 'true' } else { 'false' }
    @"
document.addEventListener('DOMContentLoaded',function(){
var ID=$idj,RUN=$rj,POLL=$pl,base='/api/images/'+ID+'/runs/'+RUN;
function logFor(box){var step=box.getAttribute('data-step-log'),tail=+box.getAttribute('data-open-tail')||200,pre=box.querySelector('pre');
return window.GI.getJson(base+'/steps/'+encodeURIComponent(step)+'/log?tail='+tail).then(function(r){if(r.ok&&pre){pre.textContent=r.data.lines.map(function(l){return typeof l==='string'?l:(l.text||l.raw||JSON.stringify(l))}).join('\n')}})}
function loadLogs(root){(root||document).querySelectorAll('[data-open-tail]').forEach(logFor)}
document.addEventListener('toggle',function(e){var d=e.target;if(d.matches&&d.matches('details.steplog')&&d.open){var pre=d.querySelector('pre');
window.GI.getJson(base+'/steps/'+encodeURIComponent(d.getAttribute('data-step-log'))+'/log?tail=500').then(function(r){if(r.ok){pre.textContent=r.data.lines.map(function(l){return typeof l==='string'?l:(l.text||JSON.stringify(l))}).join('\n')}})}},true);
document.addEventListener('click',function(e){var a=e.target.closest&&e.target.closest('[data-full-log],[data-copy-log]');if(!a){return}e.preventDefault();var box=a.closest('[data-step-log]');
if(a.hasAttribute('data-full-log')){box.setAttribute('data-open-tail','100000');logFor(box)}
else{var pre=box.querySelector('pre');if(navigator.clipboard){navigator.clipboard.writeText(pre.textContent);window.GI.live('Log copied')}}});
var dl=document.getElementById('dl-logs');if(dl){dl.addEventListener('click',function(){dl.textContent='Preparing...';dl.setAttribute('aria-disabled','true');setTimeout(function(){dl.textContent='Download all logs';dl.removeAttribute('aria-disabled')},6000)})}
var ap=document.getElementById('approval');
document.addEventListener('click',function(e){var o=e.target.closest&&e.target.closest('[data-opens=dlg-approve],[data-opens=dlg-reject]');if(!o){return}
var s=document.getElementById('ap-start'),c=document.getElementById('ap-comment'),m=document.getElementById(o.getAttribute('data-opens'));if(!m){return}
var hs=m.querySelector('input[name=startTime]'),hc=m.querySelector('input[name=comment]'),ta=m.querySelector('textarea[name=comment]');
if(hs&&s){hs.value=s.value}if(hc&&c){hc.value=c.value}if(ta&&c&&!ta.value){ta.value=c.value}});
var el=document.querySelector('[data-start]');
if(el){var t0=new Date(el.getAttribute('data-start')).getTime();setInterval(function(){var s=Math.max(0,Math.floor((Date.now()-t0)/1000)),p=function(n){return (n<10?'0':'')+n};el.querySelector('[data-elapsed]').textContent=p(Math.floor(s/3600))+':'+p(Math.floor(s/60)%60)+':'+p(s%60)},1000)}
loadLogs();
if(location.hash==='#approval'&&ap){ap.focus();ap.scrollIntoView()}
if(location.hash==='#failed'){var f=document.getElementById('failed');if(f){f.scrollIntoView()}}
if(!POLL){return}
var lastStatus=document.querySelector('[data-region=chip]').textContent.trim();
function swap(doc){var open={};document.querySelectorAll('details[data-keep]').forEach(function(d){open[d.getAttribute('data-keep')]=d.open});
['progress','stages','chip','alert','result'].forEach(function(r){var a=document.querySelector('[data-region='+r+']'),b=doc.querySelector('[data-region='+r+']');if(a&&b&&a.innerHTML!==b.innerHTML){a.innerHTML=b.innerHTML}});
var pa=document.querySelector('[data-region=approval]'),pb=doc.querySelector('[data-region=approval]');
if(pa&&pb&&!pa.contains(document.activeElement)&&!pa.querySelector('.modal-backdrop:not([hidden])')){var keep={};pa.querySelectorAll('input[id],textarea[id]').forEach(function(i){keep[i.id]=i.value});if(pa.innerHTML!==pb.innerHTML){pa.innerHTML=pb.innerHTML;for(var k in keep){var n=document.getElementById(k);if(n){n.value=keep[k]}}}}
else if(!pa&&pb){var main=document.querySelector('[data-region=progress]');main.insertAdjacentElement('afterend',pb)}
else if(pa&&!pb){pa.remove()}
document.querySelectorAll('details[data-keep]').forEach(function(d){var k=d.getAttribute('data-keep');if(k in open){d.open=open[k]}});loadLogs()}
function poll(){return fetch(location.pathname,{credentials:'same-origin',headers:{Accept:'text/html'}}).then(function(r){if(r.status===401){var b=document.getElementById('gi-expired');if(b){b.hidden=false}return}
return r.text()}).then(function(t){if(!t){return}var doc=new DOMParser().parseFromString(t,'text/html');swap(doc);
var chip=document.querySelector('[data-region=chip]').textContent.trim();if(chip!==lastStatus){lastStatus=chip;window.GI.live('Run status: '+chip)}
if(!/Running|Awaiting approval/.test(chip)){stop()}}).catch(function(){})}
var stopped=false;function stop(){stopped=true}
window.GI.poll(function(){if(!stopped){poll()}},3);
});
"@
}
