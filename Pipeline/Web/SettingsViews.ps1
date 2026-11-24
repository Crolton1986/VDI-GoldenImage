[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Helpers return heterogeneous values by design.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '', Justification = 'Internal view helpers; short positional calls keep HTML builders readable.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-* functions only build strings; nothing is changed.')]
param()

# Pure HTML view functions for settings, run control and audit (dashboard v2).
# Requires Web/DashboardViews.ps1 (ConvertTo-GIHtml, Get-GIValue, New-GIPage, ...) to be loaded first.
# Every dynamic value is HTML-encoded with ConvertTo-GIHtml. No external JS/CSS; the pages work without JS.

function Get-GIHtmlId {
    <# Encoded, attribute-safe element id derived from a (possibly dotted/indexed) key. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Prefix, [Parameter(Mandatory)][string]$Key)
    ConvertTo-GIHtml ($Prefix + '_' + ($Key -replace '[^A-Za-z0-9_-]', '_'))
}

function Get-GITokenInput {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Token)
    "<input type=""hidden"" name=""token"" value=""$(ConvertTo-GIHtml $Token)"">"
}

function Get-GISchemaSection {
    [CmdletBinding()]
    [OutputType([object])]
    param($Schema, [string]$SectionKey)
    if ($Schema -is [System.Collections.IDictionary] -and $Schema.Contains($SectionKey)) { return $Schema[$SectionKey] }
    return $null
}

function New-GISettingsLayout {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Schema,
        [string]$ActiveSection = '',
        [Parameter(Mandatory)][AllowEmptyString()][string]$ContentHtml   # already-encoded HTML
    )
    "<div class=""settings-main"">$ContentHtml</div>"
}

function Get-GIControlHtml {
    <# One input control for a scalar field def. $Name is the form name, $Value the current value. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Field, [Parameter(Mandatory)][string]$Name, $Value, [string]$IdPrefix = 'f', [string]$Extra = '')
    $type = [string](Get-GIValue $Field 'Type' 'string')
    $n = ConvertTo-GIHtml $Name
    $id = Get-GIHtmlId $IdPrefix $Name
    switch ($type) {
        'bool' {
            $chk = ''
            if ($Value -eq $true -or [string]$Value -eq 'on') { $chk = ' checked' }
            return "<input type=""checkbox"" id=""$id"" name=""$n"" value=""on""$chk$Extra>"
        }
        'int' {
            $attr = ''
            $min = Get-GIValue $Field 'Min' $null
            $max = Get-GIValue $Field 'Max' $null
            if ($null -ne $min) { $attr += " min=""$(ConvertTo-GIHtml $min)""" }
            if ($null -ne $max) { $attr += " max=""$(ConvertTo-GIHtml $max)""" }
            return "<input type=""number"" id=""$id"" name=""$n"" value=""$(ConvertTo-GIHtml $Value)""$attr$Extra>"
        }
        'time' { return "<input type=""time"" id=""$id"" name=""$n"" value=""$(ConvertTo-GIHtml $Value)""$Extra>" }
        'enum' {
            $opts = foreach ($v in @(Get-GIValue $Field 'Values' @())) {
                $sel = ''
                if ([string]$v -eq [string]$Value) { $sel = ' selected' }
                "<option value=""$(ConvertTo-GIHtml $v)""$sel>$(ConvertTo-GIHtml $v)</option>"
            }
            return "<select id=""$id"" name=""$n""$Extra>$($opts -join '')</select>"
        }
        default { return "<input type=""text"" id=""$id"" name=""$n"" value=""$(ConvertTo-GIHtml $Value)""$Extra>" }
    }
}

