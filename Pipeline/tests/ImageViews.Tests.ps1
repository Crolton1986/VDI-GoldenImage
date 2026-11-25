BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'VDI-GIPipeline.psd1') -Force
    foreach ($f in 'DashboardViews', 'Components', 'SettingsViews', 'ImageViews', 'ImageScripts', 'RunViews', 'AdminViews') { . (Join-Path $PSScriptRoot '..' 'Web' "$f.ps1") }

    function script:Ctx([string]$Role = 'Admin') {
        $global:GINavContext = @{ Path = '/'; IsAdmin = ($Role -eq 'Admin'); IsApprover = ($Role -in 'Admin', 'Approver'); UserName = "LAB\$Role"; Role = $Role; Token = 'tok'; SetupMode = $false; SetupComplete = $true }
        Get-GIViewContext
    }
    function script:Img([string]$Id = 'win11-corp', [string]$Name = 'Win11-Corp', $Last = $null, $Active = $null, [bool]$Paused = $false, [int]$Prod = 2) {
        [ordered]@{ id = $Id; name = $Name; description = ''; os = 'Windows 11'; paused = $Paused; vm = 'GI-W11-01'; testPool = 'TST-W11'
            productionPools = @(1..$Prod | ForEach-Object { "PRD-W11-$_" }); packages = @('Horizon'); autoPromote = $false
            schedule = @{ day = 'Tuesday'; time = '20:00' }; maintenanceWindow = @{ days = @('Saturday'); startTime = '22:00' }
            lastRun = $Last; activeRun = $Active; lastKnownGood = $null }
    }
    function script:Run([string]$Status, [string]$Stage = 'Maintain', [string[]]$Stages = @('Succeeded', 'Running', 'Pending', 'Pending', 'Pending', 'Pending', 'Pending', 'Pending')) {
        [ordered]@{ runId = '20261125-020000'; status = $Status; currentStage = $Stage; createdAt = '2026-11-25T02:00:00'; updatedAt = '2026-11-25T02:30:00'; progress = ''; snapshot = ''; error = ''; approvedBy = ''; stages = $Stages; stepsDone = 3; stepsTotal = 20 }
    }
    function script:Vis([string]$Html) { $x = [regex]::Replace($Html, '(?s)<style>.*?</style>|<script>.*?</script>', ''); $x }
    function script:Buttons([string]$Html) { $Html = [regex]::Replace((Vis $Html), '(?s)<div class="modal-backdrop".*?</form></div></div>|<div class="modal-backdrop".*?</div></div></div>', ''); @([regex]::Matches($Html, '<(?:button|a)[^>]*class="btn[^"]*"[^>]*>[^<]*') | ForEach-Object { ($_.Value -replace '<[^>]*>', '').Trim() }) }
}
AfterAll { Remove-Variable GINavContext -Scope Global -ErrorAction SilentlyContinue }

