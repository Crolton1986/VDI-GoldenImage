[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-* functions only build strings; nothing is changed.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '', Justification = 'Internal view helpers.')]
param()

# Shared UI components. Pure functions that return HTML strings (no Pode, no filesystem).
# Every caller-supplied text is HTML-encoded here; parameters ending in Html are trusted, already-encoded markup.
# Needs ConvertTo-GIHtml from DashboardViews.ps1 (load that file too; it is always loaded before use).
# Style lives in Get-GICss (tokens first). Behavior lives in Get-GIUiScript. See docs/UI-COMPONENTS.md.

function New-GIButton {
    <# Variants: pri, outline (default), sec, danger. -Small is 32 px. A disabled button keeps its label and explains itself via -Reason. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Label,
        [ValidateSet('pri', 'outline', 'sec', 'danger')][string]$Variant = 'outline',
        [string]$Type = 'button',
        [string]$Id = '',
        [string]$Name = '',
        [string]$Value = '',
        [string]$Href = '',                 # renders an <a class="btn"> instead of a <button>
        [string]$OpensDialog = '',          # id of a dialog from New-GIModal
        [switch]$Small,
        [switch]$Disabled,
        [string]$Reason = '',               # why it is disabled; shown as tooltip and read by screen readers
        [string]$AriaLabel = ''
    )
    $cls = 'btn'
    if ($Variant -ne 'outline') { $cls += " $Variant" }
    if ($Small) { $cls += ' small' }
    $attr = ''
    if ($Id) { $attr += " id=""$(ConvertTo-GIHtml $Id)""" }
    if ($AriaLabel) { $attr += " aria-label=""$(ConvertTo-GIHtml $AriaLabel)""" }
    if ($OpensDialog) { $attr += " data-opens=""$(ConvertTo-GIHtml $OpensDialog)"" aria-haspopup=""dialog""" }
    $reasonHtml = ''
    if ($Disabled -and $Reason) {
        $rid = if ($Id) { "$Id-why" } else { 'why-' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
        $attr += " title=""$(ConvertTo-GIHtml $Reason)"" aria-describedby=""$(ConvertTo-GIHtml $rid)"""
        $reasonHtml = "<span class=""sr-only"" id=""$(ConvertTo-GIHtml $rid)"">$(ConvertTo-GIHtml $Reason)</span>"
    }
    $text = ConvertTo-GIHtml $Label
    if ($Href) {
        if ($Disabled) { return "<a class=""$cls"" aria-disabled=""true""$attr>$text</a>$reasonHtml" }
        return "<a class=""$cls"" href=""$(ConvertTo-GIHtml $Href)""$attr>$text</a>"
    }
    if ($Name) { $attr += " name=""$(ConvertTo-GIHtml $Name)"" value=""$(ConvertTo-GIHtml $Value)""" }
    $dis = if ($Disabled) { ' disabled' } else { '' }
    "<button type=""$(ConvertTo-GIHtml $Type)"" class=""$cls""$attr$dis>$text</button>$reasonHtml"
}

function New-GIChip {
    <# Pill with text. The text is required, color alone never carries meaning. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('ok', 'warn', 'run', 'bad', 'idle')][string]$Variant = 'idle'
    )
    "<span class=""chip $Variant"">$(ConvertTo-GIHtml $Text)</span>"
}

function New-GICard {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$BodyHtml,
        [string]$Title = '',
        [string]$Id = '',
        [string]$Class = ''
    )
    $idAttr = if ($Id) { " id=""$(ConvertTo-GIHtml $Id)""" } else { '' }
    $head = if ($Title) { "<h2>$(ConvertTo-GIHtml $Title)</h2>" } else { '' }
    "<section class=""card $(ConvertTo-GIHtml $Class)""$idAttr>$head$BodyHtml</section>"
}

function New-GITabs {
    <# Server-rendered tabs: each tab is a real link. Tabs = @(@{ Label; Href; Key }). #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object[]]$Tabs,
        [Parameter(Mandatory)][string]$Selected,
        [string]$AriaLabel = 'Sections'
    )
    $items = foreach ($t in $Tabs) {
        $sel = if ([string]$t.Key -eq $Selected) { 'true' } else { 'false' }
        "<a role=""tab"" aria-selected=""$sel"" href=""$(ConvertTo-GIHtml $t.Href)""$(if ($sel -eq 'true') { ' aria-current="page"' })>$(ConvertTo-GIHtml $t.Label)</a>"
    }
    "<div class=""tabs"" role=""tablist"" aria-label=""$(ConvertTo-GIHtml $AriaLabel)"">$(@($items) -join '')</div>"
}

