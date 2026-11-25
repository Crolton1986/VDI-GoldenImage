[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Helpers return heterogeneous values by design.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '', Justification = 'Internal view helpers.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-* functions only build strings; nothing is changed.')]
param()

# Settings pages (per image and global), the add-image wizard and the audit log page.
# Needs DashboardViews.ps1, Components.ps1, SettingsViews.ps1 and ImageViews.ps1 loaded first.

function Get-GIImageSettingsSections {
    @(
        @{ Key = 'General'; Label = 'General' }
        @{ Key = 'GoldenImage'; Label = 'Guest VM' }
        @{ Key = 'Pools'; Label = 'Pools' }
        @{ Key = 'WindowsUpdate'; Label = 'Windows Update' }
        @{ Key = 'Packages'; Label = 'Packages' }
        @{ Key = 'AppVolumes'; Label = 'App Volumes tests' }
        @{ Key = 'Validation'; Label = 'Validation' }
        @{ Key = 'Snapshots'; Label = 'Snapshots' }
        @{ Key = 'Promotion'; Label = 'Schedule and promotion' }
    )
}

function Get-GISettingsSubNavItems {
    param([string]$Base, [object[]]$Sections)
    @(foreach ($s in $Sections) { @{ Label = $s.Label; Href = "$Base/$($s.Key)"; Key = $s.Key } })
}

function New-GIImageGeneralBody {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Summary, [Parameter(Mandatory)]$Ctx, [string]$Token = '', $Errors = @{}, [int]$RunCount = 0, [string]$Notice = '')
    $id = ConvertTo-GIHtml $Summary.id
    $dis = -not $Ctx.IsAdmin
    $nameErr = if ($Errors.Contains('Name')) { [string]$Errors['Name'] } else { '' }
    $form = "<form method=""post"" action=""/images/$id/settings/General"" id=""settings-form""$(if (-not $dis) { ' data-savebar' })>$(Get-GITokenInput $Token)" +
    (New-GIField -Name 'Name' -Label 'Name' -Value $Summary.name -Required -Disabled:$dis -Error $nameErr -Help 'Letters, numbers and dashes. Shown on the card and in the audit log. Renaming keeps run history.') +
    (New-GIField -Name 'Description' -Label 'Description' -Value $Summary.description -Disabled:$dis) +
    (New-GIField -Name 'Os' -Label 'OS label' -Value $Summary.os -Disabled:$dis -Help 'For example Windows 11. Shown under the name.') + '</form>'
    $bar = if ($dis) { '' } else { New-GISaveBar -FormId 'settings-form' }
    $n = if ($Notice) { "<div class=""notice"" role=""status"">$(ConvertTo-GIHtml $Notice)</div>" } else { '' }
    $general = New-GICard -Title 'General' -BodyHtml "<p class=""muted"">Name and description. These settings apply to $(ConvertTo-GIHtml $Summary.name) only and take effect from the next run.</p>$n$form$bar"
    $general = $general.Replace('<section class="card ">', '<section class="card settings-main">')
    if ($dis) { return $general }
    $pauseLabel = if ($Summary.paused) { 'Resume image' } else { 'Pause image' }
    $pauseApi = if ($Summary.paused) { 'resume' } else { 'pause' }
    $pause = New-GICard -Title 'Pause this image' -BodyHtml "<p class=""muted"">Paused images keep history and settings, are skipped by scheduled runs and cannot start runs, and show a Paused chip everywhere.</p><form data-api=""POST /api/images/$id/$pauseApi"" data-then=""reload""><button type=""submit"" class=""btn"">$pauseLabel</button><p class=""error"" data-error role=""alert""></p></form>"
    $busy = [bool]$Summary.activeRun
    $rm = New-GIButton -Label "Remove $($Summary.name)" -Variant dangerline -OpensDialog 'dlg-remove' -Disabled:$busy -Reason 'Unavailable while a run is in progress.'
    $remove = New-GICard -Class 'dangerzone' -Title 'Remove from dashboard' -BodyHtml "<p>Removes this image from the dashboard and stops managing it. The guest VM, pools and snapshots in vCenter and Horizon are not touched. Run history and logs are kept on the pipeline host.</p>$rm"
    $dlgBody = "<p>The pipeline stops managing this image. Nothing is changed in vCenter or Horizon: the guest VM $(ConvertTo-GIHtml $Summary.vm), its pools and its snapshots stay as they are.</p><ul><li>Run history and logs for $RunCount run$(if ($RunCount -ne 1) { 's' }) are kept on the pipeline host.</li><li>Scheduled runs stop.</li><li>The removal is recorded in the audit log.</li></ul><div class=""field""><label for=""rm-confirm"">Type <strong>$(ConvertTo-GIHtml $Summary.name)</strong> to confirm</label><input type=""text"" id=""rm-confirm"" autocomplete=""off"" data-must-match=""$(ConvertTo-GIHtml $Summary.name)""></div>"
    $dlg = New-GIModal -Id 'dlg-remove' -Title "Remove $($Summary.name) from the dashboard?" -BodyHtml $dlgBody -ConfirmLabel 'Remove image' -ConfirmVariant danger -Api "DELETE /api/images/$id" -Then '/'
    "$general$pause$remove$dlg"
}