Describe 'Home page' {
    It 'paints from stored data with skeletons, never waiting on live calls' {
        $c = Ctx; $h = New-GIHomePage -Summaries @(Img) -Ctx $c
        $h | Should -Match 'class="skeleton"'
        $h | Should -Match 'Checking\.\.\.'
        $h | Should -Match '<section class="card gicard" aria-label="Win11-Corp"'
        $h | Should -Match '<h2><a class="cardlink" href="/images/win11-corp">Win11-Corp</a></h2>'
    }
    It 'shows the admin controls only to Admin' {
        $img = Img -Last (Run 'Completed' 'PostCheck')
        (Buttons (New-GIHomePage -Summaries @($img) -Ctx (Ctx 'Admin'))) | Should -Contain 'Add golden image'
        (Buttons (New-GIHomePage -Summaries @($img) -Ctx (Ctx 'Admin'))) | Should -Contain 'Start run'
        foreach ($r in 'Viewer', 'Approver') {
            $b = Buttons (New-GIHomePage -Summaries @($img) -Ctx (Ctx $r))
            $b | Should -Not -Contain 'Add golden image' -Because $r
            $b | Should -Not -Contain 'Start run' -Because $r
            $b | Should -Contain 'Settings'
            $b | Should -Contain 'History'
        }
    }
    It 'awaiting approval: banner and Review and approve for Approver and Admin, none for Viewer' {
        $img = Img -Active (Run 'AwaitingApproval' 'Approval' @('Succeeded', 'Succeeded', 'Succeeded', 'Succeeded', 'Succeeded', 'Running', 'Pending', 'Pending'))
        foreach ($r in 'Approver', 'Admin') { $h = New-GIHomePage -Summaries @($img) -Ctx (Ctx $r); $h | Should -Match 'is waiting for approval'; (Buttons $h) | Should -Contain 'Review and approve' }
        $v = New-GIHomePage -Summaries @($img) -Ctx (Ctx 'Viewer')
        $v | Should -Not -Match 'is waiting for approval'
        (Buttons $v) | Should -Not -Contain 'Review and approve'
        $v | Should -Match 'Stage 6 of 8: Approval'
    }
    It 'running: Current run is the main action and there is no Start run' {
        $h = New-GIHomePage -Summaries @(Img -Active (Run 'Running')) -Ctx (Ctx)
        (Buttons $h) | Should -Not -Contain 'Start run'
        $h | Should -Match 'btn pri"[^>]*>Current run'
        $h | Should -Match 'Stage 2 of 8: Maintain'
    }
    It 'failed: View failed run for everyone, Start run for Admin only, red border' {
        $img = Img -Last (Run 'Failed' 'Maintain' @('Succeeded', 'Failed', 'Pending', 'Pending', 'Pending', 'Pending', 'Pending', 'Pending'))
        (Buttons (New-GIHomePage -Summaries @($img) -Ctx (Ctx 'Viewer'))) | Should -Contain 'View failed run'
        (Buttons (New-GIHomePage -Summaries @($img) -Ctx (Ctx 'Viewer'))) | Should -Not -Contain 'Start run'
        (Buttons (New-GIHomePage -Summaries @($img) -Ctx (Ctx 'Admin'))) | Should -Contain 'Start run'
        (New-GIHomePage -Summaries @($img) -Ctx (Ctx)) | Should -Match 'gicard failed'
    }
    It 'paused: Paused chip, no Start run, no Current run' {
        $h = New-GIHomePage -Summaries @(Img -Paused $true) -Ctx (Ctx)
        $h | Should -Match 'chip idle">Paused'
        (Buttons $h) | Should -Not -Contain 'Start run'
        (Buttons $h) | Should -Not -Contain 'Current run'
    }
    It 'never run shows Start first run disabled until the live check answers' {
        $h = New-GIHomePage -Summaries @(Img) -Ctx (Ctx)
        $h | Should -Match 'Start first run'
        $h | Should -Match 'disabled'
        $h | Should -Match 'title="Checking vCenter and Horizon"'
        $h | Should -Match 'Current run'
        $h | Should -Match 'title="No active run"'
    }
    It 'shows 3 pool rows and a Show N more pools button when there are more' {
        $h = New-GIHomePage -Summaries @(Img -Prod 5) -Ctx (Ctx)
        @([regex]::Matches($h, '<tr data-pool="[^"]*" data-test="[^"]*">')).Count | Should -Be 3
        @([regex]::Matches($h, 'data-extra')).Count | Should -Be 3
        $h | Should -Match 'Show 3 more pools'
    }
    It 'pages nine per page and offers the add tile only when there is room' {
        $ten = 1..10 | ForEach-Object { Img "img-$_" "Image $_" }
        $p1 = New-GIHomePage -Summaries $ten -Ctx (Ctx) -Page 1
        @([regex]::Matches($p1, 'class="card gicard')).Count | Should -Be 9
        $p1 | Should -Match 'Page 1 of 2'
        (Vis $p1) | Should -Not -Match 'class="card addtile"'
        (New-GIHomePage -Summaries $ten -Ctx (Ctx) -Page 2) | Should -Match 'Showing 1 of 10 golden images'
        (New-GIHomePage -Summaries @(Img) -Ctx (Ctx)) | Should -Match 'class="card addtile"'
        (Vis (New-GIHomePage -Summaries @(Img) -Ctx (Ctx 'Viewer'))) | Should -Not -Match 'addtile'
    }
    It 'empty state: Admin gets Add, others get the explanation, incomplete setup points to Setup' {
        (Buttons (New-GIHomePage -Summaries @() -Ctx (Ctx))) | Should -Contain 'Add golden image'
        $v = New-GIHomePage -Summaries @() -Ctx (Ctx 'Viewer')
        $v | Should -Match 'An Admin needs to add the first golden image'
        (Buttons $v) | Should -Not -Contain 'Add golden image'
        (New-GIHomePage -Summaries @() -Ctx (Ctx) -SetupComplete $false) | Should -Match 'Finish setup first'
    }
    It 'escapes image names' {
        (New-GIHomePage -Summaries @(Img 'x' '<script>alert(1)</script>') -Ctx (Ctx)) | Should -Not -Match '<script>alert'
    }
}

