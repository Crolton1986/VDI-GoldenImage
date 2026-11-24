[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Helpers return heterogeneous values by design.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '', Justification = 'Internal view helpers; short positional calls keep HTML builders readable.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-* functions only build strings; nothing is changed.')]
param()

# Pure HTML view functions for the golden image dashboard.
# No Pode and no filesystem access here, so everything is unit-testable (see tests/Dashboard.Tests.ps1).
# Every value that originates from state/config is HTML-encoded via ConvertTo-GIHtml.

# A function rather than a $script: variable: Pode's Use-PodeScript does not preserve script-scope variables in route runspaces.
function Get-GIViewStageOrder { @('Preflight', 'Maintain', 'Snapshot', 'TestPush', 'Validate', 'Approval', 'Promote', 'PostCheck') }

function ConvertTo-GIHtml {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Test-GIRunId {
    <# True only for yyyyMMdd-HHmmss. Call before using a RunId in any file path. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string]$RunId)
    if ([string]::IsNullOrEmpty($RunId)) { return $false }
    # \z (not $) so a trailing newline cannot slip through
    return [regex]::IsMatch($RunId, '^\d{8}-\d{6}\z')
}

function Get-GIValue {
    <# Null-safe property/key read that works for pscustomobject and dictionaries. #>
    [CmdletBinding()]
    [OutputType([object])]
    param($Object, [string]$Name, $Default = '')
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Get-GIStatusClass {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Status)
    switch ($Status) {
        'Running' { 'st-running' }
        'Succeeded' { 'st-ok' }
        'Completed' { 'st-ok' }
        'Failed' { 'st-bad' }
        'Rejected' { 'st-bad' }
        'Cancelled' { 'st-bad' }
        'AwaitingApproval' { 'st-wait' }
        'Scheduled' { 'st-sched' }
        'InProgress' { 'st-running' }
        'RolledBack' { 'st-warn' }
        'Skipped' { 'st-skip' }
        default { 'st-pending' }
    }
}

function Get-GIStatusBadge {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Status)
    "<span class=""badge $(Get-GIStatusClass $Status)"">$(ConvertTo-GIHtml $Status)</span>"
}

function Get-GIStatusIcon {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Status)
    $icon = switch ($Status) {
        'Succeeded' { '&#10004;' }
        'Failed' { '&#10008;' }
        'Running' { '&#9654;' }
        'Skipped' { '&#8211;' }
        default { '&#9675;' }
    }
    "<span class=""icon $(Get-GIStatusClass $Status)"" title=""$(ConvertTo-GIHtml $Status)"">$icon</span>"
}

function ConvertTo-GIDateTime {
    [CmdletBinding()]
    [OutputType([datetime], [object])]
    param($Value)
    if ($Value -is [datetime]) { return $Value }
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    $d = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$d)) { return $d }
    return $null
}

function Format-GIDate {
    [CmdletBinding()]
    [OutputType([string])]
    param($Value)
    $d = ConvertTo-GIDateTime $Value
    if ($null -eq $d) { return ConvertTo-GIHtml $Value }
    ConvertTo-GIHtml $d.ToString('yyyy-MM-dd HH:mm:ss')
}

function Format-GIDuration {
    [CmdletBinding()]
    [OutputType([string])]
    param($Start, $End)
    $s = ConvertTo-GIDateTime $Start
    $e = ConvertTo-GIDateTime $End
    if ($null -eq $s) { return '' }
    if ($null -eq $e) { $e = [datetimeoffset]::Now.DateTime; if ($s.Kind -eq 'Utc') { $e = [datetime]::UtcNow } }
    $ts = $e - $s
    if ($ts.TotalSeconds -lt 0) { return '' }
    if ($ts.TotalHours -ge 1) { return '{0}h {1:00}m {2:00}s' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds }
    if ($ts.TotalMinutes -ge 1) { return '{0}m {1:00}s' -f $ts.Minutes, $ts.Seconds }
    '{0}s' -f [int]$ts.TotalSeconds
}

