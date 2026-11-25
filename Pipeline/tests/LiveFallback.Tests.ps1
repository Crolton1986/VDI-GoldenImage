BeforeAll {
    foreach ($f in 'DashboardViews', 'Components', 'ImageScripts') { . (Join-Path $PSScriptRoot '..' 'Web' "$f.ps1") }
    $script:node = Get-Command node -ErrorAction SilentlyContinue
    function script:Invoke-LiveJs([string]$Calls) {
        # Runs the shared live helpers (merge, recall, store) in node with a sessionStorage shim; returns the JSON printed by $Calls.
        $js = "var mem={};global.sessionStorage={getItem:function(k){return k in mem?mem[k]:null},setItem:function(k,v){mem[k]=String(v)}};`n" +
        (Get-GILivePoolJs) + "`n$Calls"
        $f = Join-Path ([System.IO.Path]::GetTempPath()) "gi-live-$([guid]::NewGuid().ToString('N')).js"
        try { Set-Content -LiteralPath $f -Value $js -Encoding utf8; (& $script:node.Source $f) -join "`n" } finally { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue }
    }
}

Describe 'Last known state when a live check fails (gap 5)' {
    It 'ships the helpers and the greyed style' {
        $js = Get-GILivePoolJs
        $js | Should -Match 'function merge\('
        $js | Should -Match 'Last known state as of '
        (Get-GICss) | Should -Match '\.stale\{opacity'
        (Get-GIHomeScript) | Should -Match 'merge\(card\.getAttribute'
        (Get-GIOverviewScript -ImageId 'a') | Should -Match 'merge\(ID,r\)'
    }
    It 'uses no hex colour outside :root for the stale style' {
        $css = Get-GICss
        ($css -replace ':root\{[^}]*\}', '') | Should -Not -Match '#[0-9a-fA-F]{3,6}\b'
    }
    It 'fills a failed part from the remembered one and says when it was current' -Skip:(-not (Get-Command node -ErrorAction SilentlyContinue)) {
        $out = Invoke-LiveJs @'
var good={ok:true,data:{vm:{power:'PoweredOn',snapshots:[]},pools:[{pool:'P1',snapshot:'B1'}],lastKnownGood:'B1',errors:[]}};
var a=merge('img1',good);
var bad={ok:true,data:{vm:null,pools:[{pool:'P1',snapshot:'B2'}],lastKnownGood:'',errors:['vCenter: timed out']}};
var b=merge('img1',bad);
var down=merge('img1',{ok:false,error:'The dashboard did not answer'});
var other=merge('img2',{ok:false,error:'x'});
console.log(JSON.stringify({a:a.stale,b:b.stale,bvm:b.d.vm.power,bpool:b.d.pools[0].snapshot,blkg:b.d.lastKnownGood,bnote:/^ Last known state as of \d\d:\d\d\.$/.test(b.note),
 down:down.stale,downnote:down.note.length>0,other:other.d,othernote:other.note}));
'@
        $r = $out | ConvertFrom-Json
        $r.a.vm | Should -BeFalse; $r.a.pools | Should -BeFalse
        $r.b.vm | Should -BeTrue;  $r.b.pools | Should -BeFalse   # Horizon answered: its pools are current, only the VM is last known
        $r.bpool | Should -Be 'B2'
        $r.bvm | Should -Be 'PoweredOn'
        $r.blkg | Should -Be 'B1'
        $r.bnote | Should -BeTrue
        $r.down.vm | Should -BeTrue; $r.down.pools | Should -BeTrue
        $r.downnote | Should -BeTrue
        $r.other | Should -BeNullOrEmpty    # nothing known for this image: stays Unknown
        $r.othernote | Should -Be ''
    }
    It 'marks pools stale only when Horizon reported the error' -Skip:(-not (Get-Command node -ErrorAction SilentlyContinue)) {
        $out = Invoke-LiveJs @'
merge('i',{ok:true,data:{vm:{power:'PoweredOff',snapshots:[]},pools:[{pool:'P1',snapshot:'B2'}],lastKnownGood:'',errors:[]}});
var m=merge('i',{ok:true,data:{vm:{power:'PoweredOff',snapshots:[]},pools:[],lastKnownGood:'',errors:['Horizon: 503']}});
console.log(JSON.stringify({st:m.stale,snap:m.d.pools[0].snapshot}));
'@
        $r = $out | ConvertFrom-Json
        $r.st.pools | Should -BeTrue; $r.st.vm | Should -BeFalse; $r.snap | Should -Be 'B2'
    }
}