function Get-GITableFieldHtml {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Field, $Value)
    $key = [string]$Field.Key
    $cols = @(Get-GIValue $Field 'Columns' @())
    $tid = Get-GIHtmlId 't' $key
    $rows = @()
    if ($null -ne $Value) { $rows = @($Value) }
    $count = $rows.Count + 2   # always two blank rows so the form works without JS
    $head = ($cols | ForEach-Object { "<th>$(ConvertTo-GIHtml (Get-GIValue $_ 'Label' (Get-GIValue $_ 'Key'))) </th>" }) -join ''
    $body = ''
    for ($i = 0; $i -lt $count; $i++) {
        $row = $null
        if ($i -lt $rows.Count) { $row = $rows[$i] }
        $cells = ''
        foreach ($c in $cols) {
            $ck = [string]$c.Key
            $cells += "<td>$(Get-GIControlHtml -Field $c -Name ('{0}[{1}].{2}' -f $key, $i, $ck) -Value (Get-GIValue $row $ck) -IdPrefix 'c')</td>"
        }
        $rm = ConvertTo-GIHtml ('{0}[{1}]._remove' -f $key, $i)
        $cells += "<td><label><input type=""checkbox"" name=""$rm"" value=""on""> remove</label></td>"
        $body += "<tr>$cells</tr>"
    }
    $esc = ConvertTo-GIHtml $key
    "<table class=""edit"" id=""$tid"" data-key=""$esc""><thead><tr>$head<th></th></tr></thead><tbody>$body</tbody></table><p><button type=""button"" class=""sec gi-addrow"" data-table=""$tid"">Add row</button></p>"
}

function Get-GIAddRowScript {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    @'
<script>
document.querySelectorAll('button.gi-addrow').forEach(function(b){b.addEventListener('click',function(){
var t=document.getElementById(b.dataset.table);var tb=t.tBodies[0];var last=tb.rows[tb.rows.length-1];
var n=tb.rows.length;var c=last.cloneNode(true);
c.querySelectorAll('input,select').forEach(function(e){
e.name=e.name.replace(/\[\d+\]/,'['+n+']');e.removeAttribute('id');
if(e.type==='checkbox'){e.checked=false}else if(e.tagName==='SELECT'){e.selectedIndex=0}else{e.value=''}});
tb.appendChild(c);});});
</script>
'@
}

function Get-GISecretBlockHtml {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Field, $Value, [Parameter(Mandatory)][string]$SectionKey, [string]$Token, [bool]$IsHttps)
    $key = [string]$Field.Key
    $label = ConvertTo-GIHtml (Get-GIValue $Field 'Label' $key)
    $isSet = [bool](Get-GIValue $Value 'IsSet' $false)
    $badge = '<span class="badge st-pending">not set</span>'
    if ($isSet) { $badge = '<span class="badge st-ok">set</span>' }
    $dis = ''
    $note = ''
    if (-not $IsHttps) {
        $dis = ' disabled'
        $note = '<p class="warn">Credentials can only be entered over https.</p>'
    }
    $id = ConvertTo-GIHtml ($key -replace '[^A-Za-z0-9_-]', '_')
    $user = ConvertTo-GIHtml (Get-GIValue $Value 'UserName')
    @"
<form method="post" action="/settings/$(ConvertTo-GIHtml $SectionKey)/credential" class="formbox cred" autocomplete="off">
<input type="hidden" name="key" value="$(ConvertTo-GIHtml $key)">
$(Get-GITokenInput $Token)
<div class="lbl"><strong>$label</strong> $badge</div>
$note
<p><label for="cu_$id">Username</label><br><input type="text" id="cu_$id" name="username" value="$user" autocomplete="off"$dis></p>
<p><label for="cp_$id">Password</label><br><input type="password" id="cp_$id" name="password" value="" autocomplete="new-password"$dis><br><span class="muted">Leave blank to keep the existing password.</span></p>
<p><button type="submit"$dis>Save credential</button></p>
</form>
"@
}