function Get-GICss {
    @'
:root{--bg:#f4f6f8;--fg:#1d2733;--card:#fff;--line:#d9dfe5;--mut:#5d6b7a;--link:#0b5cad}
*{box-sizing:border-box}
body{margin:0;font:14px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;background:var(--bg);color:var(--fg)}
header{background:#1d2733;color:#fff;padding:10px 16px;display:flex;flex-wrap:wrap;gap:8px 20px;align-items:baseline}
header h1{font-size:17px;margin:0}
header a{color:#cfe3ff;text-decoration:none}
main{padding:12px 16px;max-width:1200px;margin:0 auto}
h2{font-size:16px;margin:22px 0 8px}
section.card{background:var(--card);border:1px solid var(--line);border-radius:6px;padding:10px 12px;margin:10px 0;overflow-x:auto}
section.attn{border-left:5px solid #d98200;background:#fff8ec}
table{border-collapse:collapse;width:100%}
th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}
th{font-size:12px;text-transform:uppercase;letter-spacing:.03em;color:var(--mut)}
a{color:var(--link)}
.badge{display:inline-block;padding:1px 8px;border-radius:10px;font-size:12px;font-weight:600;color:#fff;white-space:nowrap}
.badge.st-ok{background:#1e8a44}.badge.st-bad{background:#c0392b}.badge.st-running{background:#1b6fd1}
.badge.st-wait{background:#d98200}.badge.st-sched{background:#7a4bc4}.badge.st-warn{background:#8a6d1e}
.badge.st-skip{background:#7d8894}.badge.st-pending{background:#9aa5b1}
.icon{font-weight:700;margin-right:4px}
.icon.st-ok{color:#1e8a44}.icon.st-bad{color:#c0392b}.icon.st-running{color:#1b6fd1}.icon.st-pending,.icon.st-skip{color:#9aa5b1}
tr.cat td{background:#eef2f6;font-weight:600}
.err{border-left:5px solid #c0392b;background:#fdf0ee;padding:8px 12px;white-space:pre-wrap}
.muted{color:var(--mut)}
.kv{display:grid;grid-template-columns:max-content 1fr;gap:3px 14px}
.kv dt{color:var(--mut)}.kv dd{margin:0}
.links a{margin-right:14px}
code,pre{font-family:ui-monospace,Consolas,monospace}
@media (max-width:600px){main{padding:8px}th,td{padding:5px 4px;font-size:13px}.kv{grid-template-columns:1fr}}
'@
}

function New-GIPage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$BodyHtml,   # already-encoded HTML
        [int]$RefreshSeconds = 0
    )
    $refresh = ''
    if ($RefreshSeconds -gt 0) { $refresh = "<meta http-equiv=""refresh"" content=""$RefreshSeconds"">" }
    @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
$refresh
<title>$(ConvertTo-GIHtml $Title)</title>
<style>$(Get-GICss)</style></head>
<body>
<header><h1>VDI Golden Image Pipeline</h1><nav><a href="/">Runs</a> &middot; <a href="/pools">Pools</a> &middot; <a href="/api/runs">JSON</a></nav></header>
<main>
$BodyHtml
</main>
</body></html>
"@
}

function Get-GIRunRowHtml {
    param($Run)
    $id = ConvertTo-GIHtml (Get-GIValue $Run 'runId')
    $snapName = Get-GIValue (Get-GIValue $Run 'snapshot' $null) 'name'
    $sb = "<tr><td><a href=""/runs/$id"">$id</a></td>"
    $sb += "<td>$(ConvertTo-GIHtml (Get-GIValue $Run 'goldenVm'))</td>"
    $sb += "<td>$(ConvertTo-GIHtml $snapName)</td>"
    $sb += "<td>$(ConvertTo-GIHtml (Get-GIValue $Run 'currentStage'))</td>"
    $sb += "<td>$(Get-GIStatusBadge ([string](Get-GIValue $Run 'status')))</td>"
    $sb += "<td>$(Format-GIDate (Get-GIValue $Run 'createdAt'))</td>"
    $sb += "<td>$(Format-GIDate (Get-GIValue $Run 'updatedAt'))</td>"
    $sb += "<td>$(ConvertTo-GIHtml (Get-GIValue $Run 'progress'))</td></tr>"
    $sb
}

function Get-GIRunTableHtml {
    param($Runs)
    $head = '<table><thead><tr><th>Run</th><th>Golden VM</th><th>Snapshot</th><th>Stage</th><th>Status</th><th>Created</th><th>Updated</th><th>Progress</th></tr></thead><tbody>'
    $rows = foreach ($r in @($Runs)) { Get-GIRunRowHtml $r }
    "$head$(@($rows) -join '')</tbody></table>"
}

function New-GIRunListPage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]$Runs,
        [int]$RefreshSeconds = 0
    )
    $all = @($Runs | Where-Object { $null -ne $_ })
    $waiting = @($all | Where-Object { (Get-GIValue $_ 'status') -eq 'AwaitingApproval' })
    $others = @($all | Where-Object { (Get-GIValue $_ 'status') -ne 'AwaitingApproval' })
    $body = '<h2>Golden image runs</h2>'
    if ($waiting.Count -gt 0) {
        $body += "<section class=""card attn""><h2 style=""margin-top:0"">Needs approval</h2>$(Get-GIRunTableHtml $waiting)</section>"
    }
    if ($others.Count -gt 0) {
        $body += "<section class=""card"">$(Get-GIRunTableHtml $others)</section>"
    } elseif ($waiting.Count -eq 0) {
        $body += '<p class="muted">No runs found.</p>'
    }
    New-GIPage -Title 'Golden image runs' -BodyHtml $body -RefreshSeconds $RefreshSeconds
}

function New-GIRunDetailPage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Run,
        [int]$RefreshSeconds = 0,
        [string]$ApprovalFormHtml = '',   # already-encoded form HTML, only passed for approvers
        [string]$NoticeHtml = ''          # already-encoded notice (e.g. result of an approve/reject)
    )
    $id = ConvertTo-GIHtml (Get-GIValue $Run 'runId')
    $status = [string](Get-GIValue $Run 'status')
    $body = "<h2>Run $id $(Get-GIStatusBadge $status)</h2>"
    if ($NoticeHtml) { $body += "<section class=""card attn"">$NoticeHtml</section>" }

    $snap = Get-GIValue $Run 'snapshot' $null
    $body += '<section class="card"><dl class="kv">'
    $body += "<dt>Golden VM</dt><dd>$(ConvertTo-GIHtml (Get-GIValue $Run 'goldenVm'))</dd>"
    $body += "<dt>Current stage</dt><dd>$(ConvertTo-GIHtml (Get-GIValue $Run 'currentStage'))</dd>"
    $body += "<dt>Created</dt><dd>$(Format-GIDate (Get-GIValue $Run 'createdAt'))</dd>"
    $body += "<dt>Updated</dt><dd>$(Format-GIDate (Get-GIValue $Run 'updatedAt'))</dd>"
    $body += "<dt>Snapshot</dt><dd>$(ConvertTo-GIHtml (Get-GIValue $snap 'name'))</dd>"
    $body += "<dt>Progress</dt><dd>$(ConvertTo-GIHtml (Get-GIValue $Run 'progress'))</dd>"
    $body += '</dl>'
    $body += "<p class=""links""><a href=""/reports/$id"">Report</a><a href=""/logs/$id"">Log</a><a href=""/api/runs/$id"">JSON</a></p></section>"

    $err = Get-GIValue $Run 'error' $null
    if ($err) {
        $body += "<h2>Error</h2><div class=""err"">$(ConvertTo-GIHtml $err)</div>"
    }

    # Stage timeline, fixed order
    $stages = Get-GIValue $Run 'stages' $null
    $body += '<h2>Stages</h2><section class="card"><table><thead><tr><th>Stage</th><th>Status</th><th>Started</th><th>Ended</th><th>Duration</th><th>Message</th></tr></thead><tbody>'
    foreach ($name in (Get-GIViewStageOrder)) {
        $st = Get-GIValue $stages $name $null
        $stStatus = [string](Get-GIValue $st 'status' 'Pending')
        $started = Get-GIValue $st 'startedAt' $null
        $ended = Get-GIValue $st 'endedAt' $null
        $body += "<tr><td>$(Get-GIStatusIcon $stStatus)$name</td><td>$(Get-GIStatusBadge $stStatus)</td>"
        $body += "<td>$(Format-GIDate $started)</td><td>$(Format-GIDate $ended)</td>"
        $body += "<td>$(ConvertTo-GIHtml (Format-GIDuration $started $ended))</td>"
        $body += "<td>$(ConvertTo-GIHtml (Get-GIValue $st 'message'))</td></tr>"
    }
    $body += '</tbody></table></section>'

    # Snapshot manifest
    $manifest = Get-GIValue $snap 'manifest' $null
    if ($manifest) {
        $props = if ($manifest -is [System.Collections.IDictionary]) { $manifest.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = $_.Key; Value = $_.Value } } }
        else { $manifest.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } } }
        $body += '<h2>Snapshot manifest</h2><section class="card"><table><thead><tr><th>Component</th><th>Version</th></tr></thead><tbody>'
        foreach ($p in @($props)) { $body += "<tr><td>$(ConvertTo-GIHtml $p.Name)</td><td>$(ConvertTo-GIHtml $p.Value)</td></tr>" }
        $body += '</tbody></table></section>'
    }

    # Validation checks grouped by category
    $validation = Get-GIValue $Run 'validation' $null
    $checks = @(Get-GIValue $validation 'checks' @())
    if ($checks.Count -gt 0) {
        $vp = Get-GIValue $validation 'passed' $false
        $vBadge = if ($vp) { Get-GIStatusBadge 'Succeeded' } else { Get-GIStatusBadge 'Failed' }
        $body += "<h2>Validation $vBadge</h2><section class=""card""><table><thead><tr><th>Check</th><th>Target</th><th>Result</th><th>Detail</th></tr></thead><tbody>"
        foreach ($grp in ($checks | Group-Object -Property { [string](Get-GIValue $_ 'category' 'Other') })) {
            $body += "<tr class=""cat""><td colspan=""4"">$(ConvertTo-GIHtml $grp.Name)</td></tr>"
            foreach ($c in $grp.Group) {
                $res = if (Get-GIValue $c 'passed' $false) { Get-GIStatusBadge 'Succeeded' } else { Get-GIStatusBadge 'Failed' }
                $body += "<tr><td>$(ConvertTo-GIHtml (Get-GIValue $c 'name'))</td><td>$(ConvertTo-GIHtml (Get-GIValue $c 'target'))</td><td>$res</td><td>$(ConvertTo-GIHtml (Get-GIValue $c 'detail'))</td></tr>"
            }
        }
        $body += '</tbody></table></section>'
    }

    # Approval
    $ap = Get-GIValue $Run 'approval' $null
    $decision = Get-GIValue $ap 'decision' $null
    $body += '<h2>Approval</h2><section class="card">'
    if ($status -eq 'AwaitingApproval' -and -not $decision) {
        $body += '<p>' + (Get-GIStatusBadge 'AwaitingApproval') + ' Waiting for an approver.</p>'
        $body += $ApprovalFormHtml
    }
    $body += '<dl class="kv">'
    $body += "<dt>Decision</dt><dd>$(if ($decision) { ConvertTo-GIHtml $decision } else { '<span class="muted">none yet</span>' })</dd>"
    $body += "<dt>By</dt><dd>$(ConvertTo-GIHtml (Get-GIValue $ap 'by'))</dd>"
    $body += "<dt>At</dt><dd>$(Format-GIDate (Get-GIValue $ap 'at'))</dd>"
    $body += "<dt>Start time</dt><dd>$(Format-GIDate (Get-GIValue $ap 'startTime'))</dd>"
    $body += "<dt>Comment</dt><dd>$(ConvertTo-GIHtml (Get-GIValue $ap 'comment'))</dd>"
    $body += '</dl></section>'

    # Promotion pools
    $pools = @(Get-GIValue (Get-GIValue $Run 'promotion' $null) 'pools' @())
    if ($pools.Count -gt 0) {
        $body += '<h2>Promotion</h2><section class="card"><table><thead><tr><th>Pool</th><th>Scheduled start</th><th>Status</th><th>Message</th></tr></thead><tbody>'
        foreach ($p in $pools) {
            $body += "<tr><td>$(ConvertTo-GIHtml (Get-GIValue $p 'poolName'))</td><td>$(Format-GIDate (Get-GIValue $p 'scheduledStart'))</td><td>$(Get-GIStatusBadge ([string](Get-GIValue $p 'status')))</td><td>$(ConvertTo-GIHtml (Get-GIValue $p 'message'))</td></tr>"
        }
        $body += '</tbody></table></section>'
    }

    New-GIPage -Title "Run $(Get-GIValue $Run 'runId')" -BodyHtml $body -RefreshSeconds $RefreshSeconds
}

