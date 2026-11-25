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
    # The only place hex colors may appear: the token block. Every other rule uses var(--token).
    @'
:root{--bg:#f4f6f8;--fg:#1d2733;--card:#fff;--line:#d9dfe5;--mut:#5d6b7a;--link:#0b5cad;--pri:#0b5cad;--navy:#1d2733;--navy-2:#33414f;--on-dark:#fff;
--ok-fg:#14612b;--ok-bg:#e3f5e8;--warn-fg:#7a4300;--warn-bg:#fff1d6;--run-fg:#0b4a8f;--run-bg:#e3effb;--bad-fg:#8f1d14;--bad-bg:#fde8e6;--idle-fg:#3f4d5b;--idle-bg:#eef1f4;
--sel-bg:#e8f1fb;--hover:#eef2f6;--field-line:#b9c3ce;--skel:#e6eaee;--danger:#b3261e;--bar-done:#1a7f37;--bar-run:#0b5cad;--bar-wait:#c77700;--bar-fail:#b3261e;--bar-pending:#d9dfe5;
--shadow:rgba(0,0,0,.25);--scrim:rgba(0,0,0,.45);--font:Inter,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;--mono:ui-monospace,Consolas,monospace}
*{box-sizing:border-box}
body{margin:0;font:14px/1.45 var(--font);background:var(--bg);color:var(--fg)}
header.topbar{background:var(--navy);color:var(--on-dark);height:56px;padding:0 20px;display:flex;gap:12px;align-items:center}
.apptitle{font-size:18px;font-weight:600;flex:1}
.userbox{display:flex;gap:10px;align-items:center;font-size:13px}
.rolepill{background:var(--navy-2);color:var(--on-dark);font-size:12px;padding:2px 10px;border-radius:999px}
.layout{display:grid;grid-template-columns:232px minmax(0,1fr);align-items:start}
body.nav-collapsed .layout{grid-template-columns:56px minmax(0,1fr)}
main{padding:24px 32px;max-width:1180px;width:100%;margin:0 auto;display:flex;flex-direction:column;gap:20px}
main>*{margin-top:0;margin-bottom:0}
main>button,main>.btn{align-self:flex-start}
main h1{font-size:22px;font-weight:600;margin:0}
.sidenav{position:sticky;top:0;height:calc(100vh - 56px);overflow-y:auto;background:var(--card);border-right:1px solid var(--line);padding:8px 0;display:flex;flex-direction:column}
.sidenav button.navcollapse{display:flex;align-items:center;gap:12px;width:100%;height:40px;margin:0 0 6px;padding:0 18px;border:0;border-radius:0;background:none;color:var(--mut);text-align:left}
.sidenav button.navcollapse:hover{background:var(--hover);color:var(--fg)}
.sidenav button.navcollapse .ico{transition:transform .15s}
body.nav-collapsed .navcollapse .ico{transform:rotate(180deg)}
.navitem{display:flex;align-items:center;gap:12px;min-height:40px;padding:0 18px 0 15px;color:var(--fg);text-decoration:none;border-left:3px solid transparent}
.navitem.muted{color:var(--mut)}
.navitem .ico{flex:none}
.navitem .label{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
a.navitem:hover{background:var(--hover)}
.navitem.active{background:var(--sel-bg);border-left-color:var(--link);font-weight:600;color:var(--link)}
.navdivider{border:0;border-top:1px solid var(--line);margin:8px 0;width:100%}
.navitem.disabled{color:var(--mut);opacity:.55;cursor:not-allowed}
.navlock{display:inline-flex;margin-left:auto}.navlock .ico{width:14px;height:14px}
:focus-visible{outline:2px solid var(--link);outline-offset:2px}
.sidenav a:focus-visible,.sidenav button:focus-visible,.navtoggle-mobile:focus-visible{outline-offset:-2px}
header.topbar :focus-visible{outline-color:var(--on-dark)}
.navtoggle-mobile{display:none;min-height:40px;min-width:40px;padding:4px 6px;background:none;border:1px solid var(--on-dark);color:var(--on-dark);align-items:center;justify-content:center}
.navbackdrop{display:none}
body.nav-collapsed .sidenav .label,body.nav-collapsed .navlock{display:none}
body.nav-collapsed .navitem{padding-right:0;justify-content:flex-start}
@media (max-width:900px){
.layout{display:block}
body.nav-collapsed .layout{display:block}
main{padding:16px}
.navtoggle-mobile{display:inline-flex}
.sidenav{position:fixed;top:0;left:0;bottom:0;width:260px;max-width:85vw;height:auto;z-index:30;transform:translateX(-100%);transition:transform .2s;box-shadow:2px 0 12px var(--shadow)}
body.nav-open .sidenav{transform:none}
body.nav-open .navbackdrop{display:block;position:fixed;inset:0;background:var(--scrim);z-index:20}
.sidenav button.navcollapse{display:none}
body.nav-collapsed .sidenav .label,body.nav-collapsed .navlock{display:revert}
.grid2,.grid3{grid-template-columns:1fr}
.subnav-layout{grid-template-columns:1fr}
}
@media (prefers-reduced-motion:reduce){.sidenav,.navcollapse .ico{transition:none}.skeleton{animation:none}.spinner{animation:none}}
h2{font-size:16px;font-weight:600;margin:0}
section.card,.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:20px;overflow-x:auto}
section.attn{border-left:5px solid var(--bar-wait);background:var(--warn-bg)}
table{border-collapse:collapse;width:100%;font-size:13px}
th,td{text-align:left;padding:8px;border-bottom:1px solid var(--line);vertical-align:top}
th{font-size:11px;text-transform:uppercase;letter-spacing:.04em;color:var(--mut);font-weight:600}
a{color:var(--link)}
.badge,.chip{display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px;font-weight:600;white-space:nowrap;line-height:1.4}
.chip.ok,.badge.st-ok{background:var(--ok-bg);color:var(--ok-fg)}
.chip.warn,.badge.st-wait,.badge.st-warn{background:var(--warn-bg);color:var(--warn-fg)}
.chip.run,.badge.st-running,.badge.st-sched{background:var(--run-bg);color:var(--run-fg)}
.chip.bad,.badge.st-bad{background:var(--bad-bg);color:var(--bad-fg)}
.chip.idle,.badge.st-skip,.badge.st-pending{background:var(--idle-bg);color:var(--idle-fg)}
.icon{font-weight:700;margin-right:4px}
.icon.st-ok{color:var(--ok-fg)}.icon.st-bad{color:var(--bad-fg)}.icon.st-running{color:var(--run-fg)}.icon.st-pending,.icon.st-skip{color:var(--mut)}
tr.cat td{background:var(--hover);font-weight:600}
tr.substeps>td{padding-top:0;border-bottom:1px solid var(--line)}table.steps th,table.steps td{padding:3px 6px;font-size:13px;border-bottom:1px dashed var(--line)}table.steps tr:last-child td{border-bottom:0}
.err{border-left:5px solid var(--bar-fail);background:var(--bad-bg);padding:8px 12px;white-space:pre-wrap}
.muted{color:var(--mut)}
.kv{display:grid;grid-template-columns:max-content 1fr;gap:3px 14px}
.kv dt{color:var(--mut)}.kv dd{margin:0}
.links a{margin-right:14px}
code,pre,.mono{font-family:var(--mono)}
.ferr{border:0;background:none;padding:0;color:var(--bad-fg);white-space:normal;display:block;font-size:13px}
.field{margin:12px 0}.field>label,.field>.lbl{display:block;font-weight:500;font-size:13px;margin-bottom:4px}
.field .help{color:var(--mut);font-size:12px;margin-top:4px}
.field .warn{color:var(--warn-fg);font-size:12px;margin-top:4px}
.field .error{color:var(--bad-fg);font-size:12px;margin-top:4px}
input[type=text],input[type=number],input[type=password],input[type=time],input[type=datetime-local],select,textarea{font:inherit;min-height:40px;padding:6px 10px;border:1px solid var(--field-line);border-radius:6px;max-width:100%;background:var(--card);color:var(--fg)}
textarea{min-height:80px}
input[type=text],textarea{width:100%;max-width:560px}
.days label{margin-right:10px;white-space:nowrap}
button,.btn{font:inherit;display:inline-flex;align-items:center;justify-content:center;gap:6px;min-height:40px;padding:0 16px;border:1px solid var(--pri);background:var(--card);color:var(--pri);border-radius:6px;cursor:pointer;font-weight:600;text-decoration:none}
button.pri,.btn.pri{background:var(--pri);color:var(--on-dark)}
button.sec,.btn.sec{border-color:var(--field-line);color:var(--fg);font-weight:400}
button.dangerline,.btn.dangerline{border-color:var(--danger);color:var(--danger);background:var(--card)}
button.danger,.btn.danger{background:var(--danger);border-color:var(--danger);color:var(--on-dark)}
button.small,.btn.small{min-height:32px;padding:0 10px}
button:disabled,input:disabled,select:disabled,textarea:disabled,.btn[aria-disabled=true]{opacity:.5;cursor:not-allowed}
.formbox{border:1px solid var(--line);border-radius:6px;padding:8px 12px;margin:10px 0;background:var(--bg)}
.notice{border-left:5px solid var(--bar-done);background:var(--ok-bg);padding:8px 12px}
.testres{padding:6px 10px;border-radius:4px;margin:8px 0}.testres.ok{background:var(--ok-bg);color:var(--ok-fg)}.testres.fail{background:var(--bad-bg);color:var(--bad-fg)}
.errsum{border-left:5px solid var(--bar-fail);background:var(--bad-bg);padding:8px 12px}
table.edit input[type=text],table.edit select,table.edit input[type=number]{width:100%;min-width:90px}
.tablewrap{overflow-x:auto}
.grid2{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:20px}
.grid3{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:20px}
.tabs{display:flex;gap:4px;border-bottom:1px solid var(--line);overflow-x:auto}
.tabs a{display:inline-flex;align-items:center;min-height:42px;padding:0 16px;color:var(--fg);text-decoration:none;border-bottom:3px solid transparent;white-space:nowrap}
.tabs a:hover{background:var(--hover)}
.tabs a[aria-selected=true]{color:var(--link);font-weight:600;border-bottom-color:var(--link)}
.subnav-layout{display:grid;grid-template-columns:200px minmax(0,760px);gap:20px;align-items:start}
.subnav{display:flex;flex-direction:column;padding:8px 0}
.subnav a{display:block;min-height:40px;line-height:24px;padding:8px 16px;color:var(--fg);text-decoration:none;border-left:3px solid transparent}
.subnav a:hover{background:var(--hover)}
.subnav a[aria-current=page]{background:var(--sel-bg);color:var(--link);font-weight:600;border-left-color:var(--link)}
.savebar{position:sticky;bottom:0;display:flex;gap:12px;align-items:center;justify-content:space-between;background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 20px;box-shadow:0 -2px 8px var(--shadow)}
.savebar .actions{display:flex;gap:8px}
.stepper{display:flex;gap:8px;list-style:none;margin:0;padding:0;flex-wrap:wrap}
.stepper li{display:flex;align-items:center;gap:8px;padding:4px 12px 4px 4px;color:var(--mut)}
.stepper .num{display:inline-flex;align-items:center;justify-content:center;width:28px;height:28px;border-radius:50%;background:var(--idle-bg);color:var(--idle-fg);font-weight:600;border:1px solid var(--field-line)}
.stepper li.done{color:var(--ok-fg)}.stepper li.done .num{background:var(--ok-bg);color:var(--ok-fg);border-color:var(--ok-fg)}
.stepper li.current{color:var(--link);font-weight:600}.stepper li.current .num{background:var(--pri);color:var(--on-dark);border-color:var(--pri)}
.modal-backdrop{position:fixed;inset:0;background:var(--scrim);display:flex;align-items:center;justify-content:center;z-index:50;padding:16px}
.modal-backdrop[hidden]{display:none}
.modal{background:var(--card);border-radius:10px;width:520px;max-width:100%;max-height:90vh;overflow:auto;padding:24px;box-shadow:0 8px 32px var(--shadow)}
.modal h2{font-size:18px;margin-bottom:12px}
.modal .actions{display:flex;gap:8px;justify-content:flex-end;margin-top:20px}
.banner{display:flex;gap:12px;align-items:center;justify-content:space-between;padding:10px 16px;border-radius:6px;border-left:5px solid var(--bar-wait);background:var(--warn-bg);color:var(--warn-fg)}
.banner.error{border-left-color:var(--bar-fail);background:var(--bad-bg);color:var(--bad-fg)}
.banner[hidden]{display:none}
.skeleton{display:inline-block;min-width:80px;height:1em;border-radius:4px;background:var(--skel);vertical-align:middle;animation:gipulse 1.4s ease-in-out infinite}
@keyframes gipulse{50%{opacity:.5}}
.bars{display:flex;gap:4px}.bars span{flex:1;height:6px;border-radius:3px;background:var(--bar-pending)}
.bars .done{background:var(--bar-done)}.bars .running{background:var(--bar-run)}.bars .waiting{background:var(--bar-wait)}.bars .failed{background:var(--bar-fail)}
.pagehead{display:flex;justify-content:space-between;gap:16px;align-items:flex-start;flex-wrap:wrap}
.pagehead p{margin:4px 0 0}.headbtns{display:flex;gap:8px;flex-wrap:wrap}
.small{font-size:12px}.right{text-align:right}
.cardgrid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:20px;align-items:stretch}
@media (max-width:1100px){.cardgrid{grid-template-columns:repeat(2,minmax(0,1fr))}}
@media (max-width:700px){.cardgrid{grid-template-columns:1fr}}
.gicard{position:relative;display:flex;flex-direction:column;gap:16px;overflow:visible}
.gicard.failed{border-color:var(--bad-fg)}
.cardhead{display:flex;justify-content:space-between;gap:8px;align-items:flex-start}
.cardhead h2{font-size:16px}
a.cardlink{color:var(--fg);text-decoration:none}a.cardlink::after{content:"";position:absolute;inset:0;border-radius:10px}
a.cardlink:focus-visible{outline-offset:-2px}
.gicard .btn,.gicard button,.gicard a:not(.cardlink){position:relative;z-index:1}
dl.facts{margin:0;display:flex;flex-direction:column;gap:4px;font-size:13px}
dl.facts>div{display:flex;justify-content:space-between;gap:8px}dl.facts dt{color:var(--mut)}dl.facts dd{margin:0;text-align:right}
.caption{margin:6px 0 0;font-size:12px;color:var(--mut)}.caption.bad{color:var(--bad-fg)}
table.pooltable{font-size:12px}table.pooltable td,table.pooltable th{padding:5px 4px}
table.pooltable td[data-col=snapshot]{font-family:var(--mono)}
.linkbtn{border:0;background:none;color:var(--link);text-decoration:underline;min-height:32px;padding:0;font-weight:400;justify-content:flex-start}
.cardactions{margin-top:auto;display:flex;flex-direction:column;gap:8px}
.cardactions .row1 .btn{width:100%}.cardactions .row2{display:flex;gap:8px}.cardactions .row2>*{flex:1}
.cardactions .row1>span{display:block}.cardactions .row1>span .btn{width:100%}
.livemsg{background:var(--bad-bg);color:var(--bad-fg);border-radius:6px;padding:8px 10px;display:flex;gap:8px;justify-content:space-between;align-items:center;font-size:12px}
.livemsg[hidden]{display:none}.livemsg button{white-space:nowrap;flex:none}
.addtile{border-style:dashed;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;gap:8px;min-height:240px}
.empty{max-width:560px;margin:40px auto;text-align:center}.checklist{list-style:none;padding:0;text-align:left;display:inline-block}
.banners{display:flex;flex-direction:column;gap:8px}
.pager{display:flex;gap:12px;align-items:center;justify-content:flex-end}
.strip{display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap;align-items:center;background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 20px}
.twocol{display:grid;grid-template-columns:minmax(0,1fr) 340px;gap:20px;align-items:start}
.twocol .col{display:flex;flex-direction:column;gap:20px}
@media (max-width:900px){.twocol{grid-template-columns:1fr}}
.btnrow{display:flex;gap:8px;margin:12px 0}.btnrow .btn{flex:1}
.filterrow{display:flex;gap:16px;align-items:center;margin-bottom:12px;flex-wrap:wrap}.field.inline{margin:0;display:flex;gap:8px;align-items:center}.field.inline label{margin:0}
.summary{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:16px}.summary dt{font-size:12px;color:var(--mut)}.summary dd{margin:2px 0 0}
@media (max-width:900px){.summary{grid-template-columns:repeat(2,minmax(0,1fr))}}
ol.stages{list-style:none;margin:0;padding:0;display:grid;grid-template-columns:repeat(8,minmax(0,1fr));gap:12px}
ol.stages li{font-size:12px}ol.stages li .bar{height:6px;border-radius:3px;background:var(--bar-pending);margin-bottom:6px}
ol.stages li.done .bar{background:var(--bar-done)}ol.stages li.running .bar{background:var(--bar-run)}ol.stages li.waiting .bar{background:var(--bar-wait)}ol.stages li.failed .bar{background:var(--bar-fail)}
ol.stages li strong{display:block}
@media (max-width:900px){ol.stages{grid-template-columns:1fr}}
.nowline{border-top:1px solid var(--line);margin-top:12px;padding-top:12px}
.approval{border:2px solid var(--bar-wait)}
.stagerow{border:1px solid var(--line);border-radius:10px;background:var(--card)}
.stagerow.running{border-color:var(--bar-run)}.stagerow.failed{border-color:var(--bar-fail)}.stagerow.waiting{border-color:var(--bar-wait)}
.stagerow>summary{display:grid;grid-template-columns:140px 110px 80px minmax(0,1fr);gap:12px;align-items:center;padding:12px 20px;cursor:pointer;min-height:40px}
.stagerow>summary .msg{color:var(--mut);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.stagerow .inner{padding:0 20px 16px}
@media (max-width:900px){.stagerow>summary{grid-template-columns:1fr}}
.stepcard{border:1px solid var(--bar-run);border-radius:8px;padding:12px;margin:8px 0}
.logbox{white-space:pre;overflow:auto}
.alert{border-left:5px solid var(--bar-fail);background:var(--bad-bg);color:var(--bad-fg);border-radius:6px;padding:12px 16px}
.settings-layout{display:grid;grid-template-columns:200px minmax(0,760px);gap:20px;align-items:start}
@media (max-width:900px){.settings-layout{grid-template-columns:1fr}}
.settings-main .field input[type=text],.settings-main textarea{max-width:none}
.dangerzone{border-color:var(--danger)}.dangerzone h2{color:var(--danger)}
fieldset.wizstep{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:20px;margin:0 0 20px;min-inline-size:0}fieldset.wizstep legend{float:left;width:100%;margin:0 0 12px;padding:0}fieldset.wizstep legend+*{clear:both}fieldset.wizstep[hidden]{display:none}fieldset.wizstep h2:focus-visible{outline:2px solid var(--link)}
.wizfoot{display:flex;justify-content:space-between;align-items:center;gap:12px}
.cols2{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:20px}
@media (max-width:900px){.cols2{grid-template-columns:1fr}}
td.nowrap,.nowrap{white-space:nowrap}
.skip{position:absolute;left:-9999px;top:0}.skip:focus{left:8px;top:8px;z-index:99;background:var(--card);color:var(--link);padding:8px 12px;border-radius:6px}
.sr-only{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}
.setup-step{border-left:5px solid var(--line)}.setup-step.s-running{border-left-color:var(--bar-run)}.setup-step.s-done{border-left-color:var(--bar-done)}.setup-step.s-failed{border-left-color:var(--bar-fail)}
.setup-step h2{margin:0 0 4px;font-size:16px}.setup-step .num{display:inline-block;min-width:22px;color:var(--mut)}
.badge.sb-pending,.badge.sb-skipped{background:var(--idle-bg);color:var(--idle-fg)}.badge.sb-skipped{font-style:italic}
.badge.sb-running{background:var(--run-bg);color:var(--run-fg)}.badge.sb-done{background:var(--ok-bg);color:var(--ok-fg)}.badge.sb-failed{background:var(--bad-bg);color:var(--bad-fg)}
.spinner{display:inline-block;width:10px;height:10px;margin-right:5px;border:2px solid currentColor;border-top-color:transparent;border-radius:50%;animation:gispin 1s linear infinite;vertical-align:-1px}
@keyframes gispin{to{transform:rotate(360deg)}}
pre.detail{background:var(--hover);border:1px solid var(--line);border-radius:4px;padding:6px 8px;margin:6px 0;white-space:pre-wrap;font-size:12px;max-height:260px;overflow:auto}
.setup-step fieldset{border:0;padding:0;margin:0}.setup-step .choice{margin:8px 0}
.banner-ok{border-left:5px solid var(--bar-done);background:var(--ok-bg);padding:8px 12px;font-weight:600}
.waits{color:var(--mut);font-style:italic}
tr.steplogrow>td{padding-top:0}
details.steplog>summary{cursor:pointer;color:var(--mut);font-size:12px}
.logbox{font-family:ui-monospace,Consolas,monospace;font-size:12px;background:var(--hover);border:1px solid var(--line);border-radius:4px;padding:4px 8px;margin:4px 0;max-height:320px;overflow:auto;white-space:pre-wrap;word-break:break-word}
.logbox .ll{margin:0}.logbox .lt{color:var(--mut);margin-right:8px}
.logbox .lv-out{color:var(--mut)}.logbox .lv-info{color:var(--fg)}.logbox .lv-warn{color:var(--warn-fg)}.logbox .lv-error{color:var(--bad-fg);font-weight:600}
'@
}