function New-GISettingsSectionPage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Schema,
        [Parameter(Mandatory)][string]$SectionKey,
        $SectionData,
        $Errors,
        [string]$Token = '',
        [string]$Notice = '',
        $TestResult = $null,
        [bool]$IsHttps = $false
    )
    $section = Get-GISchemaSection $Schema $SectionKey
    $sk = ConvertTo-GIHtml $SectionKey
    if ($null -eq $section) {
        return New-GIPage -Title 'Settings' -BodyHtml (New-GISettingsLayout -Schema $Schema -ActiveSection '' -ContentHtml '<h2>Unknown section</h2>')
    }
    $values = Get-GIValue $SectionData 'Values' @{}
    if ($null -eq $Errors) { $Errors = @{} }
    $readOnly = [bool](Get-GIValue $section 'ReadOnly' $false)
    $title = ConvertTo-GIHtml (Get-GIValue $section 'Title' $SectionKey)
    $fields = @(Get-GIValue $section 'Fields' @())

    $h = "<h2>$title</h2>"
    $desc = Get-GIValue $section 'Description'
    if ($desc) { $h += "<p class=""muted"">$(ConvertTo-GIHtml $desc)</p>" }
    if ($Notice) { $h += "<div class=""notice"" role=""status"">$(ConvertTo-GIHtml $Notice)</div>" }

    if ($Errors.Count -gt 0) {
        $li = foreach ($f in $fields) {
            $fk = [string]$f.Key
            if ($Errors.Contains($fk)) { "<li>$(ConvertTo-GIHtml (Get-GIValue $f 'Label' $fk)): $(ConvertTo-GIHtml $Errors[$fk])</li>" }
        }
        $other = foreach ($ek in $Errors.Keys) {
            if (-not ($fields | Where-Object { [string]$_.Key -eq [string]$ek })) { "<li>$(ConvertTo-GIHtml $ek): $(ConvertTo-GIHtml $Errors[$ek])</li>" }
        }
        $h += "<div class=""errsum"" role=""alert""><strong>Settings were not saved. Fix the following:</strong><ul>$(@($li) -join '')$(@($other) -join '')</ul></div>"
    }

    if ($readOnly) {
        $h += '<p class="muted">Edit pipeline.config.psd1 on the server and restart the dashboard.</p><section class="card"><dl class="kv">'
        foreach ($f in $fields) {
            $fk = [string]$f.Key
            $v = Get-GIValue $values $fk $null
            $text = ''
            if ($f.Type -eq 'secret') {
                $text = 'not set'
                if (Get-GIValue $v 'IsSet' $false) { $text = 'set' }
            } elseif ($f.Type -eq 'table') {
                $text = (@($v) | ForEach-Object { ($_ | ConvertTo-Json -Compress -Depth 5) }) -join '; '
            } elseif ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) {
                $text = (@($v) | ForEach-Object { [string]$_ }) -join ', '
            } else {
                $text = [string]$v
            }
            $h += "<dt>$(ConvertTo-GIHtml (Get-GIValue $f 'Label' $fk))</dt><dd>$(ConvertTo-GIHtml $text)</dd>"
        }
        $h += '</dl></section>'
    } else {
        $secretBlocks = ''
        $h += "<form method=""post"" action=""/settings/$sk"" class=""settings-form"">$(Get-GITokenInput $Token)"
        foreach ($f in $fields) {
            $fk = [string]$f.Key
            $type = [string](Get-GIValue $f 'Type' 'string')
            if ($type -eq 'secret') {
                $secretBlocks += Get-GISecretBlockHtml -Field $f -Value (Get-GIValue $values $fk $null) -SectionKey $SectionKey -Token $Token -IsHttps $IsHttps
                continue
            }
            $v = Get-GIValue $values $fk $null
            $fid = Get-GIHtmlId 'f' $fk
            $label = ConvertTo-GIHtml (Get-GIValue $f 'Label' $fk)
            if (Get-GIValue $f 'Required' $false) { $label += ' <span class="req" title="required">*</span>' }
            $hasErr = $Errors.Contains($fk)
            $h += '<div class="field">'
            switch ($type) {
                'bool' {
                    $h += "<label for=""$fid"">$(Get-GIControlHtml -Field $f -Name $fk -Value $v) $label</label>"
                    if (Get-GIValue $f 'Confirm' $false) {
                        $cid = Get-GIHtmlId 'f' ("confirm_$fk")
                        $h += "<div><label for=""$cid""><input type=""checkbox"" id=""$cid"" name=""$(ConvertTo-GIHtml "confirm_$fk")"" value=""on""> I understand and confirm this change</label></div>"
                    }
                }
                'list' {
                    $text = (@($v) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) -join "`n"
                    $h += "<label for=""$fid"">$label</label><textarea id=""$fid"" name=""$(ConvertTo-GIHtml $fk)"" rows=""4"">$(ConvertTo-GIHtml $text)</textarea><div class=""help"">One entry per line.</div>"
                }
                'days' {
                    $sel = @($v | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
                    $boxes = foreach ($d in 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday') {
                        $chk = ''
                        if ($sel -contains $d) { $chk = ' checked' }
                        "<label><input type=""checkbox"" name=""$(ConvertTo-GIHtml $fk)"" value=""$d""$chk> $d</label>"
                    }
                    $h += "<div class=""lbl"">$label</div><div class=""days"">$($boxes -join '')</div>"
                }
                'table' {
                    $h += "<div class=""lbl"">$label</div>$(Get-GITableFieldHtml -Field $f -Value $v)"
                }
                default {
                    $h += "<label for=""$fid"">$label</label>$(Get-GIControlHtml -Field $f -Name $fk -Value $v)"
                }
            }
            if ($hasErr) { $h += "<span class=""err ferr"" role=""alert"">$(ConvertTo-GIHtml $Errors[$fk])</span>" }
            $help = Get-GIValue $f 'Help'
            if ($help) { $h += "<div class=""help"">$(ConvertTo-GIHtml $help)</div>" }
            $warn = Get-GIValue $f 'Warning'
            if ($warn) { $h += "<div class=""warn"">Warning: $(ConvertTo-GIHtml $warn)</div>" }
            $h += '</div>'
        }
        $h += '<p><button type="submit">Save</button></p></form>'
        $h += $secretBlocks
        if (@($fields | Where-Object { $_.Type -eq 'table' }).Count -gt 0) { $h += Get-GIAddRowScript }
    }

    if (Get-GIValue $section 'Test' $null) {
        $h += "<h2>Test connection</h2><form method=""post"" action=""/settings/$sk/test"" class=""formbox"">$(Get-GITokenInput $Token)<button type=""submit"" class=""sec"">Test connection</button></form>"
        if ($null -ne $TestResult) {
            $ok = [bool](Get-GIValue $TestResult 'ok' $false)
            $cls = 'fail'
            $word = 'Failed'
            if ($ok) { $cls = 'ok'; $word = 'OK' }
            $h += "<div class=""testres $cls"" role=""status""><strong>$word</strong> $(ConvertTo-GIHtml (Get-GIValue $TestResult 'detail'))</div>"
        }
    }

    New-GIPage -Title "Settings - $(Get-GIValue $section 'Title' $SectionKey)" -BodyHtml (New-GISettingsLayout -Schema $Schema -ActiveSection $SectionKey -ContentHtml $h)
}