function Get-GIPoolSummary {
    <# Latest promotion entry per pool across runs (newest first), from state only. #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([AllowNull()]$Runs)
    $seen = [ordered]@{}
    foreach ($r in @($Runs | Where-Object { $null -ne $_ })) {
        foreach ($p in @(Get-GIValue (Get-GIValue $r 'promotion' $null) 'pools' @())) {
            $name = [string](Get-GIValue $p 'poolName')
            if ($name -and -not $seen.Contains($name)) {
                $seen[$name] = [pscustomobject]@{
                    Pool           = $name
                    Snapshot       = [string](Get-GIValue (Get-GIValue $r 'snapshot' $null) 'name')
                    RunId          = [string](Get-GIValue $r 'runId')
                    ScheduledStart = Get-GIValue $p 'scheduledStart'
                    Status         = [string](Get-GIValue $p 'status')
                }
            }
        }
    }
    @($seen.Values)
}

function New-GIPoolsPage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]$LastKnownGood,
        [AllowNull()]$Runs,
        [string]$TestPoolName = '',
        [int]$RefreshSeconds = 0
    )
    $body = '<h2>Pools</h2><p class="muted">Derived from pipeline state only; no live Horizon queries.</p>'

    $body += '<h2>Last known good</h2><section class="card">'
    if ($LastKnownGood) {
        $rid = ConvertTo-GIHtml (Get-GIValue $LastKnownGood 'runId')
        $body += '<dl class="kv">'
        $body += "<dt>Golden VM</dt><dd>$(ConvertTo-GIHtml (Get-GIValue $LastKnownGood 'goldenVm'))</dd>"
        $body += "<dt>Snapshot</dt><dd>$(ConvertTo-GIHtml (Get-GIValue $LastKnownGood 'snapshotName'))</dd>"
        $body += "<dt>Run</dt><dd><a href=""/runs/$rid"">$rid</a></dd>"
        $body += "<dt>Promoted</dt><dd>$(Format-GIDate (Get-GIValue $LastKnownGood 'promotedAt'))</dd></dl>"
    } else {
        $body += '<p class="muted">No promotion has completed yet.</p>'
    }
    $body += '</section>'

    # Test pool: latest run that got past the Snapshot stage
    $all = @($Runs | Where-Object { $null -ne $_ })
    $testRun = $all | Where-Object {
        (Get-GIValue $_ 'snapshot' $null) -and (Get-GIValue (Get-GIValue (Get-GIValue $_ 'stages' $null) 'TestPush' $null) 'status' 'Pending') -ne 'Pending'
    } | Select-Object -First 1
    $body += "<h2>Test pool $(ConvertTo-GIHtml $TestPoolName)</h2><section class=""card"">"
    if ($testRun) {
        $rid = ConvertTo-GIHtml (Get-GIValue $testRun 'runId')
        $tp = Get-GIValue (Get-GIValue (Get-GIValue $testRun 'stages' $null) 'TestPush' $null) 'status'
        $body += "<dl class=""kv""><dt>Snapshot</dt><dd>$(ConvertTo-GIHtml (Get-GIValue (Get-GIValue $testRun 'snapshot' $null) 'name'))</dd>"
        $body += "<dt>Run</dt><dd><a href=""/runs/$rid"">$rid</a></dd><dt>TestPush</dt><dd>$(Get-GIStatusBadge ([string]$tp))</dd></dl>"
    } else {
        $body += '<p class="muted">No run has pushed to the test pool yet.</p>'
    }
    $body += '</section>'

    $body += '<h2>Production pools</h2><section class="card">'
    $summary = @(Get-GIPoolSummary -Runs $all)
    if ($summary.Count -gt 0) {
        $body += '<table><thead><tr><th>Pool</th><th>Snapshot</th><th>Scheduled start</th><th>Status</th><th>Run</th></tr></thead><tbody>'
        foreach ($s in $summary) {
            $rid = ConvertTo-GIHtml $s.RunId
            $body += "<tr><td>$(ConvertTo-GIHtml $s.Pool)</td><td>$(ConvertTo-GIHtml $s.Snapshot)</td><td>$(Format-GIDate $s.ScheduledStart)</td><td>$(Get-GIStatusBadge $s.Status)</td><td><a href=""/runs/$rid"">$rid</a></td></tr>"
        }
        $body += '</tbody></table>'
    } else {
        $body += '<p class="muted">No promotions recorded.</p>'
    }
    $body += '</section>'
    New-GIPage -Title 'Pools' -BodyHtml $body -RefreshSeconds $RefreshSeconds
}