function Get-GINavIcon {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    $p = switch ($Name) {
        'list'    { '<path d="M8 6h12M8 12h12M8 18h12"/><path d="M3.5 6h.01M3.5 12h.01M3.5 18h.01"/>' }
        'layers'  { '<path d="M12 3 3 8l9 5 9-5-9-5z"/><path d="m3 13 9 5 9-5"/>' }
        'play'    { '<path d="M7 4.5v15l12-7.5-12-7.5z"/>' }
        'gear'    { '<circle cx="12" cy="12" r="3"/><path d="M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.3 5.3l2.1 2.1M16.6 16.6l2.1 2.1M18.7 5.3l-2.1 2.1M7.4 16.6l-2.1 2.1"/>' }
        'clipboard' { '<rect x="6" y="4" width="12" height="17" rx="2"/><path d="M9 4h6v3H9zM9 12h6M9 16h6"/>' }
        'wrench'  { '<path d="M14.5 6.5a4 4 0 0 0 4.9 4.9l-9.4 9.4a2.1 2.1 0 0 1-3-3l9.4-9.4a4 4 0 0 0-1.9-1.9z"/>' }
        'braces'  { '<path d="M9 4C6.5 4 7.5 9 5 12c2.5 3 1.5 8 4 8M15 4c2.5 0 1.5 5 4 8-2.5 3-1.5 8-4 8"/>' }
        'lock'    { '<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>' }
        'menu'    { '<path d="M4 6h16M4 12h16M4 18h16"/>' }
        'chevrons' { '<path d="m13 6-6 6 6 6M19 6l-6 6 6 6"/>' }
        default   { '' }
    }
    "<svg class=""ico"" width=""18"" height=""18"" viewBox=""0 0 24 24"" fill=""none"" stroke=""currentColor"" stroke-width=""2"" stroke-linecap=""round"" stroke-linejoin=""round"" aria-hidden=""true"" focusable=""false"">$p</svg>"
}

