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
    $ctx = @{ Path = ''; IsAdmin = $false; IsApprover = $false; SetupMode = $false; SetupComplete = $true; UserName = ''; Role = '' }
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
$refresh
<title>$(ConvertTo-GIHtml $Title)</title>
<style>$(Get-GICss)</style></head>
<body>
<script>$(Get-GINavScript)</script>
<a class="sr-only" href="#main">Skip to content</a>
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

function Get-GIStepLogLinesHtml {
    <# Log lines as <div class="ll lv-*"> rows. Everything from the log is HTML-encoded. #>
    [CmdletBinding()]
    [OutputType([string])]
    param($Lines)
    $rows = foreach ($l in @($Lines)) {
        if ($null -eq $l) { continue }
        $lv = ([string](Get-GIValue $l 'level' 'INFO')).ToLowerInvariant()
        if ($lv -notin @('info', 'warn', 'error', 'out')) { $lv = 'info' }
        $at = [string](Get-GIValue $l 'at' '')
        $t = if ($at -match 'T(\d\d:\d\d:\d\d)') { $Matches[1] } else { '' }
        "<div class=""ll lv-$lv""><span class=""lt"">$(ConvertTo-GIHtml $t)</span>$(ConvertTo-GIHtml (Get-GIValue $l 'text'))</div>"
    }
    @($rows) -join ''
}

function Get-GIStepLogScript {
    # Polls open step logs of Running steps; log text only ever goes in through textContent.
    @'
(function(){
var MAXL=2000,EVERY=10000;
function stamp(a){var m=/T(\d\d:\d\d:\d\d)/.exec(a||'');return m?m[1]:''}
function add(box,l){
var d=document.createElement('div');
var lv=(l.level||'INFO').toLowerCase();if(['info','warn','error','out'].indexOf(lv)<0){lv='info'}
d.className='ll lv-'+lv;
var t=document.createElement('span');t.className='lt';t.textContent=stamp(l.at);
d.appendChild(t);d.appendChild(document.createTextNode(l.text==null?'':String(l.text)));
box.appendChild(d);
while(box.childNodes.length>MAXL){box.removeChild(box.firstChild)}
}
function key(d){return 'giLogOpen:'+d.getAttribute('data-run')+':'+d.getAttribute('data-step')}
function poll(d){
if(d.getAttribute('data-running')!=='1'||d.getAttribute('data-busy')==='1'){return}
d.setAttribute('data-busy','1');
var box=d.querySelector('.logbox');
var url='/runs/'+d.getAttribute('data-run')+'/steps/'+d.getAttribute('data-step')+'/log?offset='+encodeURIComponent(d.getAttribute('data-offset')||'0');
fetch(url,{credentials:'same-origin',headers:{'Accept':'application/json'}}).then(function(r){return r.ok?r.json():null}).then(function(j){
d.removeAttribute('data-busy');
if(!j){return}
var atEnd=box.scrollTop+box.clientHeight>=box.scrollHeight-8;
if(j.offset<parseInt(d.getAttribute('data-offset')||'0',10)){while(box.firstChild){box.removeChild(box.firstChild)}}
(j.lines||[]).forEach(function(l){add(box,l)});
d.setAttribute('data-offset',String(j.offset));
if(atEnd){box.scrollTop=box.scrollHeight}
if(!j.running){d.setAttribute('data-running','0')}
}).catch(function(){d.removeAttribute('data-busy')});
}
function all(){return document.querySelectorAll('details.steplog')}
function tick(){Array.prototype.forEach.call(all(),function(d){if(d.open){poll(d)}})}
document.addEventListener('DOMContentLoaded',function(){
Array.prototype.forEach.call(all(),function(d){
var box=d.querySelector('.logbox');if(box){box.scrollTop=box.scrollHeight}
try{if(sessionStorage.getItem(key(d))==='1'){d.open=true}}catch(e){}
d.addEventListener('toggle',function(){
try{sessionStorage.setItem(key(d),d.open?'1':'0')}catch(e){}
if(d.open){poll(d)}
});
});
setInterval(tick,EVERY);
});
})();
'@
}

function Get-GIStepTableHtml {
    <#
    Nested table of Maintain sub-steps (run.stages.Maintain.steps); '' when there are none.
    StepLogs maps step id -> @{ Lines; Offset } for the steps that get a live log; the caller reads the files so this stays pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param($Steps, [string]$RunId = '', $StepLogs = $null)
    $list = @(@($Steps) | Where-Object { $null -ne $_ })
    if (-not $list.Count) { return '' }
    $rows = foreach ($st in $list) {
        $s = [string](Get-GIValue $st 'status' 'Pending')
        $started = Get-GIValue $st 'startedAt' $null
        $ended = Get-GIValue $st 'endedAt' $null
        $dur = if ($started) { ConvertTo-GIHtml (Format-GIDuration $started $ended) } else { '' }
        "<tr><td>$(Get-GIStatusIcon $s)$(ConvertTo-GIHtml (Get-GIValue $st 'label' (Get-GIValue $st 'id')))</td><td>$(Get-GIStatusBadge $s)</td><td>$(Format-GIDate $started)</td><td>$dur</td><td>$(ConvertTo-GIHtml (Get-GIValue $st 'message'))</td></tr>"
        $sid = [string](Get-GIValue $st 'id' '')
        if ($StepLogs -is [System.Collections.IDictionary] -and $sid -and $RunId -and $StepLogs.Contains($sid)) {
            $log = $StepLogs[$sid]
            $lines = @(Get-GIValue $log 'Lines' @())
            $isRunning = if ($s -eq 'Running') { '1' } else { '0' }
            $summary = if ($lines.Count) { "Log ($($lines.Count) lines)" } else { 'Log' }
            "<tr class=""steplogrow""><td colspan=""5""><details class=""steplog"" data-run=""$(ConvertTo-GIHtml ([uri]::EscapeDataString($RunId)))"" data-step=""$(ConvertTo-GIHtml ([uri]::EscapeDataString($sid)))"" data-offset=""$([int64](Get-GIValue $log 'Offset' 0))"" data-running=""$isRunning""><summary>$summary</summary><div class=""logbox"">$(Get-GIStepLogLinesHtml $lines)</div></details></td></tr>"
        }
    }
    "<table class=""steps""><thead><tr><th>Step</th><th>Status</th><th>Started</th><th>Duration</th><th>Message</th></tr></thead><tbody>$(@($rows) -join '')</tbody></table>"
}

function New-GIRunDetailPage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Run,
        [int]$RefreshSeconds = 0,
        [string]$ApprovalFormHtml = '',   # already-encoded form HTML, only passed for approvers
        [string]$NoticeHtml = '',         # already-encoded notice (e.g. result of an approve/reject)
        $StepLogs = $null                 # hashtable step id -> @{ Lines; Offset }, read by the route (views do no file access)
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
        $stepHtml = Get-GIStepTableHtml (Get-GIValue $st 'steps' @()) -RunId ([string](Get-GIValue $Run 'runId')) -StepLogs $StepLogs
        if ($stepHtml) { $body += "<tr class=""substeps""><td></td><td colspan=""5"">$stepHtml</td></tr>" }
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

    if ($body.Contains('class="steplog"')) { $body += "<script>$(Get-GIStepLogScript)</script>" }
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