function New-GINotFoundPage {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Message = 'The requested page was not found.')
    New-GIPage -Title 'Not found' -BodyHtml "<h2>404 Not found</h2><p>$(ConvertTo-GIHtml $Message)</p><p><a href=""/"">Back to runs</a></p>"
}


function Get-GIFormToken {
    # CSRF token bound to user + run: HMAC-SHA256(secret, "user|runId"), base64url
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][byte[]]$Secret,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$RunId
    )
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($Secret)
    try {
        $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$($User.ToLowerInvariant())|$RunId"))
        return [Convert]::ToBase64String($hash).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    } finally { $hmac.Dispose() }
}

function Test-GIFormToken {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][byte[]]$Secret,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$RunId,
        [string]$Token
    )
    if (-not $Token) { return $false }
    $expected = [System.Text.Encoding]::ASCII.GetBytes((Get-GIFormToken -Secret $Secret -User $User -RunId $RunId))
    $actual = [System.Text.Encoding]::ASCII.GetBytes($Token)
    return [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($expected, $actual)
}

function New-GIApprovalForm {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][datetime]$DefaultStart
    )
    $rid = ConvertTo-GIHtml $RunId
    $tok = ConvertTo-GIHtml $Token
    $start = $DefaultStart.ToString('yyyy-MM-ddTHH:mm')
    @"