function New-GIImageAppVolumesBody {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Summary, [Parameter(Mandatory)]$Ctx, [string]$Token = '', [string[]]$Packages = @(), [string]$Notice = '')
    $id = ConvertTo-GIHtml $Summary.id
    $dis = -not $Ctx.IsAdmin
    $form = "<form method=""post"" action=""/images/$id/settings/AppVolumes"" id=""settings-form""$(if (-not $dis) { ' data-savebar' })>$(Get-GITokenInput $Token)" +
    (New-GIField -Name 'TestPackages' -Label 'App Volumes packages to test' -Type textarea -Value ($Packages -join "`n") -Disabled:$dis -Help "One App Volumes package name per line, matching the name in App Volumes. Validate checks these packages, which are assigned to the test pool's computer OU.") + '</form>'
    $n = if ($Notice) { "<div class=""notice"" role=""status"">$(ConvertTo-GIHtml $Notice)</div>" } else { '' }
    $bar = if ($dis) { '' } else { New-GISaveBar -FormId 'settings-form' }
    New-GICard -Class 'settings-main' -Title 'App Volumes tests' -BodyHtml "<p class=""muted"">Packages the Validate stage checks on the test pool. These settings apply to $(ConvertTo-GIHtml $Summary.name) only and take effect from the next run.</p>$n$form$bar"
}

function New-GIImageSettingsPage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Summary, [Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$BodyHtml
    )
    $id = ConvertTo-GIHtml $Summary.id
    $sections = Get-GIImageSettingsSections
    $head = New-GIImageHeader -Summary $Summary -Ctx $Ctx -Tab settings
    $ro = if ($Ctx.IsAdmin) { '' } else { '<p class="muted">Only Admins can change settings.</p>' }
    $nav = New-GISubNav -Items (Get-GISettingsSubNavItems -Base "/images/$id/settings" -Sections $sections) -Selected $Section
    $label = (@($sections | Where-Object { $_.Key -eq $Section }) | Select-Object -First 1).Label
    New-GIPage -Title "$($Summary.name) - $label settings" -BodyHtml "$head$ro<div class=""settings-layout"">$nav<div>$BodyHtml</div></div>"
}

#----- Global settings -----

function Get-GIGlobalSettingsSections {
    @(
        @{ Key = 'vCenter'; Label = 'vCenter' }
        @{ Key = 'Horizon'; Label = 'Horizon' }
        @{ Key = 'AppVolumes'; Label = 'App Volumes' }
        @{ Key = 'Email'; Label = 'Email' }
        @{ Key = 'Dashboard'; Label = 'Dashboard and sign-in' }
        @{ Key = 'Fixes'; Label = 'Fixes' }
    )
}

function New-GITestConnectionCard {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Section)
    New-GICard -Title 'Test connection' -BodyHtml "<p class=""muted"">Tests the values currently in the form, including unsaved ones. Nothing is saved.</p><button type=""button"" class=""btn"" data-test-section=""$(ConvertTo-GIHtml $Section)"">Test connection</button><div id=""test-result"" role=""status"" aria-live=""polite""></div>"
}