Describe 'Image page' {
    It 'overview: admin gets Roll back, Revert dialog, power buttons; viewer gets none' {
        $a = New-GIImageOverviewPage -Summary (Img) -Ctx (Ctx)
        (Buttons $a) | Should -Contain 'Roll back'
        $a | Should -Match 'id="dlg-revert"'
        $a | Should -Match 'id="dlg-rollback"'
        $a | Should -Match 'Power on'
        $v = New-GIImageOverviewPage -Summary (Img) -Ctx (Ctx 'Viewer')
        (Buttons $v) | Should -Not -Contain 'Roll back'
        (Vis $v) | Should -Not -Match 'dlg-revert'
        (Vis $v) | Should -Not -Match 'Power on'
    }
    It 'overview: actions are disabled with a reason while a run is active' {
        $h = New-GIImageOverviewPage -Summary (Img -Active (Run 'Running')) -Ctx (Ctx)
        $h | Should -Match 'Run 20261125-020000 is in progress'
        @([regex]::Matches($h, 'title="A run is in progress"')).Count | Should -BeGreaterThan 3
    }
    It 'overview: never-run state and tabs' {
        $h = New-GIImageOverviewPage -Summary (Img) -Ctx (Ctx)
        $h | Should -Match 'No runs yet. The first run patches the guest'
        $h | Should -Match 'Start first run'
        $h | Should -Match 'role="tablist"'
        $h | Should -Match 'aria-selected="true" href="/images/win11-corp" aria-current="page">Overview'
        $h | Should -Match 'Back to all images'
    }
    It 'runs tab: table, filter, pager, logs link, empty state' {
        $runs = @(Run 'Completed' 'PostCheck'; )
        $h = New-GIImageRunsPage -Summary (Img) -Ctx (Ctx) -Runs $runs -Total 60 -Page 2 -PageSize 25 -Status 'Failed'
        $h | Should -Match 'name="status"'
        $h | Should -Match 'Page 2 of 3'
        $h | Should -Match 'href="/images/win11-corp/runs\?status=Failed&amp;page=3"|href="/images/win11-corp/runs\?status=Failed&page=3"'
        $h | Should -Match '/api/images/win11-corp/runs/20261125-020000/logs.zip'
        (New-GIImageRunsPage -Summary (Img) -Ctx (Ctx) -Runs @() -Total 0) | Should -Match 'No runs yet'
    }
    It 'general settings: Viewer sees disabled fields and no save bar, Admin sees pause and remove' {
        $v = New-GIImageGeneralBody -Summary ([pscustomobject](Img)) -Ctx (Ctx 'Viewer')
        $v | Should -Match 'disabled'
        (Vis $v) | Should -Not -Match 'savebar'
        $v | Should -Not -Match 'Remove Win11-Corp'
        $a = New-GIImageGeneralBody -Summary ([pscustomobject](Img)) -Ctx (Ctx) -RunCount 4
        $a | Should -Match 'Pause image'
        $a | Should -Match 'Remove Win11-Corp'
        $a | Should -Match 'data-must-match="Win11-Corp"'
        $a | Should -Match 'for 4 runs'
        (New-GIImageGeneralBody -Summary ([pscustomobject](Img -Active (Run 'Running'))) -Ctx (Ctx)) | Should -Match 'Unavailable while a run is in progress'
    }
}

