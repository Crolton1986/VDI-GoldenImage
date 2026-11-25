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

function Get-GIPackagesFieldHtml {
    <# Checkbox table for the 'packages' field. $Installers is Get-GIInstallerStatus output; without it only the checkboxes render. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Field, $Value, $Installers = $null)
    $fk = [string]$Field.Key
    $selected = @(@($Value) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    $rowsByAction = @{}
    $showStatus = $null -ne $Installers
    if ($showStatus) { foreach ($p in @(Get-GIValue $Installers 'Packages' @())) { $rowsByAction[[string]$p.Action] = $p } }
    $head = '<tr><th scope="col">Maintain</th><th scope="col">Package</th>'
    if ($showStatus) { $head += '<th scope="col">Installer on host</th><th scope="col">Status</th>' }
    $head += '</tr>'
    $body = foreach ($action in @(Get-GIValue $Field 'ItemValues' @())) {
        $a = [string]$action
        $id = Get-GIHtmlId 'pkg' $a
        $chk = ''
        if ($selected -ccontains $a) { $chk = ' checked' }
        $info = if ($rowsByAction.ContainsKey($a)) { $rowsByAction[$a] } else { $null }
        $name = if ($info) { [string]$info.Name } else { $a }
        $row = "<tr><td><input type=""checkbox"" id=""$id"" name=""$(ConvertTo-GIHtml $fk)"" value=""$(ConvertTo-GIHtml $a)""$chk></td>"
        $row += "<td><label for=""$id"">$(ConvertTo-GIHtml $name)</label><div class=""help"">$(ConvertTo-GIHtml $a)$(if ($info) { " &middot; <code>$(ConvertTo-GIHtml $info.Mask)</code>" })</div></td>"
        if ($showStatus) {
            $file = '<span class="muted">-</span>'
            if ($info -and $info.File) {
                $meta = @()
                if ($info.Version) { $meta += "v$($info.Version)" }
                if ($null -ne $info.SizeMB) { $meta += "$($info.SizeMB) MB" }
                if ($info.Modified) { $meta += ([datetime]$info.Modified).ToString('yyyy-MM-dd') }
                $file = "<code>$(ConvertTo-GIHtml $info.File)</code><div class=""help"">$(ConvertTo-GIHtml ($meta -join ', '))</div>"
            }
            $state = if ($info) { [string]$info.State } else { 'NoFolder' }
            $badge = switch ($state) {
                'Found' { '<span class="badge st-ok">Found</span>' }
                'Download' { '<span class="badge st-sched">Downloads automatically</span>' }
                'Missing' {
                    if ($selected -ccontains $a) { '<span class="badge st-bad">Missing</span>' } else { '<span class="badge st-pending">Missing</span>' }
                }
                default { '<span class="badge st-skip">Not checked</span>' }
            }
            $row += "<td>$file</td><td>$badge</td>"
        }
        "$row</tr>"
    }
    $h = "<table class=""edit pkgs""><thead>$head</thead><tbody>$(@($body) -join '')</tbody></table>"
    if ($showStatus) {
        $folder = [string](Get-GIValue $Installers 'Folder' '')
        $ferr = Get-GIValue $Installers 'FolderError' $null
        if ($ferr) { $h += "<div class=""testres fail"" role=""status"">$(ConvertTo-GIHtml $ferr)</div>" }
        elseif ($folder) {
            $miss = @(@(Get-GIValue $Installers 'Packages' @()) | Where-Object { $_.Selected -and $_.State -eq 'Missing' })
            if ($miss.Count) { $h += "<div class=""testres fail"" role=""status"">$($miss.Count) ticked package(s) have no installer in $(ConvertTo-GIHtml $folder). Preflight will stop the run until you add them or untick them.</div>" }
            else { $h += "<div class=""help"">Checked $(ConvertTo-GIHtml $folder) just now.</div>" }
        } else {
            $h += '<div class="help">No installer folder set, so the pipeline can''t check installers. They must already be in the Install folder inside the golden VM.</div>'
        }
    }
    return $h
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
            $lab = ConvertTo-GIHtml ("$(Get-GIValue $c 'Label' $ck), row $($i + 1)")
            $extra = ' aria-label="' + $lab + '"'
            $ctl = Get-GIControlHtml -Field $c -Name ('{0}[{1}].{2}' -f $key, $i, $ck) -Value (Get-GIValue $row $ck) -IdPrefix 'c' -Extra $extra
            $cells += "<td>$ctl</td>"
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
    param([Parameter(Mandatory)]$Field, $Value, [Parameter(Mandatory)][string]$SectionKey, [string]$Token, [bool]$IsHttps, [string]$Action = '')
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
<form method="post" action="$(if ($Action) { ConvertTo-GIHtml $Action } else { '/settings/' + (ConvertTo-GIHtml $SectionKey) + '/credential' })" class="formbox cred" autocomplete="off">
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
        [bool]$IsHttps = $false,
        [string]$FormAction = '',          # default /settings/<section>
        [string]$TestAction = '',          # default /settings/<section>/test (global sections only)
        [string]$CredAction = '',          # default /settings/<section>/credential
        [switch]$Disabled,                 # Viewer and Approver: fields disabled, no save bar, no test or credential forms
        [switch]$BodyOnly,                 # return the section card for embedding in a page
        [string]$DescSuffix = ''
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
    if ($desc) { $h += "<p class=""muted"">$(ConvertTo-GIHtml $desc)$(if ($DescSuffix) { ' ' + (ConvertTo-GIHtml $DescSuffix) })</p>" }
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
 $formStart = $h.Length
        $act = if ($FormAction) { ConvertTo-GIHtml $FormAction } else { "/settings/$sk" }
        $h += "<form method=""post"" action=""$act"" class=""settings-form"" id=""settings-form""$(if (-not $Disabled) { ' data-savebar' })>$(Get-GITokenInput $Token)"
        foreach ($f in $fields) {
            $fk = [string]$f.Key
            $type = [string](Get-GIValue $f 'Type' 'string')
            if ($type -eq 'secret') {
                if (-not $Disabled) { $secretBlocks += Get-GISecretBlockHtml -Field $f -Value (Get-GIValue $values $fk $null) -SectionKey $SectionKey -Token $Token -IsHttps $IsHttps -Action $CredAction }
                else { $st = Get-GIValue (Get-GIValue $values $fk $null) 'IsSet' $false; $h += "<div class=""field""><div class=""lbl"">$(ConvertTo-GIHtml (Get-GIValue $f 'Label' $fk))</div><span class=""chip $(if ($st) { 'ok' } else { 'idle' })"">$(if ($st) { 'Saved' } else { 'Not set' })</span></div>" }
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
                'packages' {
                    $h += "<div class=""lbl"">$label</div>$(Get-GIPackagesFieldHtml -Field $f -Value $v -Installers (Get-GIValue $SectionData 'Installers' $null))"
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
        $h += '</form>'
        if ($Disabled) {
            $h = $h.Substring(0, $formStart) + ($h.Substring($formStart) -replace '<(input|select|textarea|button)(?![^>]*\bdisabled\b)([ >])', '<$1 disabled$2')
        } else { $h += New-GISaveBar -FormId 'settings-form' }
        $h += $secretBlocks
        if (@($fields | Where-Object { $_.Type -eq 'table' }).Count -gt 0) { $h += Get-GIAddRowScript }
    }

    if ((Get-GIValue $section 'Test' $null) -and -not $Disabled -and -not $FormAction -and -not $BodyOnly) {
        $h += "<h2>Test connection</h2><form method=""post"" action=""/settings/$sk/test"" class=""formbox"">$(Get-GITokenInput $Token)<button type=""submit"" class=""sec"">Test connection</button></form>"
        if ($null -ne $TestResult) {
            $ok = [bool](Get-GIValue $TestResult 'ok' $false)
            $cls = 'fail'
            $word = 'Failed'
            if ($ok) { $cls = 'ok'; $word = 'OK' }
            $h += "<div class=""testres $cls"" role=""status""><strong>$word</strong> $((ConvertTo-GIHtml ([string](Get-GIValue $TestResult 'detail'))) -replace "`r?`n", '<br>')</div>"
        }
    }

    if ($BodyOnly) { return "<section class=""card settings-main"">$h</section>" }
    New-GIPage -Title "Settings - $(Get-GIValue $section 'Title' $SectionKey)" -BodyHtml (New-GISettingsLayout -Schema $Schema -ActiveSection $SectionKey -ContentHtml $h)
}