function New-GIDashboardSettingsBody {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Dashboard)
    $v = { param($k) ConvertTo-GIHtml $(if ($Dashboard.ContainsKey($k)) { $Dashboard[$k] } else { '' }) }
    $ro = '<span class="chip idle">Read only</span>'
    $roles = "<div class=""tablewrap""><table><thead><tr><th scope=""col"">Role</th><th scope=""col"">AD group</th><th scope=""col"">Can</th></tr></thead><tbody>" +
    "<tr><th scope=""row"">Viewer</th><td class=""mono"">$(& $v 'ViewerGroup')</td><td>See everything, change nothing</td></tr>" +
    "<tr><th scope=""row"">Approver</th><td class=""mono"">$(& $v 'ApproverGroup')</td><td>Approve and reject runs</td></tr>" +
    "<tr><th scope=""row"">Admin</th><td class=""mono"">$(& $v 'AdminGroup')</td><td>Start runs, power, revert, roll back, edit settings</td></tr></tbody></table></div><p class=""muted"">A person in more than one group gets the highest role.</p>"
    New-GICard -Class 'settings-main' -Title 'Dashboard and sign-in' -BodyHtml "<p class=""muted"">Read only here. Changing the listener or the access groups from the dashboard could lock everyone out. Edit <code>pipeline.config.psd1</code> and restart the dashboard.</p>$ro<dl class=""kv""><dt>Port</dt><dd>$(& $v 'Port')</dd><dt>Certificate thumbprint</dt><dd class=""mono"">$(& $v 'CertificateThumbprint')</dd><dt>Auto refresh</dt><dd>$(& $v 'RefreshSeconds') seconds</dd></dl>$roles"
}

function New-GIFixesBody {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object[]]$Fixes = @())
    $rows = foreach ($f in @($Fixes)) {
        $m = $f.match
        $codes = @(Get-GIWatcherProp $m 'ExitCodes' @()) -join ', '
        $pat = @(Get-GIWatcherProp $m 'Patterns' @()) -join '; '
        $matchLine = "Matches: $(if ($codes) { 'exit code ' + $codes } else { 'any failure' })$(if ($pat) { ', ' + $pat })"
        $actions = if (@($f.actions) -contains '*') { 'All steps' } else { (@($f.actions) -join ', ') }
        $reboot = if ($f.rebootFromAttempt -gt 0) { ", reboots from use $($f.rebootFromAttempt)" } else { '' }
        $last = if ($f.lastUsedRunId) { $r = ConvertTo-GIHtml $f.lastUsedRunId; "<span class=""mono"">$r</span>" } else { 'Never' }
        $bad = if (-not $f.valid) { " $(New-GIChip -Text 'Invalid file' -Variant bad)" } else { '' }
        "<tr><th scope=""row""><strong>$(ConvertTo-GIHtml $f.id)</strong>$bad<div>$(ConvertTo-GIHtml $f.description)</div><div class=""muted small"">$(ConvertTo-GIHtml $matchLine)</div></th><td>$(ConvertTo-GIHtml $actions)</td><td>$($f.priority)</td><td>$($f.maxAttempts)$(ConvertTo-GIHtml $reboot)</td><td>$last</td></tr>"
    }
    $table = "<div class=""tablewrap""><table><thead><tr><th scope=""col"">Fix</th><th scope=""col"">Applies to</th><th scope=""col"">Priority</th><th scope=""col"">Max uses</th><th scope=""col"">Last used</th></tr></thead><tbody>$(@($rows) -join '')$(if (-not $rows) { '<tr><td colspan="5" class="muted">No fix scripts found in Pipeline/guest/fixes.</td></tr>' })</tbody></table></div>"
    New-GICard -Class 'settings-main' -Title 'Fixes' -BodyHtml "<p class=""muted"">Known install failures the guest watcher repairs by itself, then retries the step. Fixes are files in the pipeline repository (<code>Pipeline/guest/fixes</code>), so they're added and changed through git, not here.</p>$table<p class=""muted small"">The step on the run page shows ""Fixed by &lt;fix&gt;"" when one was used. To add a fix, see ""Adding a fix script"" in the repository README.</p>"
}

function New-GIGlobalSettingsPage {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Section, [Parameter(Mandatory)][string]$BodyHtml)
    $nav = New-GISubNav -Items (Get-GISettingsSubNavItems -Base '/settings' -Sections (Get-GIGlobalSettingsSections)) -Selected $Section -AriaLabel 'Global settings sections'
    $ro = if ($Ctx.IsAdmin) { '' } else { '<p class="muted">Only Admins can change settings.</p>' }
    $head = "<div><h1>Global settings</h1><p class=""muted"">Connections and options shared by every golden image. Settings that differ per image are on each image's Settings tab.</p>$ro</div>"
    New-GIPage -Title 'Global settings' -BodyHtml "$head<div class=""settings-layout"">$nav<div>$BodyHtml</div></div>"
}

#----- Add golden image wizard -----