function New-GITable {
    <# Columns = header strings. Rows = array of arrays of already-encoded cell HTML. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string[]]$Columns,
        [object[]]$Rows = @(),
        [string]$Caption = '',
        [string]$EmptyText = ''
    )
    $cap = if ($Caption) { "<caption class=""sr-only"">$(ConvertTo-GIHtml $Caption)</caption>" } else { '' }
    $head = ($Columns | ForEach-Object { "<th scope=""col"">$(ConvertTo-GIHtml $_)</th>" }) -join ''
    $body = foreach ($r in $Rows) { '<tr>' + ((@($r) | ForEach-Object { "<td>$_</td>" }) -join '') + '</tr>' }
    if (@($Rows).Count -eq 0 -and $EmptyText) { $body = "<tr><td colspan=""$(@($Columns).Count)"" class=""muted"">$(ConvertTo-GIHtml $EmptyText)</td></tr>" }
    "<div class=""tablewrap""><table>$cap<thead><tr>$head</tr></thead><tbody>$(@($body) -join '')</tbody></table></div>"
}

function New-GIField {
    <# Label above, optional helper text and inline error, both wired through aria-describedby. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Label,
        [string]$Value = '',
        [ValidateSet('text', 'number', 'password', 'time', 'datetime-local', 'select', 'textarea')][string]$Type = 'text',
        [string[]]$Options = @(),          # for select
        [string]$Help = '',
        [string]$Error = '',
        [switch]$Required,
        [switch]$Disabled
    )
    $n = ConvertTo-GIHtml $Name
    $desc = @()
    if ($Help) { $desc += "$n-help" }
    if ($Error) { $desc += "$n-err" }
    $da = if ($desc) { " aria-describedby=""$($desc -join ' ')""" } else { '' }
    $req = if ($Required) { ' required aria-required="true"' } else { '' }
    $dis = if ($Disabled) { ' disabled' } else { '' }
    $inv = if ($Error) { ' aria-invalid="true"' } else { '' }
    $lab = ConvertTo-GIHtml $Label
    if ($Required) { $lab += ' <span aria-hidden="true">*</span><span class="sr-only"> (required)</span>' }
    $ctl = switch ($Type) {
        'select' {
            $opts = foreach ($o in $Options) { "<option value=""$(ConvertTo-GIHtml $o)""$(if ($o -eq $Value) { ' selected' })>$(ConvertTo-GIHtml $o)</option>" }
            "<select id=""$n"" name=""$n""$da$req$dis$inv>$(@($opts) -join '')</select>"
        }
        'textarea' { "<textarea id=""$n"" name=""$n""$da$req$dis$inv>$(ConvertTo-GIHtml $Value)</textarea>" }
        default { "<input type=""$Type"" id=""$n"" name=""$n"" value=""$(ConvertTo-GIHtml $Value)""$da$req$dis$inv>" }
    }
    $h = if ($Help) { "<div class=""help"" id=""$n-help"">$(ConvertTo-GIHtml $Help)</div>" } else { '' }
    $e = if ($Error) { "<div class=""error"" id=""$n-err"">$(ConvertTo-GIHtml $Error)</div>" } else { '' }
    "<div class=""field""><label for=""$n"">$lab</label>$ctl$h$e</div>"
}

function New-GISaveBar {
    <# Sticky bar for a settings column. The UI script updates it when a form with data-savebar changes. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$FormId = 'settings-form')
    $f = ConvertTo-GIHtml $FormId
    @"
<div class="savebar" data-savebar-for="$f"><div role="status" aria-live="polite"><span class="savebar-clean">No unsaved changes</span><span class="savebar-dirty" hidden><span class="chip warn"><span class="savebar-count">0</span> unsaved</span> <span class="savebar-summary muted"></span></span></div>
<div class="actions"><button type="button" class="btn sec" data-savebar-discard disabled>Discard</button><button type="submit" form="$f" class="btn pri" data-savebar-save disabled>Save changes</button></div></div>
"@
}

function New-GISubNav {
    <# Vertical section list for settings. Items = @(@{ Label; Href; Key }). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object[]]$Items, [Parameter(Mandatory)][string]$Selected, [string]$AriaLabel = 'Settings sections')
    $links = foreach ($i in $Items) {
        $cur = if ([string]$i.Key -eq $Selected) { ' aria-current="page"' } else { '' }
        "<a href=""$(ConvertTo-GIHtml $i.Href)""$cur>$(ConvertTo-GIHtml $i.Label)</a>"
    }
    "<nav class=""card subnav"" aria-label=""$(ConvertTo-GIHtml $AriaLabel)"">$(@($links) -join '')</nav>"
}