function Get-GINavItems {
    <# The fixed, ordered side-nav item list. Role 'Admin' items are disabled for non-admins; HideForNonAdmin items are not rendered for them. A $null entry is the divider. #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    @(
        @{ Label = 'Golden images'; Href = '/'; Icon = 'layers' }
        @{ Label = 'Audit log'; Href = '/audit'; Icon = 'clipboard' }
        $null
        # Interim: the page is still admin-only until task 08 makes it read-only for other roles.
        @{ Label = 'Global settings'; Href = '/settings'; Icon = 'gear'; Role = 'Admin' }
        @{ Label = 'Setup'; Href = '/setup'; Icon = 'wrench'; Role = 'Admin'; HideForNonAdmin = $true }
        @{ Label = 'JSON API'; Href = '/api/runs'; Icon = 'braces'; Muted = $true }
    )
}

function New-GISideNav {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Context)
    $path = if ($Context.ContainsKey('Path')) { [string]$Context.Path } else { '' }
    $isAdmin = $Context.ContainsKey('IsAdmin') -and [bool]$Context.IsAdmin
    $setupMode = $Context.ContainsKey('SetupMode') -and [bool]$Context.SetupMode
    $setupComplete = (-not $Context.ContainsKey('SetupComplete')) -or [bool]$Context.SetupComplete
    $setupLocked = $setupMode -and -not $setupComplete

    $parts = foreach ($item in (Get-GINavItems)) {
        if ($null -eq $item) { '<hr class="navdivider">'; continue }
        if ($item.HideForNonAdmin -and -not $isAdmin) { continue }
        $label = ConvertTo-GIHtml $item.Label
        $href = $item.Href
        $icon = Get-GINavIcon $item.Icon
        $disabledTitle = $null
        if ($setupLocked) {
            if ($href -ne '/setup') { $disabledTitle = 'Finish setup first' }
        } elseif ($item.Role -eq 'Admin' -and -not $isAdmin) {
            $disabledTitle = 'Admins only'
        }
        $active = $false
        if ($href -eq '/') { $active = ($path -eq '/' -or $path.StartsWith('/runs/') -or $path.StartsWith('/images')) }
        elseif ($href -eq '/settings') { $active = ($path -eq '/settings' -or $path.StartsWith('/settings/')) }
        else { $active = ($path -eq $href) }
        $muted = if ($item.Muted) { ' muted' } else { '' }
        if ($disabledTitle) {
            $t = ConvertTo-GIHtml $disabledTitle
            "<span class=""navitem disabled"" aria-disabled=""true"" title=""$t"">$icon<span class=""label"">$label</span><span class=""navlock"">$(Get-GINavIcon 'lock')</span></span>"
        } else {
            $cls = "navitem$muted"; $cur = ''
            if ($active) { $cls = 'navitem active'; $cur = ' aria-current="page"' }
            "<a class=""$cls"" href=""$href"" title=""$label""$cur>$icon<span class=""label"">$label</span></a>"
        }
    }
    $collapse = "<button type=""button"" class=""navcollapse"" aria-expanded=""true"" aria-controls=""sidenav"" aria-label=""Collapse menu"" title=""Collapse menu"">$(Get-GINavIcon 'chevrons')<span class=""label"">Collapse</span></button>"
    "<nav class=""sidenav"" id=""sidenav"" aria-label=""Main"">$collapse$(@($parts) -join '')</nav>"
}