function New-GIWizardPage {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)]$Installers, [string[]]$Days = @('Saturday'))
    $steps = @('Basics', 'Guest VM and pools', 'Windows Update and packages', 'Schedule and promotion', 'Review')
    $rows = foreach ($p in @($Installers.Packages)) {
        "<tr><td><input type=""checkbox"" id=""pk-$(ConvertTo-GIHtml $p.Action)"" name=""pkg"" value=""$(ConvertTo-GIHtml $p.Action)""></td><td><label for=""pk-$(ConvertTo-GIHtml $p.Action)"">$(ConvertTo-GIHtml $p.Name)</label><div class=""muted small mono"">$(ConvertTo-GIHtml $p.Action) · $(ConvertTo-GIHtml $p.Mask)</div></td></tr>"
    }
    $dayBoxes = foreach ($d in 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday') { "<label><input type=""checkbox"" name=""day"" value=""$d""$(if ($Days -contains $d) { ' checked' })> $d</label> " }
    $s1 = (New-GIField -Name 'Name' -Label 'Name' -Required -Help 'Letters, numbers and dashes. Shown on the card and in the audit log.') + (New-GIField -Name 'Description' -Label 'Description') + '<p id="name-status" class="muted" role="status"></p>'
    $s2 = @"
<div id="inv-status" role="status" class="muted">Loading from vCenter and Horizon...</div>
<div class="field"><label for="VmSelect">Guest VM <span aria-hidden="true">*</span><span class="sr-only"> (required)</span></label><select id="VmSelect" name="VmName" aria-describedby="vm-info"></select><input type="text" id="VmText" name="VmNameText" hidden aria-label="Guest VM name (typed)"><div class="help" id="vm-info"></div></div>
<div class="field"><label for="TestSelect">Test pool <span aria-hidden="true">*</span><span class="sr-only"> (required)</span></label><select id="TestSelect" name="TestPool"></select><input type="text" id="TestText" name="TestPoolText" hidden aria-label="Test pool name (typed)"><div class="help">Every new snapshot goes here first.</div></div>
<div class="field"><div class="lbl">Production pools</div><div class="tablewrap"><table><thead><tr><th scope="col">Include</th><th scope="col">Pool</th><th scope="col">Used by</th><th scope="col">Logoff policy</th></tr></thead><tbody id="ProdRows"></tbody></table></div><div id="ProdText" hidden><label for="ProdTextArea">Production pool names, one per line</label><textarea id="ProdTextArea"></textarea></div></div>
<p id="pool-status" class="muted" role="status"></p><button type="button" class="btn small" id="inv-retry" hidden>Try again</button>
"@
    $s3 = (New-GIField -Name 'WuMax' -Label 'Windows Update maximum passes' -Type number -Value '5' -Help 'Each pass installs updates, then reboots if needed.') + '<div class="field"><label><input type="checkbox" id="WuOn" checked> Run Windows Update</label></div>' +
    (New-GIField -Name 'InstallerDir' -Label 'Installer folder on pipeline host' -Help 'Optional. Files here are copied into the Install folder in the guest before packages run. Leave empty if you stage installers in the guest yourself.') + (New-GIField -Name 'Timeout' -Label 'Package timeout (min)' -Type number -Value '60') +
    "<div class=""tablewrap""><table><thead><tr><th scope=""col"">Maintain</th><th scope=""col"">Package</th></tr></thead><tbody>$(@($rows) -join '')</tbody></table></div><p class=""muted small"">The package list is built into the pipeline. Supporting a new package needs a script added by an administrator of the pipeline, so it can't be added here.</p>" +
    (New-GIField -Name 'TestPackages' -Label 'App Volumes packages to test' -Type textarea -Help 'One package name per line. Validate checks these on the test pool.') + '<p class="muted">You can change these later under Settings.</p>'
    $s4 = "<fieldset class=""field""><legend class=""lbl"">Who approves new images?</legend><label><input type=""radio"" name=""Promote"" value=""approver"" checked> Wait for an Approver (recommended)</label><br><label><input type=""radio"" name=""Promote"" value=""auto""> Promote automatically</label></fieldset><div class=""field""><div class=""lbl"">Maintenance window days</div><div class=""days"">$(@($dayBoxes) -join '')</div></div>" + (New-GIField -Name 'StartTime' -Label 'Start time (24 hour, server time)' -Type time -Value '22:00')
    $s5 = '<div id="review"></div><div class="field" id="auto-confirm" hidden><label><input type="checkbox" id="AutoOk"> I understand new images will reach production without approval.</label></div><p id="review-status" role="status"></p>'
    $bodies = @($s1, $s2, $s3, $s4, $s5)
    $sets = for ($i = 0; $i -lt 5; $i++) { "<fieldset class=""wizstep card"" data-step=""$($i + 1)""$(if ($i -gt 0) { ' hidden' })><legend><h2 tabindex=""-1"">$($steps[$i])</h2></legend>$($bodies[$i])</fieldset>" }
    $foot = "<div class=""wizfoot""><button type=""button"" class=""btn sec"" id=""wiz-back"">Cancel and go back</button><div><span class=""muted"" id=""wiz-count"">Step 1 of 5</span> <button type=""button"" class=""btn pri"" id=""wiz-next"">Next: Guest VM and pools</button></div></div>"
    $stepper = "<div id=""wiz-stepper"">$(New-GIStepper -Steps $steps -Current 1)</div>"
    $labels = ConvertTo-Json -InputObject @($steps) -Compress
    $body = "<h1>Add golden image</h1>$stepper<form id=""wizard"" novalidate>$(@($sets) -join '')$foot</form><div id=""wiz-error"" class=""alert"" role=""alert"" hidden></div><script>$(Get-GIWizardScript -Labels $labels)</script>"
    New-GIPage -Title 'Add golden image' -BodyHtml $body
}