function New-GIRunControlPage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        $Runs = @(),
        $Lock = $null,
        $PendingRequest = $null,
        [string]$Token = '',
        [string[]]$Stages = @(),
        [string]$TestPool = '',
        [string[]]$ProdPools = @(),
        [string]$LastKnownGood = '',
        [string]$Notice = ''
    )
    $stale = $false
    if ($null -ne $Lock) { $stale = [bool](Get-GIValue $Lock 'stale' $false) }
    $busy = ($null -ne $Lock -and -not $stale) -or ($null -ne $PendingRequest)
    $dis = ''
    if ($busy) { $dis = ' disabled' }
    $tok = Get-GITokenInput $Token

    $h = '<h2>Run control</h2>'
    if ($Notice) { $h += "<div class=""notice"" role=""status"">$(ConvertTo-GIHtml $Notice)</div>" }

    $h += '<section class="card"><h3>Status</h3>'
    if ($null -ne $Lock) {
        $state = 'Busy'
        if ($stale) { $state = 'Stale lock (owning process is gone; runs may be started)' }
        $h += "<p><strong>$state</strong></p><dl class=""kv""><dt>Stage</dt><dd>$(ConvertTo-GIHtml (Get-GIValue $Lock 'stage'))</dd><dt>Run</dt><dd>$(ConvertTo-GIHtml (Get-GIValue $Lock 'runId'))</dd><dt>Requested by</dt><dd>$(ConvertTo-GIHtml (Get-GIValue $Lock 'requestedBy'))</dd><dt>Started</dt><dd>$(Format-GIDate (Get-GIValue $Lock 'startedAt'))</dd><dt>Stale</dt><dd>$(if ($stale) { 'yes' } else { 'no' })</dd></dl>"
    } else {
        $h += '<p><strong>Idle</strong></p>'
    }
    if ($null -ne $PendingRequest) {
        $h += "<p><strong>Queued, waiting for the runner</strong></p><dl class=""kv""><dt>Action</dt><dd>$(ConvertTo-GIHtml (Get-GIValue $PendingRequest 'action'))</dd><dt>Stage</dt><dd>$(ConvertTo-GIHtml (Get-GIValue $PendingRequest 'stage'))</dd><dt>Requested by</dt><dd>$(ConvertTo-GIHtml (Get-GIValue $PendingRequest 'requestedBy'))</dd><dt>Requested at</dt><dd>$(Format-GIDate (Get-GIValue $PendingRequest 'requestedAt'))</dd></dl>"
        $h += "<form method=""post"" action=""/run/cancel-request"">$tok<button type=""submit"" class=""sec"">Cancel queued request</button></form>"
    }
    if ($busy) { $h += '<p class="muted">Controls below are disabled while the pipeline is busy or a request is queued.</p>' }
    $h += '<p class="muted">There is no stop button on purpose: killing a run in the middle of a snapshot or a push leaves vCenter or Horizon half-done. In an emergency, end the VDI-GI-Runner task in Task Scheduler on the server.</p></section>'

    $h += "<section class=""card""><h3>Start full run</h3><form method=""post"" action=""/run/start"">$tok<input type=""hidden"" name=""action"" value=""All""><button type=""submit""$dis>Start full run</button></form></section>"

    $recent = @($Runs | Where-Object { $_ } | Sort-Object { [string](Get-GIValue $_ 'runId') } -Descending | Select-Object -First 20)
    $runOpts = ($recent | ForEach-Object { $rid = ConvertTo-GIHtml (Get-GIValue $_ 'runId'); "<option value=""$rid"">$rid ($(ConvertTo-GIHtml (Get-GIValue $_ 'status')))</option>" }) -join ''
    $stOpts = ($Stages | ForEach-Object { "<option value=""$(ConvertTo-GIHtml $_)"">$(ConvertTo-GIHtml $_)</option>" }) -join ''
    $h += @"