function Get-GINavScript {
    @'
(function(){
var K='giNavCollapsed',b=document.body;
function get(){try{return localStorage.getItem(K)}catch(e){return null}}
function put(v){try{localStorage.setItem(K,v)}catch(e){}}
if(get()==='1'){b.classList.add('nav-collapsed')}
function sync(){
var c=b.classList.contains('nav-collapsed'),o=b.classList.contains('nav-open');
var x=document.querySelector('.navcollapse');
if(x){x.setAttribute('aria-expanded',c?'false':'true');var t=c?'Expand menu':'Collapse menu';x.setAttribute('aria-label',t);x.title=t}
var m=document.querySelector('.navtoggle-mobile');
if(m){m.setAttribute('aria-expanded',o?'true':'false')}
}
document.addEventListener('DOMContentLoaded',sync);
document.addEventListener('click',function(e){
var t=e.target;if(!t||!t.closest){return}
if(t.closest('.navcollapse')){b.classList.toggle('nav-collapsed');put(b.classList.contains('nav-collapsed')?'1':'0');sync();return}
if(t.closest('.navtoggle-mobile')){b.classList.toggle('nav-open');sync();return}
if(b.classList.contains('nav-open')&&!t.closest('.sidenav')){b.classList.remove('nav-open');sync()}
});
document.addEventListener('keydown',function(e){
if(e.key==='Escape'&&b.classList.contains('nav-open')){b.classList.remove('nav-open');sync();var m=document.querySelector('.navtoggle-mobile');if(m){m.focus()}}
});
})();
'@
}