<form method="post" action="/runs/$rid/decision" class="approval">
<input type="hidden" name="token" value="$tok">
<p><label>Production start time (defaults to next maintenance window)<br>
<input type="datetime-local" name="startTime" value="$start" required></label></p>
<p><label>Comment (change ticket, reason)<br><input type="text" name="comment" maxlength="500" style="width:100%"></label></p>
<p><button type="submit" name="decision" value="approve">Approve and schedule</button>
<button type="submit" name="decision" value="reject">Reject</button></p>
</form>
"@
}


function Get-GIDashboardUser {
    # DOMAIN\user of the authenticated caller, or 'anonymous' with -NoAuth
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Context, $WebEvent)
    if ($Context.NoAuth -or -not $WebEvent -or -not $WebEvent.Auth -or -not $WebEvent.Auth.User) { return 'anonymous' }
    $u = $WebEvent.Auth.User
    $name = if ($u.Username) { [string]$u.Username } else { [string]$u.Name }
    if ($u.Domain) { return "$($u.Domain)\$name" }
    return $name
}

function Test-GIDashboardApprover {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Context, $WebEvent)
    if ($Context.NoAuth -or -not $Context.ApproverShort) { return $false }
    if (-not $WebEvent -or -not $WebEvent.Auth -or -not $WebEvent.Auth.User) { return $false }
    return [bool](@($WebEvent.Auth.User.Groups) | Where-Object { $_ -eq $Context.ApproverShort })
}