<section class="card"><h3>Retry / single stage</h3>
<form method="post" action="/run/start">$tok
<p><label>Run<br><select name="runId"$dis>$runOpts</select></label></p>
<p><label>Stage<br><select name="stage"$dis>$stOpts</select></label></p>
<p><label><input type="radio" name="action" value="FromStage" checked$dis> Run this stage through Validate</label><br>
<label><input type="radio" name="action" value="Stage"$dis> Run only this stage</label></p>
<p><button type="submit"$dis>Start</button></p></form></section>
<section class="card"><h3>PostCheck now</h3>
<form method="post" action="/run/start">$tok<input type="hidden" name="action" value="PostCheck"><button type="submit"$dis>Run PostCheck now</button></form></section>
"@

    $pools = @()
    if ($TestPool) { $pools += $TestPool }
    $pools += @($ProdPools)
    $poolOpts = ($pools | ForEach-Object { "<option value=""$(ConvertTo-GIHtml $_)"">$(ConvertTo-GIHtml $_)</option>" }) -join ''
    $lkg = ConvertTo-GIHtml $LastKnownGood
    $h += @"
<section class="card"><h3>Roll back a pool</h3>
<form method="post" action="/run/rollback">$tok
<p><label>Pool<br><select name="pool"$dis>$poolOpts</select></label></p>
<p><label>Snapshot name<br><input type="text" name="snapshotName" value="" placeholder="$lkg"$dis></label><br><span class="muted">Leave blank to use the last known good snapshot: <strong>$lkg</strong></span></p>
<p><label><input type="checkbox" name="forceLogoff" value="on"$dis> Force logoff</label><br><span class="warn">Warning: Ends active sessions on that pool.</span></p>
<p><label>Type the pool name to confirm<br><input type="text" name="confirmPool" value="" autocomplete="off"$dis></label></p>
<p><button type="submit" class="danger"$dis>Roll back</button></p></form></section>
"@
    New-GIPage -Title 'Run control' -BodyHtml $h
}