function New-GIPage {
    [CmdletBinding()]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Per-request nav context set by the dashboard middleware; Pode routes and view builders share no other channel.')]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$BodyHtml,   # already-encoded HTML
        [int]$RefreshSeconds = 0
    )
    $refresh = ''
    if ($RefreshSeconds -gt 0) { $refresh = "<meta http-equiv=""refresh"" content=""$RefreshSeconds"">" }
    $ctx = @{ Path = ''; IsAdmin = $false; IsApprover = $false; SetupMode = $false; SetupComplete = $true; UserName = ''; Role = ''; Token = '' }
    $g = Get-Variable -Name GINavContext -Scope Global -ErrorAction SilentlyContinue
    if ($g -and $g.Value -is [System.Collections.IDictionary]) { foreach ($k in $g.Value.Keys) { $ctx[[string]$k] = $g.Value[$k] } }
    $nav = New-GISideNav -Context $ctx
    $menuIcon = Get-GINavIcon 'menu'
    $userBox = ''
    if ($ctx.UserName) { $userBox = "<div class=""userbox""><span>$(ConvertTo-GIHtml $ctx.UserName)</span><span class=""rolepill"">$(ConvertTo-GIHtml $ctx.Role)</span></div>" }
    $uiScript = if (Get-Command -Name Get-GIUiScript -ErrorAction SilentlyContinue) { Get-GIUiScript } else { '' }
    @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="gi-token" content="$(ConvertTo-GIHtml $ctx.Token)">
