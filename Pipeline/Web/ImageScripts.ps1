[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Script text helpers.')]
param()

# Page scripts for the golden image pages. Small vanilla JS, no libraries. They only add live values to a page that has
# already painted from stored data. Shared helpers (GI.getJson, GI.poll, GI.send, GI.live) come from Get-GIUiScript.

function Get-GILivePoolJs {
    # Shared by the home and overview scripts: state chip for a pool, power text, error text.
    @'
var PW={PoweredOn:'Powered on',PoweredOff:'Powered off',Suspended:'Suspended'};
function powerText(d){return d&&d.vm&&PW[d.vm.power]?PW[d.vm.power]:'Unknown'}
function poolState(p,d){var t=p.test;if(!p.snapshot){return ['No image pushed yet','idle']}
if(/ERROR|FAIL/i.test(p.state||'')){return ['Failed','bad']}
if(p.matchesLatest){return [(t&&p.snapshot!==d.lastKnownGood)?'New':'Current','ok']}
return ['Behind','idle']}
function setChip(el,text,variant){el.textContent='';var s=document.createElement('span');s.className='chip '+variant;s.textContent=text;el.appendChild(s)}
function errKind(errs){var v=errs.some(function(e){return /^vCenter/.test(e)}),h=errs.some(function(e){return /^Horizon/.test(e)});return v&&h?'vCenter or Horizon':(v?'vCenter':'Horizon')}
function ago(t){var s=Math.max(0,Math.round((Date.now()-t)/1000));return s<60?s+' seconds ago':Math.round(s/60)+' minutes ago'}
function hhmm(t){var x=new Date(t);return ('0'+x.getHours()).slice(-2)+':'+('0'+x.getMinutes()).slice(-2)}
function recall(id){try{var s=sessionStorage.getItem('gi-live-'+id);return s?JSON.parse(s):{}}catch(x){return {}}}
function store(id,k){try{sessionStorage.setItem('gi-live-'+id,JSON.stringify(k))}catch(x){}}
/* Keeps the last good vCenter part (vm) and Horizon part (pools) per image. When a part is missing from the live answer,
   the remembered part fills in and is flagged stale, so the page shows last known values (greyed) instead of Unknown. */
function merge(id,r){var d=r.ok?r.data:null,k=recall(id),now=Date.now(),st={vm:false,pools:false},o=null;
if(d){o={vm:d.vm,pools:d.pools||[],lastKnownGood:d.lastKnownGood||'',errors:d.errors||[]};
var hz=o.errors.some(function(e){return /^Horizon/.test(e)});
if(o.vm){k.vm=o.vm;k.vmAt=now}else if(k.vm){o.vm=k.vm;st.vm=true}
if(!hz&&o.pools.length){k.pools=o.pools;k.poolsAt=now}else if(hz&&k.pools){o.pools=k.pools;st.pools=true}
if(o.lastKnownGood){k.lkg=o.lastKnownGood}else if(k.lkg){o.lastKnownGood=k.lkg}
store(id,k)}
else if(k.vm||k.pools){o={vm:k.vm||null,pools:k.pools||[],lastKnownGood:k.lkg||'',errors:[]};st.vm=!!k.vm;st.pools=!!k.pools}
var at=[];if(st.vm){at.push(k.vmAt)}if(st.pools){at.push(k.poolsAt)}
return {d:o,stale:st,note:at.length?' Last known state as of '+hhmm(Math.min.apply(null,at))+'.':''}}
'@
}

function Get-GIHomeScript {
    $pre = Get-GILivePoolJs
    @"
document.addEventListener('DOMContentLoaded',function(){
$pre
var grid=document.querySelector('.cardgrid');if(!grid){return}
var secs=+grid.getAttribute('data-refresh')||60,last=null,errs={},cards=[].slice.call(grid.querySelectorAll('[data-image]'));
var upd=document.getElementById('gi-updated');
function header(){if(!upd||!last){return}var bad=Object.keys(errs).filter(function(k){return errs[k]});
upd.textContent=(bad.length?'Some checks failed. ':'vCenter and Horizon connected. ')+'Updated '+ago(last)+'.'}
setInterval(header,5000);
function sortPools(card,data){var tb=card.querySelector('.pooltable tbody');if(!tb){return}
var rows=[].slice.call(tb.querySelectorAll('tr'));
function prob(r){var s=r.getAttribute('data-st');return s==='Behind'||s==='Failed'}
var test=rows.filter(function(r){return r.getAttribute('data-test')==='true'}),rest=rows.filter(function(r){return r.getAttribute('data-test')!=='true'});
var order=test.concat(rest.filter(prob),rest.filter(function(r){return !prob(r)}));
order.forEach(function(r){tb.appendChild(r)});
var btn=card.querySelector('[data-more-pools]'),open=btn&&btn.getAttribute('aria-expanded')==='true',hidden=0,hp=0;
order.forEach(function(r,i){var h=!open&&i>=3;r.hidden=h;if(h){hidden++;if(prob(r)){hp++}}});
if(btn){btn.hidden=order.length<=3;btn.textContent=open?'Show fewer pools':'Show '+(order.length-3)+' more pools'+(hp?' ('+hp+' behind)':'')}}
function apply(card,r){var msg=card.querySelector('[data-live-msg]'),chip=card.querySelector('.chipslot'),stored=card.getAttribute('data-state');
var m=merge(card.getAttribute('data-image'),r),d=m.d,e=r.ok?(r.data.errors||[]):[r.error||'The dashboard did not answer'];
card.querySelectorAll('[data-live=power]').forEach(function(n){n.textContent=powerText(d);n.classList.toggle('stale',m.stale.vm)});
var pools={};if(d&&d.pools){d.pools.forEach(function(p){pools[p.pool]=p})}
card.querySelectorAll('.pooltable tbody tr').forEach(function(row){var name=row.getAttribute('data-pool'),p=pools[name],snap=row.querySelector('[data-col=snapshot]'),st=row.querySelector('[data-col=state]');
row.classList.toggle('stale',m.stale.pools);
if(p){p.test=row.getAttribute('data-test')==='true';snap.textContent=p.snapshot||'None';var s=poolState(p,d);setChip(st,s[0],s[1]);row.setAttribute('data-st',s[0])}
else{snap.textContent='Unknown';setChip(st,'Unknown','idle');row.setAttribute('data-st','Unknown')}});
sortPools(card,d);
var startBtn=card.querySelector('[data-live-btn] button');
errs[card.getAttribute('data-image')]=e.length>0;
if(e.length){msg.hidden=false;msg.textContent='';var t=document.createElement('span');t.textContent=e.join(' ')+m.note;msg.appendChild(t);
var b=document.createElement('button');b.type='button';b.className='btn small dangerline';b.textContent='Try again';b.addEventListener('click',function(){load(card)});msg.appendChild(b);
if(stored==='Checking...'){setChip(chip,'Can\'t reach '+errKind(e),'warn')}
if(startBtn){startBtn.disabled=true;startBtn.title='Can\'t reach '+errKind(e)}}
else{msg.hidden=true;msg.textContent='';
if(stored==='Checking...'){setChip(chip,'Up to date','ok');card.setAttribute('data-state','Up to date')}
if(startBtn){startBtn.disabled=false;startBtn.removeAttribute('title')}}
last=Date.now();header()}
function load(card){return window.GI.getJson('/api/images/'+card.getAttribute('data-image')+'/live').then(function(r){apply(card,r)})}
function refreshAll(){return Promise.all(cards.map(load))}
grid.addEventListener('click',function(e){var b=e.target.closest&&e.target.closest('[data-more-pools]');if(!b){return}
var open=b.getAttribute('aria-expanded')==='true';b.setAttribute('aria-expanded',open?'false':'true');sortPools(b.closest('[data-image]'))});
var rb=document.getElementById('gi-refresh');if(rb){rb.addEventListener('click',function(){refreshAll()})}
window.GI.poll(refreshAll,secs);
});
"@
}

function Get-GIOverviewScript {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ImageId, [bool]$IsAdmin = $false, [bool]$Locked = $false)
    $pre = Get-GILivePoolJs
    $adm = if ($IsAdmin) { 'true' } else { 'false' }
    $lck = if ($Locked) { 'true' } else { 'false' }
    $idj = ConvertTo-Json -InputObject $ImageId -Compress
    @"
document.addEventListener('DOMContentLoaded',function(){
$pre
var ID=$idj,ADMIN=$adm,LOCKED=$lck,last=null;
var upd=document.getElementById('gi-updated'),errBox=document.getElementById('gi-live-error');
function tick(){if(upd&&last){upd.textContent='updated '+ago(last)}}setInterval(tick,5000);
function td(t,cls){var c=document.createElement('td');if(cls){c.className=cls}c.textContent=t;return c}
function revertBtn(name){var b=document.createElement('button');b.type='button';b.className='btn dangerline small';b.textContent='Revert VM';
b.setAttribute('data-opens','dlg-revert');b.setAttribute('data-fill-snapshot',name);b.setAttribute('aria-label','Revert VM to '+name);if(LOCKED){b.disabled=true;b.title='A run is in progress'}return b}
function apply(r){var m=merge(ID,r),d=m.d,e=r.ok?(r.data.errors||[]):[r.error||'The dashboard did not answer'];
document.querySelectorAll('[data-live=power]').forEach(function(n){n.textContent=powerText(d);n.classList.toggle('stale',m.stale.vm)});
var vs=document.querySelector('[data-live=vmsnap]');if(vs){vs.classList.toggle('stale',m.stale.vm);var cur=d&&d.vm?(d.vm.snapshots.filter(function(s){return s.isCurrent})[0]||{}).name:'';vs.textContent=cur||(d&&d.vm?'None':'Unknown')}
var on=document.querySelector('[data-power-on]'),off=document.querySelector('[data-power-off]');
if(on&&off){var p=d&&d.vm?d.vm.power:'';on.hidden=p!=='PoweredOff';off.hidden=p!=='PoweredOn'}
var pools={};if(d&&d.pools){d.pools.forEach(function(p){pools[p.pool]=p})}
document.querySelectorAll('.poolsfull tbody tr').forEach(function(row){row.classList.toggle('stale',m.stale.pools);var p=pools[row.getAttribute('data-pool')],snap=row.querySelector('[data-col=snapshot]'),st=row.querySelector('[data-col=state]');
if(p){p.test=row.getAttribute('data-test')==='true';snap.textContent=p.snapshot||'No image pushed yet';var s=poolState(p,d);setChip(st,s[0],s[1])}else{snap.textContent='Unknown';setChip(st,'Unknown','idle')}});
var rows=document.getElementById('gi-snap-rows'),sel=document.getElementById('rb-snap');
if(rows&&d&&d.vm){rows.textContent='';rows.classList.toggle('stale',m.stale.vm);var used={};(d.pools||[]).forEach(function(p){if(p.snapshot){used[p.snapshot]=(used[p.snapshot]||0)+1}});
var list=d.vm.snapshots.slice().sort(function(a,b){return a.created<b.created?1:-1});
if(!list.length){var tr0=document.createElement('tr'),c0=td('No snapshots yet.','muted');c0.colSpan=5;tr0.appendChild(c0);rows.appendChild(tr0)}
list.forEach(function(s){var tr=document.createElement('tr');tr.appendChild(td(s.name,'mono'));tr.appendChild(td(s.created.replace('T',' ').substring(0,16)));
tr.appendChild(td(used[s.name]?used[s.name]+(used[s.name]===1?' pool':' pools'):'None'));
var tg=document.createElement('td');if(d.lastKnownGood===s.name){var c=document.createElement('span');c.className='chip ok';c.textContent='Last known good';tg.appendChild(c)}
var og=(d.vm.outsideRetention||[]).filter(function(o){return o.name===s.name})[0];if(og){var oc=document.createElement('span');oc.className='chip idle';oc.textContent='Outside retention';oc.title=og.reason;tg.appendChild(oc)}tr.appendChild(tg);
var ac=document.createElement('td');ac.className='right';if(ADMIN){ac.appendChild(revertBtn(s.name))}tr.appendChild(ac);rows.appendChild(tr)});
if(sel){var keep=sel.value;sel.textContent='';var o=document.createElement('option');o.value='';o.textContent='Last known good'+(d.lastKnownGood?' ('+d.lastKnownGood+')':'');sel.appendChild(o);
list.forEach(function(s){var op=document.createElement('option');op.value=s.name;op.textContent=s.name;sel.appendChild(op)});sel.value=keep}}
else if(rows&&!d){rows.textContent='';var tr=document.createElement('tr'),c=td('Snapshots could not be loaded.','muted');c.colSpan=5;tr.appendChild(c);rows.appendChild(tr)}
if(e.length){errBox.hidden=false;errBox.textContent='';var t=document.createElement('span');t.className='banner-text';t.textContent=e.join(' ')+m.note;errBox.appendChild(t);
var b=document.createElement('button');b.type='button';b.className='btn small';b.textContent='Try again';b.addEventListener('click',load);errBox.appendChild(b)}else{errBox.hidden=true}
var chip=document.getElementById('gi-statechip');if(chip&&chip.textContent.trim()==='Checking...'){if(e.length){setChip(chip,'Can\'t reach '+errKind(e),'warn')}else{setChip(chip,'Up to date','ok')}}
last=Date.now();tick()}
function load(){return window.GI.getJson('/api/images/'+ID+'/live').then(apply)}
document.addEventListener('gi:changed',function(){load();setTimeout(load,5000);setTimeout(load,15000)});
document.addEventListener('click',function(ev){var b=ev.target.closest&&ev.target.closest('[data-opens=dlg-rollback]');if(b){var n=b.getAttribute('data-fill-pool');var f=document.querySelector('#dlg-rollback form');if(f){f.querySelector('[data-must-match]').setAttribute('data-must-match',n)}}});
window.GI.poll(load,60);
});
"@
}

function Get-GIRunsTabScript {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ImageId)
    $idj = ConvertTo-Json -InputObject $ImageId -Compress
    @"
document.addEventListener('DOMContentLoaded',function(){
var ID=$idj;
function upd(tr){var id=tr.getAttribute('data-active-run');window.GI.getJson('/api/images/'+ID+'/runs/'+id).then(function(r){if(!r.ok){return}var run=r.data.run;
tr.querySelector('[data-col=stage]').textContent=run.currentStage||'';
var s=run.status==='AwaitingApproval'?'Awaiting approval':run.status,v=run.status==='Failed'?'bad':(run.status==='Running'?'run':(run.status==='AwaitingApproval'?'warn':'ok'));
var c=tr.querySelector('[data-col=status]');c.textContent='';var ch=document.createElement('span');ch.className='chip '+v;ch.textContent=s;c.appendChild(ch);
if(run.status!=='Running'&&run.status!=='AwaitingApproval'){tr.removeAttribute('data-active-run')}})}
function all(){document.querySelectorAll('[data-active-run]').forEach(upd)}
window.GI.poll(all,10);
});
"@
}