function ConvertTo-GIAuditDetailHtml {
    [CmdletBinding()]
    [OutputType([string])]
    param($Detail)
    if ($null -eq $Detail) { return '' }
    $lines = @()
    $props = @()
    if ($Detail -is [System.Collections.IDictionary]) {
        $props = $Detail.Keys | ForEach-Object { [pscustomobject]@{ Name = [string]$_; Value = $Detail[$_] } }
    } elseif ($Detail -is [psobject] -and $Detail -isnot [string] -and $Detail.PSObject.Properties.Count -gt 0 -and $Detail -isnot [System.ValueType]) {
        $props = $Detail.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } }
    } else {
        return ConvertTo-GIHtml ([string]$Detail)
    }
    $isDiff = { param($v) ($null -ne $v) -and ($v -isnot [string]) -and (($v -is [System.Collections.IDictionary] -and $v.Contains('old') -and $v.Contains('new')) -or ($v -is [pscustomobject] -and $v.PSObject.Properties['old'] -and $v.PSObject.Properties['new'])) }
    $fmt = { param($v) if ($null -eq $v) { '(none)' } elseif ($v -is [string] -or $v -is [System.ValueType]) { [string]$v } else { $v | ConvertTo-Json -Compress -Depth 5 } }
    foreach ($p in $props) {
        if (& $isDiff $p.Value) {
            $lines += '{0}: {1} -> {2}' -f $p.Name, (& $fmt (Get-GIValue $p.Value 'old' $null)), (& $fmt (Get-GIValue $p.Value 'new' $null))
            continue
        }
        # one level of nesting, e.g. changes = @{ Key = @{ old; new } }
        $children = @()
        if ($p.Value -is [System.Collections.IDictionary]) {
            $children = $p.Value.Keys | ForEach-Object { [pscustomobject]@{ Name = [string]$_; Value = $p.Value[$_] } }
        } elseif ($p.Value -is [pscustomobject]) {
            $children = $p.Value.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } }
        }
        if ($children.Count -gt 0 -and @($children | Where-Object { & $isDiff $_.Value }).Count -eq $children.Count) {
            foreach ($c in $children) {
                $lines += '{0}: {1} -> {2}' -f $c.Name, (& $fmt (Get-GIValue $c.Value 'old' $null)), (& $fmt (Get-GIValue $c.Value 'new' $null))
            }
        } else {
            $lines += '{0}: {1}' -f $p.Name, (& $fmt $p.Value)
        }
    }
    ($lines | ForEach-Object { ConvertTo-GIHtml $_ }) -join '<br>'
}

function New-GIAuditPage {
    [CmdletBinding()]
    [OutputType([string])]
    param($Entries = @())
    $rows = foreach ($e in @($Entries | Where-Object { $_ })) {
        "<tr><td>$(Format-GIDate (Get-GIValue $e 'at'))</td><td>$(ConvertTo-GIHtml (Get-GIValue $e 'user'))</td><td>$(ConvertTo-GIHtml (Get-GIValue $e 'action'))</td><td>$(ConvertTo-GIHtml (Get-GIValue $e 'target'))</td><td><code>$(ConvertTo-GIAuditDetailHtml (Get-GIValue $e 'detail' $null))</code></td></tr>"
    }
    $body = '<h2>Audit log</h2><section class="card"><table><thead><tr><th>At</th><th>User</th><th>Action</th><th>Target</th><th>Detail</th></tr></thead><tbody>'
    if (-not $rows) { $body += '<tr><td colspan="5" class="muted">No audit entries.</td></tr>' } else { $body += ($rows -join '') }
    $body += '</tbody></table></section>'
    New-GIPage -Title 'Audit log' -BodyHtml $body
}

function New-GIRunActionsHtml {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Run, [string]$Token = '', [bool]$Busy = $false)
    $status = [string](Get-GIValue $Run 'status')
    $rid = ConvertTo-GIHtml (Get-GIValue $Run 'runId')
    $stage = ConvertTo-GIHtml (Get-GIValue $Run 'currentStage')
    $dis = ''
    $note = ''
    if ($Busy) { $dis = ' disabled'; $note = '<p class="muted">Disabled while the pipeline is busy.</p>' }
    $tok = Get-GITokenInput $Token
    if ($status -eq 'Failed' -and $stage) {
        return "<section class=""card""><h3>Actions</h3>$note<form method=""post"" action=""/run/start"">$tok<input type=""hidden"" name=""runId"" value=""$rid""><input type=""hidden"" name=""stage"" value=""$stage""><button type=""submit"" name=""action"" value=""FromStage""$dis>Retry from $stage</button> <button type=""submit"" name=""action"" value=""Stage"" class=""sec""$dis>Re-run $stage only</button></form></section>"
    }
    if ($status -eq 'Scheduled') {
        return "<section class=""card""><h3>Actions</h3>$note<form method=""post"" action=""/run/start"">$tok<input type=""hidden"" name=""runId"" value=""$rid""><button type=""submit"" name=""action"" value=""PostCheck""$dis>Run PostCheck now</button></form></section>"
    }
    ''
}