$refresh
<title>$(ConvertTo-GIHtml $Title)</title>
<style>$(Get-GICss)</style></head>
<body>
<script>$(Get-GINavScript)</script>
<a class="skip" href="#main">Skip to content</a>
<header class="topbar"><button type="button" class="navtoggle-mobile" aria-controls="sidenav" aria-expanded="false" aria-label="Open menu">$menuIcon</button><div class="apptitle">VDI Golden Image Pipeline</div>$userBox</header>
<div class="layout">
$nav
<main id="main" tabindex="-1">
<div class="banner" id="gi-expired" role="alert" hidden><span class="banner-text">Your session expired. Sign in again to continue.</span><a href="/">Sign in</a></div>
$BodyHtml
<div id="gi-live" class="sr-only" role="status" aria-live="polite"></div>
</main>
</div>
<div class="navbackdrop"></div>
<script>$uiScript</script>
</body></html>
"@
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

function Get-GIDashboardUser {
    # DOMAIN\user of the authenticated caller; 'local-admin' with -LocalAdmin; 'anonymous' with -NoAuth
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Context, $WebEvent)
    if ($Context['LocalAdmin']) { return 'local-admin' }
    if ($Context.NoAuth -or -not $WebEvent -or -not $WebEvent.Auth -or -not $WebEvent.Auth.User) { return 'anonymous' }
    $u = $WebEvent.Auth.User
    $name = if ($u.Username) { [string]$u.Username } else { [string]$u.Name }
    if ($u.Domain) { return "$($u.Domain)\$name" }
    return $name
}

