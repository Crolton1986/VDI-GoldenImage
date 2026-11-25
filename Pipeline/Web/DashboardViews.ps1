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
header.topbar{background:#1d2733;color:#fff;padding:10px 16px;display:flex;gap:12px;align-items:center}
header.topbar h1{font-size:17px;margin:0}
.layout{display:grid;grid-template-columns:240px minmax(0,1fr);align-items:start}
body.nav-collapsed .layout{grid-template-columns:56px minmax(0,1fr)}
main{padding:12px 16px;max-width:1200px;width:100%;margin:0 auto}
.sidenav{position:sticky;top:0;height:100vh;overflow-y:auto;background:var(--card);border-right:1px solid var(--line);padding:8px 0;display:flex;flex-direction:column}
.sidenav button.navcollapse{display:flex;align-items:center;gap:12px;width:100%;margin:0 0 6px;padding:8px 18px;border:0;border-radius:0;background:none;color:var(--mut);text-align:left}
.sidenav button.navcollapse:hover{background:#eef2f6;color:var(--fg)}
.sidenav button.navcollapse .ico{transition:transform .15s}
body.nav-collapsed .navcollapse .ico{transform:rotate(180deg)}
.navitem{display:flex;align-items:center;gap:12px;padding:9px 18px;color:var(--fg);text-decoration:none;border-left:4px solid transparent;padding-left:14px}
.navitem .ico,.navchild .ico{flex:none}
.navitem .label{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
a.navitem:hover,.navchild:hover{background:#eef2f6}
.navitem.active{background:#e6f0fb;border-left-color:var(--link);font-weight:600}
.navitem.disabled,.navchild.disabled{color:var(--mut);opacity:.55;cursor:not-allowed}
.navlock{display:inline-flex;margin-left:auto}.navlock .ico{width:14px;height:14px}
.navsub{margin:0}
.navsub summary{cursor:pointer;padding:3px 18px 3px 54px;font-size:12px;text-transform:uppercase;letter-spacing:.03em;color:var(--mut)}
.navchild{display:block;padding:6px 18px 6px 54px;color:var(--fg);text-decoration:none;border-left:4px solid transparent}
.navchild.active{background:#e6f0fb;border-left-color:var(--link);font-weight:600}
.sidenav a:focus-visible,.sidenav button:focus-visible,.sidenav summary:focus-visible,.navtoggle-mobile:focus-visible{outline:2px solid var(--link);outline-offset:-2px}
.navtoggle-mobile{display:none;padding:4px 6px;background:none;border:1px solid #cfe3ff;color:#fff}
.navtoggle-mobile:focus-visible{outline-color:#cfe3ff}
.navbackdrop{display:none}
body.nav-collapsed .sidenav .label,body.nav-collapsed .navsub,body.nav-collapsed .navlock{display:none}
body.nav-collapsed .navitem{padding-right:0;justify-content:flex-start}
@media (max-width:760px){
.layout{display:block}
body.nav-collapsed .layout{display:block}
.navtoggle-mobile{display:inline-flex}
.sidenav{position:fixed;top:0;left:0;bottom:0;width:260px;max-width:85vw;height:auto;z-index:30;transform:translateX(-100%);transition:transform .2s;box-shadow:2px 0 12px rgba(0,0,0,.25)}
body.nav-open .sidenav{transform:none}
body.nav-open .navbackdrop{display:block;position:fixed;inset:0;background:rgba(0,0,0,.4);z-index:20}
.sidenav button.navcollapse{display:none}
body.nav-collapsed .sidenav .label,body.nav-collapsed .navsub,body.nav-collapsed .navlock{display:revert}
body.nav-collapsed .sidenav .navsub{display:block}
}
@media (prefers-reduced-motion:reduce){.sidenav,.navcollapse .ico{transition:none}}
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
tr.substeps>td{padding-top:0;border-bottom:1px solid var(--line)}table.steps th,table.steps td{padding:3px 6px;font-size:13px;border-bottom:1px dashed var(--line)}table.steps tr:last-child td{border-bottom:0}
.err{border-left:5px solid #c0392b;background:#fdf0ee;padding:8px 12px;white-space:pre-wrap}
.muted{color:var(--mut)}
.kv{display:grid;grid-template-columns:max-content 1fr;gap:3px 14px}
.kv dt{color:var(--mut)}.kv dd{margin:0}
.links a{margin-right:14px}
code,pre{font-family:ui-monospace,Consolas,monospace}
.ferr{border:0;background:none;padding:0;color:#c0392b;white-space:normal;display:block;font-size:13px}
.field{margin:12px 0}.field>label,.field>.lbl{display:block;font-weight:600;margin-bottom:3px}
.field .help{color:var(--mut);font-size:12px;margin-top:2px}
.field .warn{color:#8a5a00;font-size:12px;margin-top:2px}
input[type=text],input[type=number],input[type=password],input[type=time],select,textarea{font:inherit;padding:4px 6px;border:1px solid var(--line);border-radius:4px;max-width:100%}
input[type=text],textarea{width:100%;max-width:560px}
.days label{margin-right:10px;white-space:nowrap}
button{font:inherit;padding:5px 14px;border:1px solid #0b5cad;background:#0b5cad;color:#fff;border-radius:4px;cursor:pointer}
button.sec{background:#fff;color:#0b5cad}button.danger{background:#c0392b;border-color:#c0392b}
button:disabled,input:disabled,select:disabled{opacity:.5;cursor:not-allowed}
.formbox{border:1px solid var(--line);border-radius:6px;padding:8px 12px;margin:10px 0;background:#fafbfc}
.notice{border-left:5px solid #1e8a44;background:#eef8f1;padding:8px 12px;margin:10px 0}
.testres{padding:6px 10px;border-radius:4px;margin:8px 0}.testres.ok{background:#e3f4e8;color:#14643a}.testres.fail{background:#fdf0ee;color:#9b2c1f}
.errsum{border-left:5px solid #c0392b;background:#fdf0ee;padding:8px 12px;margin:10px 0}
table.edit input[type=text],table.edit select,table.edit input[type=number]{width:100%;min-width:90px}
@media (max-width:600px){main{padding:8px}th,td{padding:5px 4px;font-size:13px}.kv{grid-template-columns:1fr}}
.setup-step{border-left:5px solid var(--line)}.setup-step.s-running{border-left-color:#1b6fd1}.setup-step.s-done{border-left-color:#1e8a44}.setup-step.s-failed{border-left-color:#c0392b}
.setup-step h2{margin:0 0 4px;font-size:16px}.setup-step .num{display:inline-block;min-width:22px;color:var(--mut)}
.badge.sb-pending{background:#9aa5b1}.badge.sb-running{background:#1b6fd1}.badge.sb-done{background:#1e8a44}.badge.sb-failed{background:#c0392b}.badge.sb-skipped{background:#9aa5b1;font-style:italic}
.spinner{display:inline-block;width:10px;height:10px;margin-right:5px;border:2px solid #fff;border-top-color:transparent;border-radius:50%;animation:gispin 1s linear infinite;vertical-align:-1px}
@keyframes gispin{to{transform:rotate(360deg)}}
pre.detail{background:#f0f3f6;border:1px solid var(--line);border-radius:4px;padding:6px 8px;margin:6px 0;white-space:pre-wrap;font-size:12px;max-height:260px;overflow:auto}
.setup-step fieldset{border:0;padding:0;margin:0}.setup-step .choice{margin:8px 0}
.banner-ok{border-left:5px solid #1e8a44;background:#eef8f1;padding:8px 12px;margin:10px 0;font-weight:600}
.waits{color:var(--mut);font-style:italic}
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
    <# The fixed, ordered side-nav item list. Role 'Admin' items are disabled (not hidden) for non-admins. #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $children = @()
    if (Get-Command -Name Get-GISettingsSchema -ErrorAction SilentlyContinue) {
        $schema = Get-GISettingsSchema
        if ($schema -is [System.Collections.IDictionary]) {
            $children = @(foreach ($key in $schema.Keys) {
                    $t = $schema[$key]
                    $label = if ($t -is [System.Collections.IDictionary] -and $t.Contains('Title')) { [string]$t['Title'] } else { [string]$key }
                    @{ Label = $label; Href = "/settings/$key"; Key = [string]$key }
                })
        }
    }
    @(
        @{ Label = 'Runs'; Href = '/'; Icon = 'list'; Role = ''; Children = @() }
        @{ Label = 'Pools'; Href = '/pools'; Icon = 'layers'; Role = ''; Children = @() }
        @{ Label = 'Run control'; Href = '/run'; Icon = 'play'; Role = 'Admin'; Children = @() }
        @{ Label = 'Settings'; Href = '/settings'; Icon = 'gear'; Role = 'Admin'; Children = $children }
        @{ Label = 'Audit'; Href = '/audit'; Icon = 'clipboard'; Role = 'Admin'; Children = @() }
        @{ Label = 'Setup'; Href = '/setup'; Icon = 'wrench'; Role = 'Admin'; Children = @() }
        @{ Label = 'JSON API'; Href = '/api/runs'; Icon = 'braces'; Role = ''; Children = @() }
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
        if ($href -eq '/') { $active = ($path -eq '/' -or $path.StartsWith('/runs/')) }
        elseif ($href -eq '/settings') { $active = ($path -eq '/settings' -or $path.StartsWith('/settings/')) }
        else { $active = ($path -eq $href) }
        $kids = @($item.Children)

        if ($disabledTitle) {
            $t = ConvertTo-GIHtml $disabledTitle
            $row = "<span class=""navitem disabled"" aria-disabled=""true"" title=""$t"">$icon<span class=""label"">$label</span><span class=""navlock"">$(Get-GINavIcon 'lock')</span></span>"
        } else {
            $cls = 'navitem'; $cur = ''
            if ($active) { $cls = 'navitem active'; $cur = ' aria-current="page"' }
            $row = "<a class=""$cls"" href=""$href"" title=""$label""$cur>$icon<span class=""label"">$label</span></a>"
        }
        if ($kids.Count -eq 0) { $row; continue }

        $kidHtml = foreach ($k in $kids) {
            $kl = ConvertTo-GIHtml $k.Label
            if ($disabledTitle) {
                "<span class=""navchild disabled"" aria-disabled=""true"" title=""$(ConvertTo-GIHtml $disabledTitle)"">$kl</span>"
            } elseif ($path -ieq $k.Href) {
                "<a class=""navchild active"" href=""$(ConvertTo-GIHtml $k.Href)"" aria-current=""page"">$kl</a>"
            } else {
                "<a class=""navchild"" href=""$(ConvertTo-GIHtml $k.Href)"">$kl</a>"
            }
        }
        $open = ''
        if ($active -and -not $disabledTitle) { $open = ' open' }
        "<div class=""navgroup"">$row<details class=""navsub""$open><summary>Sections</summary><div class=""navchildren"">$(@($kidHtml) -join '')</div></details></div>"
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
    $ctx = @{ Path = ''; IsAdmin = $false; IsApprover = $false; SetupMode = $false; SetupComplete = $true }
    $g = Get-Variable -Name GINavContext -Scope Global -ErrorAction SilentlyContinue
    if ($g -and $g.Value -is [System.Collections.IDictionary]) { foreach ($k in $g.Value.Keys) { $ctx[[string]$k] = $g.Value[$k] } }
    $nav = New-GISideNav -Context $ctx
    $menuIcon = Get-GINavIcon 'menu'
    @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
$refresh
<title>$(ConvertTo-GIHtml $Title)</title>
<style>$(Get-GICss)</style></head>
<body>
<script>$(Get-GINavScript)</script>
<header class="topbar"><button type="button" class="navtoggle-mobile" aria-controls="sidenav" aria-expanded="false" aria-label="Open menu">$menuIcon</button><h1>VDI Golden Image Pipeline</h1></header>
<div class="layout">
$nav
<main>
$BodyHtml
</main>
</div>
<div class="navbackdrop"></div>
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

function Get-GIStepTableHtml {
    <# Nested table of Maintain sub-steps (run.stages.Maintain.steps); '' when there are none. #>
    [CmdletBinding()]
    [OutputType([string])]
    param($Steps)
    $list = @(@($Steps) | Where-Object { $null -ne $_ })
    if (-not $list.Count) { return '' }
    $rows = foreach ($st in $list) {
        $s = [string](Get-GIValue $st 'status' 'Pending')
        $started = Get-GIValue $st 'startedAt' $null
        $ended = Get-GIValue $st 'endedAt' $null
        $dur = if ($started) { ConvertTo-GIHtml (Format-GIDuration $started $ended) } else { '' }
        "<tr><td>$(Get-GIStatusIcon $s)$(ConvertTo-GIHtml (Get-GIValue $st 'label' (Get-GIValue $st 'id')))</td><td>$(Get-GIStatusBadge $s)</td><td>$(Format-GIDate $started)</td><td>$dur</td><td>$(ConvertTo-GIHtml (Get-GIValue $st 'message'))</td></tr>"
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
        $stepHtml = Get-GIStepTableHtml (Get-GIValue $st 'steps' @())
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
    if (-not $ok) { return @{ Code = 403; Message = "You are not in the $($Role.ToLower()) group." } }
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