Describe 'Overview: last pushed, retention, inline status (gap 6)' {
    It 'shows when each pool last received an image, from the run history' {
        $lp = @{ 'TST-W11' = @{ at = '2026-11-25T02:30:00'; snapshot = 'Baseline 3'; runId = 'r1' }; 'PRD-W11-1' = @{ at = '2026-11-22T22:00:00'; snapshot = 'Baseline 2<x>'; runId = 'r0' } }
        $h = New-GIImageOverviewPage -Summary (Img) -Ctx (Ctx) -LastPushed $lp
        $h | Should -Match 'data-pool="TST-W11"[^>]*>.*?data-col="pushed" class="muted">2026-11-25 02:30:00 <span class="mono small">Baseline 3</span>'
        $h | Should -Match 'data-col="pushed" class="muted">2026-11-22 22:00:00 <span class="mono small">Baseline 2&lt;x&gt;</span>'
        $h | Should -Match 'data-pool="PRD-W11-2".*?data-col="pushed" class="muted">None recorded'
    }
    It 'explains the Outside retention tag and says when pruning is off' {
        (New-GIImageOverviewPage -Summary (Img) -Ctx (Ctx) -SnapshotsKept 2 -Prune $true) | Should -Match 'marked Outside retention are the ones the next retention pass would remove\.'
        (New-GIImageOverviewPage -Summary (Img) -Ctx (Ctx) -SnapshotsKept 2 -Prune $true) | Should -Not -Match 'Pruning is off'
        (New-GIImageOverviewPage -Summary (Img) -Ctx (Ctx) -SnapshotsKept 2 -Prune $false) | Should -Match 'Pruning is off, so nothing is removed'
        (Get-GIOverviewScript -ImageId 'a') | Should -Match "textContent='Outside retention'"
    }
    It 'answers actions inline: the dialogs close and write a status line, nothing reloads' {
        $h = New-GIImageOverviewPage -Summary (Img) -Ctx (Ctx)
        foreach ($d in 'dlg-power-on', 'dlg-power-off', 'dlg-revert', 'dlg-rollback') {
            $h | Should -Match "id=`"$d`".*?data-then=`"inline`""
        }
        $h | Should -Match 'data-done="Power on requested for GI-W11-01\.'
        $h | Should -Match 'id="gi-action-status" role="status" aria-live="polite"'
        (New-GIImageOverviewPage -Summary (Img) -Ctx (Ctx) -Notice 'Created') | Should -Match 'class="notice" role="status">Created</div><div id="gi-action-status"'
        (Get-GIOverviewScript -ImageId 'a') | Should -Match "addEventListener\('gi:changed'"
        (Get-Content (Join-Path $PSScriptRoot '..' 'Web' 'Components.ps1') -Raw) | Should -Match "t==='inline'"
    }
}