function Test-GIDashboardGroup {
    param([Parameter(Mandatory)]$Context, $WebEvent, [string]$Group)
    if ($Context['LocalAdmin']) { return $true }
    if ($Context.NoAuth -or -not $Group) { return $false }
    if (-not $WebEvent -or -not $WebEvent.Auth -or -not $WebEvent.Auth.User) { return $false }
    return [bool](@($WebEvent.Auth.User.Groups) | Where-Object { $_ -eq $Group })
}

function Test-GIDashboardApprover {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Context, $WebEvent)
    return (Test-GIDashboardGroup -Context $Context -WebEvent $WebEvent -Group $Context['ApproverShort'])
}

function Test-GIDashboardAdmin {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Context, $WebEvent)
    return (Test-GIDashboardGroup -Context $Context -WebEvent $WebEvent -Group $Context['AdminShort'])
}

function Get-GIDashboardConfig {
    # Fresh config per request so settings saved in the UI are used right away
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    $a = @{}
    if ($Context['ConfigPath']) { $a.Path = $Context['ConfigPath'] }
    return (Get-GIConfig @a)
}

function Get-GIPostRejection {
    <#
    .SYNOPSIS
      Shared checks for every state-changing POST. Returns $null when allowed, else @{ Code; Message }.
      Role: 'Admin' or 'Approver'. FormId must match the id the form's token was issued for.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        $WebEvent,
        [Parameter(Mandatory)][ValidateSet('Admin', 'Approver')][string]$Role,
        [Parameter(Mandatory)][string]$FormId,
        [hashtable]$Headers
    )
    if ($Context.NoAuth -and -not $Context['LocalAdmin']) { return @{ Code = 403; Message = 'The dashboard is read-only when it runs without authentication.' } }
    $ok = if ($Role -eq 'Admin') { Test-GIDashboardAdmin -Context $Context -WebEvent $WebEvent } else { Test-GIDashboardApprover -Context $Context -WebEvent $WebEvent }
    if (-not $ok) {
        try {
            $callerRole = if (Test-GIDashboardAdmin -Context $Context -WebEvent $WebEvent) { 'Admin' } elseif (Test-GIDashboardApprover -Context $Context -WebEvent $WebEvent) { 'Approver' } else { 'Viewer' }
            $path = if ($WebEvent) { [string]$WebEvent.Path } else { '' }
            Write-GIAudit -Config (Get-GIDashboardConfig $Context) -User (Get-GIDashboardUser -Context $Context -WebEvent $WebEvent) -Action 'auth.denied' -Target $path -Detail @{ needed = $Role; role = $callerRole; result = 'Denied' }
        } catch { Write-Verbose "Could not audit the denied request: $($_.Exception.Message)" }
        return @{ Code = 403; Message = "You are not in the $($Role.ToLower()) group." }
    }
    $origin = if ($Headers) { [string]$Headers['Origin'] } else { '' }
    $hostHdr = if ($Headers) { [string]$Headers['Host'] } else { '' }
    if ($origin -and $origin -ne 'null') {
        try { $auth = ([uri]$origin).Authority } catch { $auth = '' }
        if ($auth -ne $hostHdr) { return @{ Code = 403; Message = 'Cross-origin request refused.' } }
    }
    $user = Get-GIDashboardUser -Context $Context -WebEvent $WebEvent
    $token = if ($WebEvent -and $WebEvent.Data) { [string]$WebEvent.Data['token'] } else { '' }
    if (-not (Test-GIFormToken -Secret $Context.FormSecret -User $user -RunId $FormId -Token $token)) {
        return @{ Code = 403; Message = 'Form expired or invalid. Reload the page and try again.' }
    }
    return $null
}