function Get-GIWizardScript {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Labels)
    @"
document.addEventListener('DOMContentLoaded',function(){
var L=$Labels,cur=1,inv=null,stepper=document.getElementById('wiz-stepper'),form=document.getElementById('wizard'),dirty=false;
function q(id){return document.getElementById(id)}
function steps(){return [].slice.call(form.querySelectorAll('fieldset.wizstep'))}
function val(n){return (form.elements[n]||{}).value||''}
function render(){steps().forEach(function(s,i){s.hidden=(i+1)!==cur});
var html='';L.forEach(function(t,i){var st=(i+1)<cur?'done':((i+1)===cur?'current':'todo');html+='<li class="'+st+'"'+(st==='current'?' aria-current="step"':'')+'><span class="num" aria-hidden="true">'+(st==='done'?'✔':(i+1))+'</span><span></span></li>'});
stepper.innerHTML='<ol class="stepper" aria-label="Steps">'+html+'</ol>';stepper.querySelectorAll('li span:last-child').forEach(function(s,i){s.textContent=L[i]});
stepper.querySelectorAll('li.done').forEach(function(li,i){li.style.cursor='pointer';li.addEventListener('click',function(){cur=i+1;render()})});
q('wiz-count').textContent='Step '+cur+' of 5';q('wiz-back').textContent=cur===1?'Cancel and go back':'Back';
var nx=q('wiz-next');nx.textContent=cur===5?'Create golden image':'Next: '+L[cur];
var h=form.querySelector('fieldset[data-step="'+cur+'"] h2');if(h){h.focus()};if(cur===5){review()}}
function days(){return [].slice.call(form.querySelectorAll('input[name=day]:checked')).map(function(c){return c.value})}
function pkgs(){return [].slice.call(form.querySelectorAll('input[name=pkg]:checked')).map(function(c){return c.value})}
function prods(){var r=[];form.querySelectorAll('#ProdRows tr').forEach(function(tr){var c=tr.querySelector('input[type=checkbox]');if(c&&c.checked&&!c.disabled){r.push({Name:c.value,LogoffPolicy:tr.querySelector('select').value})}});
var ta=q('ProdText');if(!ta.hidden){q('ProdTextArea').value.split(/\r?\n/).forEach(function(n){n=n.trim();if(n){r.push({Name:n,LogoffPolicy:'WAIT_FOR_LOGOFF'})}})}return r}
function vm(){var s=q('VmSelect');return s.hidden?q('VmText').value.trim():s.value}
function test(){var s=q('TestSelect');return s.hidden?q('TestText').value.trim():s.value}
function payload(){var gi={VmName:vm(),Actions:pkgs(),ActionTimeoutMin:+val('Timeout')||60,WindowsUpdate:{Enabled:q('WuOn').checked,MaxPasses:+val('WuMax')||5}};
if(val('InstallerDir').trim()){gi.InstallerSourceDir=val('InstallerDir').trim()}
return {Name:val('Name').trim(),Description:val('Description').trim(),GoldenImage:gi,
Pools:{Test:{Name:test(),LogoffPolicy:'FORCE_LOGOFF'},Production:prods()},
Promotion:{AutoPromote:form.elements.Promote.value==='auto',MaintenanceWindow:{Days:days(),StartTime:val('StartTime')||'22:00'}},
AppVolumes:{TestPackages:val('TestPackages').split(/\r?\n/).map(function(x){return x.trim()}).filter(Boolean)}}}
function problem(step){var p=payload();
if(step===1){if(!p.Name){return 'Enter a name.'}if(!/^[A-Za-z0-9][A-Za-z0-9 _-]*$/.test(p.Name)){return 'Use letters, numbers and dashes in the name.'}}
if(step===2){if(!p.GoldenImage.VmName){return 'Pick the guest VM.'}if(!p.Pools.Test.Name){return 'Pick the test pool.'}if(!p.Pools.Production.length){return 'Include at least one production pool.'}
if(p.Pools.Production.some(function(x){return x.Name===p.Pools.Test.Name})){return 'The test pool must differ from the production pools.'}}
if(step===4){if(!p.Promotion.MaintenanceWindow.Days.length){return 'Select at least one day for the maintenance window.'}}return ''}
function showErr(m){var e=q('wiz-error');e.hidden=!m;e.textContent=m||'';if(m){e.focus&&e.setAttribute('tabindex','-1');e.focus()}}
function review(){var p=payload(),r=q('review');r.textContent='';
function card(t,step,lines){var d=document.createElement('section');d.className='card';var h=document.createElement('h3');h.textContent=t;d.appendChild(h);lines.forEach(function(l){var x=document.createElement('p');x.textContent=l;d.appendChild(x)});
var a=document.createElement('a');a.href='#';a.textContent='Edit '+t;a.addEventListener('click',function(e){e.preventDefault();cur=step;render()});d.appendChild(a);r.appendChild(d)}
card('Basics',1,[p.Name,p.Description||'No description']);
card('Guest VM and pools',2,['Guest VM: '+p.GoldenImage.VmName,'Test pool: '+p.Pools.Test.Name,'Production pools: '+p.Pools.Production.map(function(x){return x.Name+' ('+(x.LogoffPolicy==='FORCE_LOGOFF'?'force logoff':'wait for logoff')+')'}).join(', ')]);
card('Windows Update and packages',3,['Windows Update: '+(p.GoldenImage.WindowsUpdate.Enabled?'on, up to '+p.GoldenImage.WindowsUpdate.MaxPasses+' passes':'off'),'Packages: '+(p.GoldenImage.Actions.join(', ')||'none'),'App Volumes tests: '+(p.AppVolumes.TestPackages.join(', ')||'none')]);
card('Schedule and promotion',4,[p.Promotion.AutoPromote?'Promote automatically':'Wait for an Approver','Window: '+p.Promotion.MaintenanceWindow.Days.join(', ')+' '+p.Promotion.MaintenanceWindow.StartTime]);
q('auto-confirm').hidden=!p.Promotion.AutoPromote;
var st=q('review-status');st.textContent='Checking...';
window.GI.send('POST','/api/images?dryRun=1',p).then(function(x){if(x.ok){st.className='';st.textContent='Ready: All checks passed. Nothing runs until you start the first run from the image page. Set the guest administrator password under Settings, Guest VM.'}else{st.className='error';st.textContent=x.error}})}
function fillInv(){var vs=q('VmSelect'),ts=q('TestSelect'),st=q('inv-status');
vs.textContent='';ts.textContent='';q('ProdRows').textContent='';
if(inv.errors&&inv.errors.length){st.textContent=inv.errors.join(' ');st.className='error';q('inv-retry').hidden=false;
if(!inv.vms.length){vs.hidden=true;q('VmText').hidden=false;q('vm-info').textContent='Typed names are unverified.'}
if(!inv.pools.length){ts.hidden=true;q('TestText').hidden=false;q('ProdText').hidden=false;q('pool-status').textContent='Typed names are unverified.'}}
else{st.className='muted';st.textContent='Loaded from vCenter and Horizon just now ('+inv.vms.length+' VMs, '+inv.pools.length+' pools)';q('inv-retry').hidden=true;vs.hidden=false;q('VmText').hidden=true;ts.hidden=false;q('TestText').hidden=true;q('ProdText').hidden=true;q('pool-status').textContent=''}
var o=document.createElement('option');o.value='';o.textContent='Choose a VM';vs.appendChild(o);
inv.vms.forEach(function(v){var op=document.createElement('option');op.value=v.name;op.textContent=v.name+(v.usedBy?' (used by '+v.usedBy+')':'');if(v.usedBy){op.disabled=true}vs.appendChild(op)});
var o2=document.createElement('option');o2.value='';o2.textContent='Choose a pool';ts.appendChild(o2);
inv.pools.forEach(function(p){var op=document.createElement('option');op.value=p.name;op.textContent=p.name+(p.usedBy?' (used by '+p.usedBy+')':'');if(p.usedBy){op.disabled=true}ts.appendChild(op);
var tr=document.createElement('tr');var c1=document.createElement('td'),cb=document.createElement('input');cb.type='checkbox';cb.value=p.name;cb.id='pp-'+p.name;cb.setAttribute('aria-label','Include '+p.name);if(p.usedBy){cb.disabled=true}c1.appendChild(cb);tr.appendChild(c1);
var c2=document.createElement('td');c2.textContent=p.name;tr.appendChild(c2);var c3=document.createElement('td');if(p.usedBy){var ch=document.createElement('span');ch.className='chip idle';ch.textContent=p.usedBy;c3.appendChild(ch)}tr.appendChild(c3);
var c4=document.createElement('td'),sel=document.createElement('select');sel.setAttribute('aria-label','Logoff policy for '+p.name);[['WAIT_FOR_LOGOFF','Wait for logoff'],['FORCE_LOGOFF','Force logoff']].forEach(function(x){var op=document.createElement('option');op.value=x[0];op.textContent=x[1];sel.appendChild(op)});
sel.disabled=true;cb.addEventListener('change',function(){sel.disabled=!cb.checked});c4.appendChild(sel);tr.appendChild(c4);q('ProdRows').appendChild(tr)})}
function load(){q('inv-status').textContent='Loading from vCenter and Horizon...';window.GI.getJson('/api/inventory').then(function(r){inv=r.ok?r.data:{vms:[],pools:[],errors:[r.error||'Could not load vCenter and Horizon.']};fillInv()})}
q('inv-retry').addEventListener('click',load);
form.addEventListener('input',function(){dirty=true});
window.addEventListener('beforeunload',function(e){if(dirty&&!created){e.preventDefault();e.returnValue=''}});
var created=false;
q('wiz-back').addEventListener('click',function(){if(cur>1){cur--;showErr('');render();return}if(!dirty||confirm('Discard what you entered?')){created=true;location.href='/'}});
q('wiz-next').addEventListener('click',function(){showErr('');var m=problem(cur);if(m){showErr(m);return}
if(cur<5){cur++;render();return}
if(payload().Promotion.AutoPromote&&!q('AutoOk').checked){showErr('Tick the box to confirm that new images reach production without approval.');return}
var b=q('wiz-next');b.disabled=true;b.textContent='Creating...';
window.GI.send('POST','/api/images',payload()).then(function(r){if(r.ok){created=true;location.href='/images/'+r.data.id+'?created=1'}else{b.disabled=false;b.textContent='Create golden image';showErr(r.error)}})});
render();load();
});
"@
}