Describe 'Run page' {
    BeforeAll {
        function script:Detail([string]$Status, [string]$Stage, $Steps = @(), $Approval = $null, $Validation = $null) {
            $stages = [ordered]@{}
            foreach ($n in Get-GIViewStageOrder) { $stages[$n] = [pscustomobject]@{ status = 'Pending'; startedAt = $null; endedAt = $null; message = ''; data = @{} } }
            $order = Get-GIViewStageOrder; $ci = [array]::IndexOf($order, $Stage)
            for ($i = 0; $i -lt $ci; $i++) { $stages[$order[$i]].status = 'Succeeded' }
            if ($ci -ge 0) { $stages[$Stage].status = $(if ($Status -eq 'Failed') { 'Failed' } elseif ($Status -eq 'AwaitingApproval') { 'Running' } elseif ($Status -in 'Running') { 'Running' } else { 'Succeeded' }) }
            $run = [pscustomobject]@{ runId = '20261125-020000'; status = $Status; currentStage = $Stage; createdAt = '2026-11-25T02:00:00'; updatedAt = '2026-11-25T02:44:00'; error = $null
                snapshot = [pscustomobject]@{ name = 'GI-20261125-020000' }; stages = [pscustomobject]$stages; approval = $Approval; validation = $Validation; promotion = [pscustomobject]@{ pools = @() } }
            [ordered]@{ run = $run; imageId = 'win11-corp'; steps = @($Steps)
                approval = [ordered]@{ poolsToUpdate = @([ordered]@{ name = 'PRD-W11-1'; logoffPolicy = 'WAIT_FOR_LOGOFF' }, [ordered]@{ name = 'PRD-W11-2'; logoffPolicy = 'FORCE_LOGOFF' }); nextWindow = '2026-11-28T22:00:00' } }
        }
        function script:Step($id, $label, $status, $lines = 0) { [ordered]@{ id = $id; label = $label; status = $status; startedAt = '2026-11-25T02:05:00'; endedAt = '2026-11-25T02:06:00'; message = ''; logLines = $lines; fixApplied = @() } }
    }
    It 'awaiting approval: evidence, force-logoff call-out and decision buttons for an Approver' {
        $val = [pscustomobject]@{ passed = $true; checks = @([pscustomobject]@{ name = 'Services'; detail = '4 of 4 running'; passed = $true }) }
        $d = Detail 'AwaitingApproval' 'Approval' -Validation $val
        $h = New-GIRunPage -Detail $d -Summary (Img) -Ctx (Ctx 'Approver')
        $h | Should -Match 'Approval needed for Win11-Corp'
        $h | Should -Match 'Approving updates 2 production pools'
        $h | Should -Match 'Users on PRD-W11-2 will be signed out'
        $h | Should -Match 'Services: 4 of 4 running'
        $h | Should -Match 'id="dlg-approve"'
        $h | Should -Match 'data-required'
        (Buttons $h) | Should -Contain 'Approve'
        (Buttons $h) | Should -Contain 'Reject'
        $h | Should -Match 'aria-current="step"'
        $h | Should -Match 'id="approval"'
    }
    It 'awaiting approval: a Viewer sees the evidence and no buttons' {
        $h = New-GIRunPage -Detail (Detail 'AwaitingApproval' 'Approval') -Summary (Img) -Ctx (Ctx 'Viewer')
        $h | Should -Match 'Approving updates 2 production pools'
        (Buttons $h) | Should -Not -Contain 'Approve'
        (Vis $h) | Should -Not -Match 'dlg-approve'
    }
    It 'awaiting approval with auto-approve on: notice instead of buttons' {
        $img = Img; $img.autoPromote = $true
        $h = New-GIRunPage -Detail (Detail 'AwaitingApproval' 'Approval') -Summary $img -Ctx (Ctx)
        $h | Should -Match 'Auto-approve is on'
        (Buttons $h) | Should -Not -Contain 'Approve'
    }
    It 'after a decision the panel is a read-only summary' {
        $ap = [pscustomobject]@{ decision = 'Approved'; by = 'LAB\approver1'; at = '2026-11-25T03:00:00'; startTime = '2026-11-28T22:00:00'; comment = 'CHG123' }
        $h = New-GIRunPage -Detail (Detail 'Scheduled' 'Promote' -Approval $ap) -Summary (Img) -Ctx (Ctx 'Approver')
        $h | Should -Match 'Approval: Approved'
        $h | Should -Match 'LAB\\approver1'
        (Vis $h) | Should -Not -Match 'dlg-approve'
    }
    It 'failed: alert, retry for Admin only, failed step open with a log box' {
        $steps = @((Step 'PowerOn' 'Power on' 'Succeeded'), (Step 'Pkg:Horizon' 'Install Horizon Agent' 'Failed' 22), (Step 'Reboot' 'Reboot' 'Pending'))
        $steps[1].message = 'exit code 1603'
        $d = Detail 'Failed' 'Maintain' $steps
        $a = New-GIRunPage -Detail $d -Summary (Img) -Ctx (Ctx 'Admin')
        $a | Should -Match 'Failed at Install Horizon Agent'
        (Buttons $a) | Should -Contain 'Retry from this step'
        (Buttons $a) | Should -Contain 'Start a new run'
        $a | Should -Match 'id="failed"'
        $a | Should -Match 'aria-label="Log for Install Horizon Agent"'
        $a | Should -Match 'tabindex="0"'
        $a | Should -Match '1 step not run'
        $a | Should -Match '1 step succeeded'
        foreach ($r in 'Approver', 'Viewer') { (Buttons (New-GIRunPage -Detail $d -Summary (Img) -Ctx (Ctx $r))) | Should -Not -Contain 'Retry from this step' }
    }
    It 'tags steps kept from an earlier attempt as Resumed, with the suffix moved out of the message (gap 12)' {
        $kept = Step 'SafetySnapshot' 'Safety snapshot' 'Succeeded'; $kept.message = 'taken (earlier attempt)'; $kept.resumed = $true
        $old = Step 'WU' 'Windows Update' 'Succeeded'; $old.message = '2 passes (earlier attempt)'   # saved before the flag existed
        $new = Step 'PowerOn' 'Power on' 'Succeeded'; $new.message = 'on'
        $h = New-GIRunPage -Detail (Detail 'Running' 'Maintain' @($kept, $old, $new, (Step 'X' 'Reboot' 'Running'))) -Summary (Img) -Ctx (Ctx)
        ([regex]::Matches($h, 'chip idle">Resumed</span><span class="sr-only"> \(kept from an earlier attempt\)</span>')).Count | Should -Be 2
        $h | Should -Match '<td>taken</td>'
        $h | Should -Not -Match '\(earlier attempt\)</td>'
        $h | Should -Match '<th scope="row">Power on</th><td><span class="chip ok">Succeeded</span></td>'
    }
    It 'result block says what happened to the test pool and each production pool, not just a count (gap 12)' {
        $d = Detail 'Completed' 'PostCheck'
        $d.run.promotion = [pscustomobject]@{ pools = @([pscustomobject]@{ poolName = 'PRD-W11-1'; status = 'Succeeded' }, [pscustomobject]@{ poolName = 'PRD-W11-2'; status = 'Failed' }, [pscustomobject]@{ poolName = 'PRD-W11-3'; status = 'Cancelled' }) }
        $h = New-GIRunPage -Detail $d -Summary (Img) -Ctx (Ctx)
        $h | Should -Match '<dt>Test pool</dt><dd>TST-W11 received the snapshot</dd>'
        $h | Should -Match '<dt>Production pools</dt><dd>1 of 3 updated, 2 failed or cancelled</dd>'
        $h | Should -Match '<dt>Promoted</dt>'
        $h | Should -Not -Match 'Pools updated'
        $s = Detail 'Scheduled' 'Promote'
        $s.run.promotion = [pscustomobject]@{ pools = @([pscustomobject]@{ poolName = 'PRD-W11-1'; status = 'Scheduled' }, [pscustomobject]@{ poolName = 'PRD-W11-2'; status = 'InProgress' }) }
        $hs = New-GIRunPage -Detail $s -Summary (Img) -Ctx (Ctx)
        $hs | Should -Match '<dt>Production pools</dt><dd>2 scheduled or pushing</dd>'
        $hs | Should -Match '<dt>Approved</dt>'
        $n = Detail 'Completed' 'PostCheck'
        (New-GIRunPage -Detail $n -Summary (Img) -Ctx (Ctx)) | Should -Match '<dt>Production pools</dt><dd>None recorded</dd>'
        $n.run.stages.TestPush.status = 'Failed'
        (New-GIRunPage -Detail $n -Summary (Img) -Ctx (Ctx)) | Should -Match 'Not updated \(Failed\)'
    }
    It 'running: step count comes from the run, with skipped steps summarized' {
        $steps = @((Step 'A' 'Revert' 'Skipped'), (Step 'B' 'Snapshot' 'Succeeded'), (Step 'C' 'Windows Update' 'Running' 5), (Step 'D' 'Reboot' 'Pending'), (Step 'E' 'Manifest' 'Pending'))
        $h = New-GIRunPage -Detail (Detail 'Running' 'Maintain' $steps) -Summary (Img) -Ctx (Ctx 'Viewer')
        $h | Should -Match 'step 3 of 5'
        $h | Should -Match '1 step succeeded.*, 1 skipped'
        $h | Should -Match '2 steps pending: Reboot, Manifest'
        $h | Should -Match 'data-open-tail="3"'
        $h | Should -Match 'data-start='
    }
    It 'adds Fixed by and a link to the Fixes page' {
        $s = Step 'Pkg:Horizon' 'Install Horizon Agent' 'Succeeded'; $s.fixApplied = @([pscustomobject]@{ id = 'RegistryKeyMarkedForDeletion'; attempt = 2 })
        $h = New-GIRunPage -Detail (Detail 'Running' 'Maintain' @($s)) -Summary (Img) -Ctx (Ctx)
        $h | Should -Match 'Fixed by <a href="/settings/Fixes">RegistryKeyMarkedForDeletion</a>, attempt 2'
    }
    It 'pending stages describe what they will do from this image' {
        $h = New-GIRunPage -Detail (Detail 'Running' 'Preflight') -Summary (Img -Prod 5) -Ctx (Ctx)
        $h | Should -Match 'Pushes the snapshot to TST-W11'
        $h | Should -Match 'Pushes to 5 production pools'
    }
    It 'warns when a running run has not changed for 10 minutes and offers no Stop button' {
        $d = Detail 'Running' 'Maintain' @(Step 'A' 'Step' 'Running')
        $d.run.updatedAt = (Get-Date).AddMinutes(-30).ToString('o')
        $h = New-GIRunPage -Detail $d -Summary (Img) -Ctx (Ctx)
        $h | Should -Match 'No update from the runner for 10 minutes'
        $h | Should -Not -Match '>Stop<'
    }
    It 'has breadcrumbs, report/logs/json links and a not-found page' {
        $h = New-GIRunPage -Detail (Detail 'Completed' 'PostCheck') -Summary (Img) -Ctx (Ctx)
        $h | Should -Match 'Golden images</a> / <a href="/images/win11-corp">Win11-Corp</a> / <a href="/images/win11-corp/runs">Runs</a>'
        $h | Should -Match 'Download all logs'
        $h | Should -Match 'title="Includes logs from inside the guest VM."'
        (New-GIRunNotFoundPage -ImageId 'win11-corp') | Should -Match 'Back to the Runs tab'
    }
}