function New-GIStepper {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string[]]$Steps, [Parameter(Mandatory)][int]$Current)   # Current is 1-based
    $i = 0
    $li = foreach ($s in $Steps) {
        $i++
        $state = if ($i -lt $Current) { 'done' } elseif ($i -eq $Current) { 'current' } else { 'todo' }
        $cur = if ($state -eq 'current') { ' aria-current="step"' } else { '' }
        $mark = if ($state -eq 'done') { '&#10004;' } else { "$i" }
        $word = switch ($state) { 'done' { ' (done)' } 'current' { ' (current step)' } default { '' } }
        "<li class=""$state""$cur><span class=""num"" aria-hidden=""true"">$mark</span><span>$(ConvertTo-GIHtml $s)<span class=""sr-only"">$word</span></span></li>"
    }
    "<ol class=""stepper"" aria-label=""Steps"">$(@($li) -join '')</ol>"
}

function New-GIModal {
    <# Hidden until a button with data-opens="<Id>" is used. Focus goes to the first field, or to Cancel when there is none. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$BodyHtml,
        [Parameter(Mandatory)][string]$ConfirmLabel,
        [ValidateSet('pri', 'danger')][string]$ConfirmVariant = 'pri',
        [string]$FormAction = '',          # when set the dialog is a POST form
        [string]$FormHtml = ''             # extra hidden inputs (token etc.), already encoded
    )
    $i = ConvertTo-GIHtml $Id
    $confirm = "<button type=""submit"" class=""btn $ConfirmVariant"">$(ConvertTo-GIHtml $ConfirmLabel)</button>"
    $inner = "<h2 id=""$i-title"">$(ConvertTo-GIHtml $Title)</h2>$BodyHtml<div class=""actions""><button type=""button"" class=""btn sec"" data-close>Cancel</button>$confirm</div>"
    if ($FormAction) { $inner = "<form method=""post"" action=""$(ConvertTo-GIHtml $FormAction)"">$FormHtml$inner</form>" }
    "<div class=""modal-backdrop"" id=""$i"" hidden><div class=""modal"" role=""dialog"" aria-modal=""true"" aria-labelledby=""$i-title"">$inner</div></div>"
}

function New-GIBanner {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('warn', 'error')][string]$Variant = 'warn',
        [string]$LinkText = '',
        [string]$LinkHref = '',
        [string]$Id = '',
        [switch]$Hidden
    )
    $role = if ($Variant -eq 'error') { 'alert' } else { 'status' }
    $cls = if ($Variant -eq 'error') { 'banner error' } else { 'banner' }
    $idA = if ($Id) { " id=""$(ConvertTo-GIHtml $Id)""" } else { '' }
    $hid = if ($Hidden) { ' hidden' } else { '' }
    $link = if ($LinkText -and $LinkHref) { "<a href=""$(ConvertTo-GIHtml $LinkHref)"">$(ConvertTo-GIHtml $LinkText)</a>" } else { '' }
    "<div class=""$cls"" role=""$role""$idA$hid><span class=""banner-text"">$(ConvertTo-GIHtml $Text)</span>$link</div>"
}

function New-GISkeleton {
    <# Placeholder for a live value. -Label says what is loading, for screen readers. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Label = 'Loading', [int]$Width = 80)
    "<span class=""skeleton"" style=""width:${Width}px"" role=""img"" aria-label=""$(ConvertTo-GIHtml $Label)""></span>"
}

function New-GIStatusRegion {
    <# Inline status text near an action. Errors stay until the next action, they never auto-dismiss. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Id)
    "<div id=""$(ConvertTo-GIHtml $Id)"" role=""status"" aria-live=""polite"" class=""muted""></div>"
}

function Get-GIRoleName {
    <# Viewer, Approver or Admin from the per-request nav context. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([hashtable]$Context)
    if ($Context -and $Context['IsAdmin']) { return 'Admin' }
    if ($Context -and $Context['IsApprover']) { return 'Approver' }
    'Viewer'
}