#----- Audit log -----

function New-GIAuditLogPage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][object[]]$Entries = @(), [int]$Total = 0, [int]$Page = 1, [int]$PageSize = 50,
        [string[]]$Images = @(), [string[]]$Users = @(), [hashtable]$Filter = @{}
    )
    $sel = {
        param($name, $label, $opts, $cur)
        $o = foreach ($x in $opts) { $s = if ($x[0] -eq $cur) { ' selected' } else { '' }; '<option value="' + (ConvertTo-GIHtml $x[0]) + '"' + $s + '>' + (ConvertTo-GIHtml $x[1]) + '</option>' }
        "<div class=""field inline""><label for=""a-$name"">$label</label><select id=""a-$name"" name=""$name"">$(@($o) -join '')</select></div>"
    }
    $fv = { param($k) if ($Filter.ContainsKey($k)) { [string]$Filter[$k] } else { '' } }
    $imgOpts = @(, @('', 'All')) + @($Images | ForEach-Object { , @($_, $_) })
    $catOpts = @(@('', 'All actions'), @('approval', 'Approve and reject'), @('run', 'Run control'), @('poolvm', 'Pool and VM'), @('settings', 'Settings'), @('signin', 'Sign-ins'))
    $userOpts = @(, @('', 'Everyone')) + @($Users | ForEach-Object { , @($_, $_) })
    $form = "<form method=""get"" action=""/audit"" class=""filterrow"">$(& $sel 'image' 'Golden image' $imgOpts (& $fv 'image'))$(& $sel 'category' 'Action' $catOpts (& $fv 'category'))$(& $sel 'user' 'User' $userOpts (& $fv 'user'))<div class=""field inline""><label for=""a-from"">From</label><input type=""date"" id=""a-from"" name=""from"" value=""$(ConvertTo-GIHtml (& $fv 'from'))""></div><div class=""field inline""><label for=""a-to"">To</label><input type=""date"" id=""a-to"" name=""to"" value=""$(ConvertTo-GIHtml (& $fv 'to'))""></div><button type=""submit"" class=""btn small"">Apply</button><a class=""btn small"" href=""/audit.csv?$(Get-GIQueryString $Filter)"">Export CSV</a></form>"
    $rows = foreach ($e in @($Entries)) {
        $res = Get-GIAuditResult $e
        $variant = switch ($res) { 'Failed' { 'bad' } 'Denied' { 'bad' } 'Approved' { 'ok' } 'Passed' { 'ok' } 'Saved' { 'ok' } 'OK' { 'ok' } 'Allowed' { 'ok' } 'Started' { 'run' } default { 'idle' } }
        $role = if ($e.PSObject.Properties['role'] -and $e.role) { " <span class=""muted"">($(ConvertTo-GIHtml $e.role))</span>" } else { '' }
        $img = if ($e.PSObject.Properties['image'] -and $e.image) { ConvertTo-GIHtml $e.image } else { '<span class="muted">None</span>' }
        "<tr><td class=""mono nowrap"">$(Format-GIDate $e.at)</td><td>$(ConvertTo-GIHtml $e.user)$role</td><td>$(ConvertTo-GIHtml $e.action)</td><td>$img</td><td>$(ConvertTo-GIHtml (Get-GIAuditDetailText $e))</td><td>$(New-GIChip -Text $res -Variant $variant)</td></tr>"
    }
    $table = "<div class=""tablewrap""><table><thead><tr><th scope=""col"">When</th><th scope=""col"">User</th><th scope=""col"">Action</th><th scope=""col"">Golden image</th><th scope=""col"">Details</th><th scope=""col"">Result</th></tr></thead><tbody>$(@($rows) -join '')$(if (-not $rows) { '<tr><td colspan="6" class="muted">No entries match these filters.</td></tr>' })</tbody></table></div>"
    $pages = [math]::Max(1, [int][math]::Ceiling($Total / $PageSize))
    $from = if ($Total -eq 0) { 0 } else { ($Page - 1) * $PageSize + 1 }
    $to = [math]::Min($Page * $PageSize, $Total)
    $f2 = @{}; foreach ($k in $Filter.Keys) { $f2[$k] = $Filter[$k] }
    $f2.page = $Page - 1; $prevQ = Get-GIQueryString $f2; $f2.page = $Page + 1; $nextQ = Get-GIQueryString $f2
    $prev = if ($Page -gt 1) { New-GIButton -Label 'Previous' -Variant sec -Small -Href "/audit?$prevQ" } else { New-GIButton -Label 'Previous' -Variant sec -Small -Disabled -Reason 'First page' }
    $next = if ($Page -lt $pages) { New-GIButton -Label 'Next' -Variant sec -Small -Href "/audit?$nextQ" } else { New-GIButton -Label 'Next' -Variant sec -Small -Disabled -Reason 'Last page' }
    $pager = "<nav class=""pager"" aria-label=""Pages""><span>Showing $from to $to of $Total entries</span>$prev$next</nav>"
    New-GIPage -Title 'Audit log' -BodyHtml "<div><h1>Audit log</h1><p class=""muted"">Every action taken in the dashboard, across all golden images, including sign-ins. Visible to every role.</p></div>$(New-GICard -BodyHtml "$form$table$pager")"
}

function Get-GIQueryString {
    [CmdletBinding()]
    [OutputType([string])]
    param([hashtable]$Values)
    (@($Values.Keys | Sort-Object | Where-Object { $null -ne $Values[$_] -and [string]$Values[$_] -ne '' } | ForEach-Object { "$([uri]::EscapeDataString([string]$_))=$([uri]::EscapeDataString([string]$Values[$_]))" })) -join '&'
}