Describe 'Wizard, audit and global settings' {
    It 'wizard has five steps, a stepper and a focus target per step' {
        $inst = [pscustomobject]@{ Packages = @([pscustomobject]@{ Action = 'Horizon'; Name = 'Horizon Agent'; Mask = '*.exe' }) }
        $h = New-GIWizardPage -Ctx (Ctx) -Installers $inst
        @([regex]::Matches($h, '<fieldset class="wizstep')).Count | Should -Be 5
        $h | Should -Match 'Basics'; $h | Should -Match 'Windows Update and packages'; $h | Should -Match 'Promote automatically'
        $h | Should -Not -Match 'id="AutoOk"'   # the confirmation is a dialog now
        $h | Should -Match 'id="dlg-auto-promote"'
        $h | Should -Match 'Promote automatically\?'
        $h | Should -Match 'data-confirm data-confirm-yes'
        $h | Should -Match 'tabindex="-1"'
    }
    It 'wizard packages table has installer status, a recheck button, and asks the server on every Next (gap 13)' {
        $inst = [pscustomobject]@{ Packages = @([pscustomobject]@{ Action = 'Horizon'; Name = 'Horizon <Agent>'; Mask = '*.exe' }) }
        $h = New-GIWizardPage -Ctx (Ctx) -Installers $inst
        $h | Should -Match '<th scope="col">Installer on host</th><th scope="col">Status</th>'
        $h | Should -Match 'data-pkg-file="Horizon"><span class="muted">-</span></td><td data-pkg-state="Horizon"><span class="chip idle">Not checked</span></td>'
        $h | Should -Match 'id="pkg-recheck">Check again</button>'
        $h | Should -Match "/api/images\?dryRun=1&step='\+cur"
        $h | Should -Match "/api/packages\?folder='\+encodeURIComponent"
        $h | Should -Match "window\.GI\.open\('dlg-auto-promote'"
        $h | Should -Not -Match '<script[^>]+src='
    }
    It 'audit page: filters, role in muted text, results and no secret in details' {
        $e = [pscustomobject]@{ at = '2026-11-25T10:00:00'; user = 'LAB\jwood'; role = 'Admin'; action = 'settings.update'; target = 'Packages'; image = 'win11-corp'; detail = [pscustomobject]@{ section = 'Packages'; password = 'hunter2'; keys = @('Actions') }; result = 'Saved' }
        $d = [pscustomobject]@{ at = '2026-11-25T10:05:00'; user = 'LAB\viewer1'; role = 'Viewer'; action = 'auth.denied'; target = 'POST /api/images/x/runs'; detail = [pscustomobject]@{ needed = 'Admin' }; result = 'Denied' }
        $h = New-GIAuditLogPage -Entries @($e, $d) -Total 2 -Images @('win11-corp') -Users @('LAB\jwood')
        $h | Should -Match 'Sign-ins'
        $h | Should -Match 'Export CSV'
        $h | Should -Match 'LAB\\jwood <span class="muted">\(Admin\)</span>'
        $h | Should -Match 'chip bad">Denied'
        $h | Should -Not -Match 'hunter2'
        $h | Should -Match 'Showing 1 to 2 of 2 entries'
    }
    It 'audit helpers: categories, defaults, csv with formula guard' {
        Get-GIAuditCategory 'auth.signin.failed' | Should -Be 'signin'
        Get-GIAuditCategory 'pool.rollback' | Should -Be 'poolvm'
        $csv = ConvertTo-GIAuditCsv -Entries @([pscustomobject]@{ at = 'x'; user = '=cmd'; action = 'run.request'; detail = [pscustomobject]@{} })
        $csv | Should -Match '"''=cmd"'
        $csv | Should -Match 'When,User,Role,Action,Golden image,Details,Result'
    }
    It 'dashboard settings are read only with the role table; fixes list real data' {
        $h = New-GIDashboardSettingsBody -Dashboard @{ Port = 8443; CertificateThumbprint = 'ABC'; RefreshSeconds = 20; ViewerGroup = 'D\V'; ApproverGroup = 'D\A'; AdminGroup = 'D\Ad' }
        $h | Should -Match 'Read only'
        $h | Should -Not -Match '<input'
        $h | Should -Match 'A person in more than one group gets the highest role'
        $f = New-GIFixesBody -Fixes @([ordered]@{ id = 'X'; valid = $true; description = 'd'; priority = 5; actions = @('*'); maxAttempts = 2; rebootFromAttempt = 0; match = @{ ExitCodes = @(1) }; lastUsedRunId = '20261101-010101' })
        $f | Should -Match 'All steps'
        $f | Should -Match '20261101-010101'
        $f | Should -Not -Match '<button'
    }
    It 'settings section page can render disabled and embedded' {
        $schema = Get-GISettingsSchema
        $data = @{ Section = 'Validation'; Values = @{ GuestSampleCount = 2; RequiredServices = @('wsnm'); MachineReadyTimeoutMin = 60 } }
        $h = New-GISettingsSectionPage -Schema $schema -SectionKey 'Validation' -SectionData $data -Token 't' -BodyOnly -Disabled -FormAction '/images/x/settings/Validation'
        $h | Should -Match '<input[^>]* disabled'
        (Vis $h) | Should -Not -Match 'savebar'
        $e = New-GISettingsSectionPage -Schema $schema -SectionKey 'Validation' -SectionData $data -Token 't' -BodyOnly -FormAction '/images/x/settings/Validation' -DescSuffix 'Applies to X only.'
        $e | Should -Match 'action="/images/x/settings/Validation"'
        $e | Should -Match 'data-savebar'
        $e | Should -Match 'Applies to X only.'
    }
}