function Get-GIUiScript {
    <# Small vanilla JS: modal dialogs, unsaved-changes guard and save bar, visibility-aware polling, 401 banner. #>
    @'
(function(){
var d=document;
function live(msg){var r=d.getElementById('gi-live');if(r){r.textContent='';setTimeout(function(){r.textContent=msg},30)}}
window.GI={live:live};

/* Dialogs: focus in, Escape or Cancel closes, focus returns to the opener. */
var opener=null;
function focusables(m){return m.querySelectorAll('input:not([type=hidden]):not(:disabled),select:not(:disabled),textarea:not(:disabled),button:not(:disabled),a[href]')}
function openDlg(id,from){var b=d.getElementById(id);if(!b){return}opener=from||d.activeElement;b.hidden=false;
var m=b.querySelector('.modal'),f=m.querySelector('input:not([type=hidden]):not(:disabled),select:not(:disabled),textarea:not(:disabled)')||m.querySelector('[data-close]');if(f){f.focus()}}
function closeDlg(b){b.hidden=true;if(opener&&opener.focus){opener.focus()}opener=null}
d.addEventListener('click',function(e){var t=e.target;if(!t||!t.closest){return}
var o=t.closest('[data-opens]');if(o){e.preventDefault();openDlg(o.getAttribute('data-opens'),o);return}
var c=t.closest('[data-close]');if(c){var b=c.closest('.modal-backdrop');if(b){closeDlg(b)}return}
if(t.classList&&t.classList.contains('modal-backdrop')){closeDlg(t)}});
d.addEventListener('keydown',function(e){var b=d.querySelector('.modal-backdrop:not([hidden])');if(!b){return}
if(e.key==='Escape'){e.preventDefault();closeDlg(b);return}
if(e.key==='Tab'){var f=focusables(b.querySelector('.modal'));if(!f.length){return}var a=f[0],z=f[f.length-1];
if(e.shiftKey&&d.activeElement===a){e.preventDefault();z.focus()}else if(!e.shiftKey&&d.activeElement===z){e.preventDefault();a.focus()}}});

/* Save bar and unsaved-changes warning for forms marked data-savebar. */
var dirtyForms=[];
function snap(f){var o={};new FormData(f).forEach(function(v,k){if(k!=='token'){o[k]=(o[k]===undefined?'':o[k]+',')+v}});return o}
d.querySelectorAll('form[data-savebar]').forEach(function(f){
var base=snap(f),bar=d.querySelector('[data-savebar-for="'+f.id+'"]');if(!bar){return}
var save=bar.querySelector('[data-savebar-save]'),disc=bar.querySelector('[data-savebar-discard]');
function upd(){var now=snap(f),ch=[];Object.keys(now).concat(Object.keys(base)).forEach(function(k){if(now[k]!==base[k]&&ch.indexOf(k)<0){ch.push(k)}});
bar.querySelector('.savebar-clean').hidden=ch.length>0;bar.querySelector('.savebar-dirty').hidden=ch.length===0;
bar.querySelector('.savebar-count').textContent=ch.length;bar.querySelector('.savebar-summary').textContent=ch.slice(0,3).join(', ')+(ch.length>3?' and more':'');
save.disabled=ch.length===0;disc.disabled=ch.length===0;
var i=dirtyForms.indexOf(f);if(ch.length&&i<0){dirtyForms.push(f)}if(!ch.length&&i>=0){dirtyForms.splice(i,1)}}
f.addEventListener('input',upd);f.addEventListener('change',upd);
disc.addEventListener('click',function(){f.reset();upd()});
f.addEventListener('submit',function(){dirtyForms=dirtyForms.filter(function(x){return x!==f})});
});
window.addEventListener('beforeunload',function(e){if(dirtyForms.length){e.preventDefault();e.returnValue=''}});

/* Polling: GI.poll(fn, seconds). Runs only while the tab is visible, refreshes once when it returns. */
window.GI.poll=function(fn,sec){var t=null;function go(){fn();t=setTimeout(go,sec*1000)}
function start(){if(t===null){go()}}function stop(){if(t!==null){clearTimeout(t);t=null}}
d.addEventListener('visibilitychange',function(){if(d.hidden){stop()}else{start()}});if(!d.hidden){start()}};

/* Fetch JSON with a 15 s timeout and a 401 banner. Resolves {ok,status,data,error}. */
window.GI.getJson=function(url){var c=new AbortController(),t=setTimeout(function(){c.abort()},15000);
return fetch(url,{credentials:'same-origin',signal:c.signal,headers:{Accept:'application/json'}}).then(function(r){clearTimeout(t);
if(r.status===401){var b=d.getElementById('gi-expired');if(b){b.hidden=false}return {ok:false,status:401,error:'Your session expired.'}}
return r.json().then(function(j){return {ok:r.ok,status:r.status,data:j,error:r.ok?null:(j&&j.error)||('HTTP '+r.status)}},function(){return {ok:false,status:r.status,error:'HTTP '+r.status}})
},function(e){clearTimeout(t);return {ok:false,status:0,error:(e&&e.name==='AbortError')?'The server did not answer within 15 seconds.':'The server could not be reached.'}})};
})();
'@
}
