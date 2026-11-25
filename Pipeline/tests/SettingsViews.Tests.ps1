BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'Web' 'DashboardViews.ps1')
    . (Join-Path $PSScriptRoot '..' 'Web' 'Components.ps1')
    # Page-wide assertions below look at markup only, not the shared page script
    function Get-GIUiScript { '' }
    . (Join-Path $PSScriptRoot '..' 'Web' 'SettingsViews.ps1')
    . (Join-Path $PSScriptRoot '..' 'Web' 'AdminViews.ps1')

    $script:schema = [ordered]@{
        vCenter = @{
            Title = 'vCenter'; ConfigPath = 'vCenter'; Test = 'vCenter'; ReadOnly = $false; Description = 'vCenter connection.'
            Fields = @(
                @{ Key = 'Server'; Label = 'Server'; Type = 'string'; Required = $true; Help = 'FQDN of the VCSA' }
                @{ Key = 'WindowsUpdate.MaxPasses'; Label = 'Max passes'; Type = 'int'; Min = 1; Max = 9 }
                @{ Key = 'Enabled'; Label = 'Enabled'; Type = 'bool' }
                @{ Key = 'AutoPromote'; Label = 'Auto promote'; Type = 'bool'; Confirm = $true; Warning = 'Promotes without approval' }
                @{ Key = 'Hosts'; Label = 'Hosts'; Type = 'list' }
                @{ Key = 'Mode'; Label = 'Mode'; Type = 'enum'; Values = @('Wait', 'Force') }
                @{ Key = 'Days'; Label = 'Days'; Type = 'days' }
                @{ Key = 'Start'; Label = 'Start'; Type = 'time' }
                @{ Key = 'Pools'; Label = 'Pools'; Type = 'table'; Columns = @(
                        @{ Key = 'Name'; Label = 'Name'; Type = 'string' }
                        @{ Key = 'Policy'; Label = 'Policy'; Type = 'enum'; Values = @('WAIT', 'FORCE') }) }
                @{ Key = 'CredentialSecret'; Label = 'Credential'; Type = 'secret' }
            )
        }
        Dashboard = @{ Title = 'Dashboard'; ReadOnly = $true; Test = $null; Description = 'ro'
            Fields = @(@{ Key = 'Port'; Label = 'Port'; Type = 'int' }) }
    }
    $script:data = @{ Values = @{
            Server = '"<x>'; 'WindowsUpdate.MaxPasses' = 3; Enabled = $true; AutoPromote = $false
            Hosts = @('h1', 'h2'); Mode = 'Force'; Days = @('Monday', 'Friday'); Start = '22:30'
            Pools = @(@{ Name = 'PRD-1'; Policy = 'FORCE' })
            CredentialSecret = @{ Name = 'vc'; IsSet = $true; UserName = 'svc"<u>' }
        }
    }
    function script:Page($e = @{}, $https = $true, $test = $null, $key = 'vCenter') {
        New-GISettingsSectionPage -Schema $script:schema -SectionKey $key -SectionData $script:data -Errors $e -Token 'tok123' -IsHttps $https -TestResult $test
    }
}

Describe 'Settings layout' {
    It 'only wraps the content (sections live in the side nav)' {
        $h = New-GISettingsLayout -Schema $schema -ActiveSection 'Dashboard' -ContentHtml '<p>x</p>'
        $h | Should -Be '<div class="settings-main"><p>x</p></div>'
        $h | Should -Not -Match 'sidemenu'
    }
}

Describe 'Settings section page' {
    It 'posts to the section with hidden token' {
        $h = Page
        $h | Should -Match '<form method="post" action="/settings/vCenter" class="settings-form" id="settings-form" data-savebar><input type="hidden" name="token" value="tok123">'
    }
    It 'renders string and encodes values' {
        $h = Page
        $h | Should -Match 'name="Server" value="&quot;&lt;x&gt;"'
        $h | Should -Not -Match '"<x>'
    }
    It 'renders int with min/max and dotted name' {
        (Page) | Should -Match 'type="number" id="f_WindowsUpdate_MaxPasses" name="WindowsUpdate.MaxPasses" value="3" min="1" max="9"'
    }
    It 'renders bool checkbox, with confirm gate and warning' {
        $h = Page
        $h | Should -Match 'name="Enabled" value="on" checked'
        $h | Should -Match 'name="AutoPromote" value="on" data-confirm-dialog="dlg-confirm-f_AutoPromote">'
        $h | Should -Match 'name="confirm_AutoPromote"'   # the no-JS fallback stays in the page
        $h | Should -Match 'Promotes without approval'
        $h | Should -Match '<div class="confirmbox">'
        $h | Should -Match 'id="dlg-confirm-f_AutoPromote".*?Change Auto promote\?.*?Promotes without approval.*?data-confirm data-confirm-yes'
    }
    It 'renders list textarea one per line' { (Page) | Should -Match '(?s)<textarea[^>]*name="Hosts"[^>]*>h1\nh2</textarea>' }
    It 'renders enum select with selection' { (Page) | Should -Match '<option value="Force" selected>' }
    It 'renders days checkboxes' {
        $h = Page
        ([regex]::Matches($h, 'name="Days" value="')).Count | Should -Be 7
        $h | Should -Match 'name="Days" value="Monday" checked'
        $h | Should -Not -Match 'name="Days" value="Tuesday" checked'
    }
    It 'renders time input' { (Page) | Should -Match 'type="time" id="f_Start" name="Start" value="22:30"' }
    It 'renders table rows with 2 blanks, remove boxes and add button' {
        $h = Page
        $h | Should -Match 'name="Pools\[0\]\.Name" value="PRD-1"'
        $h | Should -Match 'name="Pools\[2\]\.Name" value=""'
        $h | Should -Not -Match 'name="Pools\[3\]'
        $h | Should -Match 'name="Pools\[0\]\._remove"'
        $h | Should -Match 'gi-addrow'
        $h | Should -Match '<option value="FORCE" selected>'
    }
    It 'shows field errors inline and a summary' {
        $h = Page @{ Server = 'bad <host>' }
        $h | Should -Match 'class="err ferr"[^>]*>bad &lt;host&gt;'
        $h | Should -Match 'class="errsum"'
    }
    It 'renders help text' { (Page) | Should -Match 'FQDN of the VCSA' }
    It 'puts the secret block outside the main form and never renders a password' {
        $h = Page
        $mainEnd = $h.IndexOf('</form>')
        $cred = $h.IndexOf('action="/settings/vCenter/credential"')
        $cred | Should -BeGreaterThan $mainEnd
        $h | Should -Match 'name="key" value="CredentialSecret"'
        $h | Should -Match 'type="password"[^>]*value=""[^>]*autocomplete="new-password"'
        $h | Should -Match 'name="username" value="svc&quot;&lt;u&gt;"'
        $h | Should -Match 'badge st-ok">set<'
        # The save bar starts with disabled buttons (nothing changed yet); no form field or credential control is disabled
        ($h -replace '(?s)<div class="savebar".*?</div></div>', '') | Should -Not -Match '\sdisabled[\s>]'
    }
    It 'disables credential entry when not https' {
        $h = Page -https $false
        $h | Should -Match 'Credentials can only be entered over https'
        $h | Should -Match 'type="password"[^>]*disabled'
    }
    It 'ReadOnly section has no form' {
        $h = New-GISettingsSectionPage -Schema $schema -SectionKey 'Dashboard' -SectionData @{ Values = @{ Port = 8443 } } -Token 't'
        $h | Should -Not -Match '<form'
        $h | Should -Match 'Edit pipeline.config.psd1 on the server and restart the dashboard'
        $h | Should -Match '<dd>8443</dd>'
    }
    It 'shows Test button only when Test is set, with result' {
        $h = Page -test @{ ok = $true; detail = 'conn <ok>' }
        $h | Should -Match 'action="/settings/vCenter/test"'
        $h | Should -Match 'testres ok'
        $h | Should -Match 'conn &lt;ok&gt;'
        (Page -test @{ ok = $false; detail = 'nope' }) | Should -Match 'testres fail'
        $ro = New-GISettingsSectionPage -Schema $schema -SectionKey 'Dashboard' -SectionData @{ Values = @{} } -Token 't'
        $ro | Should -Not -Match '/test'
    }
    It 'shows notice' {
        $h = New-GISettingsSectionPage -Schema $schema -SectionKey 'vCenter' -SectionData $data -Token 't' -Notice 'Saved <1>'
        $h | Should -Match 'Saved &lt;1&gt;'
    }
}

Describe 'Packages field' {
    BeforeAll {
        $script:pf = @{ Key = 'Actions'; Label = 'Maintained packages'; Type = 'packages'; ItemValues = @('VmTools', 'Horizon', 'MsTeams', 'DEM') }
        $script:inst = [pscustomobject]@{ Folder = 'D:\Inst'; FolderError = $null; Packages = @(
                [pscustomobject]@{ Action = 'VmTools'; Name = 'VMware Tools'; Mask = 'VMware-tools-*64.exe'; Selected = $true; State = 'Found'; File = 'VMware-tools-12.5.0-x86_64.exe'; Version = '12.5.0'; SizeMB = 110.2; Modified = [datetime]'2026-11-01' }
                [pscustomobject]@{ Action = 'Horizon'; Name = 'Horizon Agent'; Mask = '*Horizon-Agent-x86_64-*.exe'; Selected = $true; State = 'Missing'; File = ''; Version = ''; SizeMB = $null; Modified = $null }
                [pscustomobject]@{ Action = 'MsTeams'; Name = 'Microsoft Teams for VDI'; Mask = 'teamsbootstrapper.exe'; Selected = $false; State = 'Download'; File = ''; Version = ''; SizeMB = $null; Modified = $null }
                [pscustomobject]@{ Action = 'DEM'; Name = 'Dynamic Environment Manager'; Mask = '*.msi'; Selected = $false; State = 'Missing'; File = ''; Version = ''; SizeMB = $null; Modified = $null }
            ) }
    }
    It 'ticks the selected packages, one checkbox per package, all named after the field' {
        $h = Get-GIPackagesFieldHtml -Field $pf -Value @('VmTools', 'Horizon') -Installers $inst
        ([regex]::Matches($h, 'type="checkbox" id="pkg_\w+" name="Actions"')).Count | Should -Be 4
        $h | Should -Match 'id="pkg_VmTools" name="Actions" value="VmTools" data-pkg-name="VMware Tools" checked'
        $h | Should -Not -Match 'value="MsTeams" checked'
    }
    It 'shows the host file and a status badge per package' {
        $h = Get-GIPackagesFieldHtml -Field $pf -Value @('VmTools', 'Horizon') -Installers $inst
        $h | Should -Match 'VMware-tools-12\.5\.0-x86_64\.exe'
        $h | Should -Match 'v12\.5\.0, 110\.2 MB, 2026-11-01'
        $h | Should -Match 'chip bad">Missing'
        $h | Should -Match 'chip idle">Missing'
        $h | Should -Match 'chip ok">Found'
        $h | Should -Match 'chip idle">Downloads automatically'
        $h | Should -Match '1 ticked package\(s\) have no installer'
    }
    It 'renders only checkboxes without installer data' {
        $h = Get-GIPackagesFieldHtml -Field $pf -Value @('VmTools')
        $h | Should -Not -Match 'Installer on host'
        $h | Should -Not -Match 'badge'
    }
    It 'explains when no installer folder is set' {
        $noFolder = [pscustomobject]@{ Folder = ''; FolderError = $null; Packages = @() }
        Get-GIPackagesFieldHtml -Field $pf -Value @() -Installers $noFolder | Should -Match 'No installer folder set'
    }
    It 'is rendered by the section page from SectionData.Installers' {
        $sch = [ordered]@{ Packages = @{ Title = 'Packages'; ConfigPath = 'GoldenImage'; Test = $null; ReadOnly = $false; Fields = @($pf) } }
        $h = New-GISettingsSectionPage -Schema $sch -SectionKey 'Packages' -SectionData @{ Values = @{ Actions = @('Horizon') }; Installers = $inst } -Token 't'
        $h | Should -Match 'value="Horizon" data-pkg-name="Horizon Agent" checked'
        $h | Should -Match 'Installer on host'
    }
    It 'says how many steps the ticked packages add, and updates the line when one is ticked' {
        $h = Get-GIPackagesFieldHtml -Field $pf -Value @('VmTools', 'Horizon') -Installers $inst
        $h | Should -Match 'id="pkg-steps" role="status" aria-live="polite">2 packages ticked: the run gets 2 install steps after Windows Update\.'
        $h | Should -Match "Ticking '\+nm\+' adds 1 step \(Install '\+nm\+'\)"
        (Get-GIPackageStepsText -Count 1) | Should -Be '1 package ticked: the run gets 1 install step after Windows Update.'
        (Get-GIPackageStepsText -Count 0) | Should -Match '^No packages ticked'
    }
    It 'offers Check again only when it knows where the page lives, and encodes the link' {
        (Get-GIPackagesFieldHtml -Field $pf -Value @() -Installers $inst -RecheckHref '/images/a"b/settings/Packages') | Should -Match '<a class="linkbtn" href="/images/a&quot;b/settings/Packages">Check again</a>'
        (Get-GIPackagesFieldHtml -Field $pf -Value @() -Installers $inst) | Should -Not -Match 'Check again'
        (Get-GIPackagesFieldHtml -Field $pf -Value @()) | Should -Not -Match 'Check again'
        $sch = [ordered]@{ Packages = @{ Title = 'Packages'; ConfigPath = 'GoldenImage'; Test = $null; ReadOnly = $false; Fields = @($pf) } }
        (New-GISettingsSectionPage -Schema $sch -SectionKey 'Packages' -SectionData @{ Values = @{ Actions = @() }; Installers = $inst } -FormAction '/images/w11/settings/Packages' -BodyOnly) | Should -Match 'href="/images/w11/settings/Packages">Check again'
    }
}


Describe 'Inventory pickers (gap 9)' {
    BeforeAll {
        $script:isch = [ordered]@{ GoldenImage = @{ Title = 'Guest VM'; ConfigPath = 'GoldenImage'; Test = 'GoldenImage'; ReadOnly = $false; Fields = @(
                    @{ Key = 'VmName'; Label = 'VM name'; Type = 'string'; Inventory = 'vms' }
                    @{ Key = 'Prod'; Label = 'Production'; Type = 'table'; Columns = @(@{ Key = 'Name'; Label = 'Pool name'; Type = 'string'; Inventory = 'pools' }, @{ Key = 'Policy'; Label = 'Policy'; Type = 'string' }) }) } }
        $script:idata = @{ Values = @{ VmName = 'GI-<W11>'; Prod = @(@{ Name = 'PRD-1'; Policy = 'x' }) } }
    }
    It 'keeps the text input as the field and adds a hidden select next to it (typed fallback)' {
        $h = New-GISettingsSectionPage -Schema $isch -SectionKey GoldenImage -SectionData $idata -Token t -BodyOnly -ImageName 'Win11 "A"'
        $h | Should -Match '<input type="text" id="f_VmName" name="VmName" value="GI-&lt;W11&gt;" data-inv="vms"><select class="invpick" data-inv-pick="vms" hidden aria-label="VM name, choose from vCenter">'
        $h | Should -Match 'name="Prod\[0\]\.Name" value="PRD-1"[^>]*data-inv="pools"><select class="invpick" data-inv-pick="pools" hidden'
        ([regex]::Matches($h, 'data-inv-pick="pools"')).Count | Should -Be 3   # one per table row, two of them blank
        $h | Should -Match 'data-image-name="Win11 &quot;A&quot;"'
        $h | Should -Match 'id="inv-status" role="status" aria-live="polite"'
        $h | Should -Match "fetch|getJson\('/api/inventory'\)"
        $h | Should -Match 'op\.disabled=true|\{op\.disabled=true\}'
    }
    It 'adds no picker script for a section without inventory fields, nor for a read-only (Viewer) page' {
        (New-GISettingsSectionPage -Schema $schema -SectionKey vCenter -SectionData $data -Token t -BodyOnly) | Should -Not -Match 'inv-status'
        (New-GISettingsSectionPage -Schema $isch -SectionKey GoldenImage -SectionData $idata -Token t -BodyOnly -Disabled) | Should -Not -Match 'getJson\('
    }
    It 'uses no external script or hex colour' {
        $h = New-GISettingsSectionPage -Schema $isch -SectionKey GoldenImage -SectionData $idata -Token t -BodyOnly
        $h | Should -Not -Match '<script[^>]+src='
        $h | Should -Not -Match '#[0-9a-fA-F]{6}\b'
    }
}

Describe 'Advanced group and connection chip (gap 10)' {
    BeforeAll {
        $script:asch = [ordered]@{ AppVolumes = @{ Title = 'App Volumes'; ConfigPath = 'AppVolumes'; Test = 'AppVolumes'; ReadOnly = $false; Fields = @(
                    @{ Key = 'Server'; Label = 'Manager'; Type = 'string' }
                    @{ Key = 'Endpoints.Session'; Label = 'Session endpoint'; Type = 'string'; Pattern = '^/'; Group = 'Advanced' }
                    @{ Key = 'Endpoints.Attachments'; Label = 'Attachments endpoint'; Type = 'string'; Group = 'Advanced' }) } }
        $script:adata = @{ Values = @{ Server = 'av1'; 'Endpoints.Session' = '/a'; 'Endpoints.Attachments' = '/b' } }
    }
    It 'collapses grouped fields into one closed details block after the other fields' {
        $h = New-GISettingsSectionPage -Schema $asch -SectionKey AppVolumes -SectionData $adata -Token t -BodyOnly
        $h | Should -Match '<details class="advanced"><summary>Advanced</summary>.*Session endpoint.*Attachments endpoint.*</details></form>'
        ([regex]::Matches($h, '<details')).Count | Should -Be 1
        $h.IndexOf('Manager') | Should -BeLessThan $h.IndexOf('<details')
        $h.IndexOf('Session endpoint') | Should -BeGreaterThan $h.IndexOf('<details')
    }
    It 'opens the group when one of its fields has an error' {
        $h = New-GISettingsSectionPage -Schema $asch -SectionKey AppVolumes -SectionData $adata -Token t -BodyOnly -Errors @{ 'Endpoints.Session' = 'Must start with /' }
        $h | Should -Match '<details class="advanced" open>'
        $h | Should -Match 'Must start with /'
    }
    It 'shows the connection state beside the title in words' {
        (New-GIConnectionChipHtml -State NotTested) | Should -Match 'chip idle" data-conn-chip>Not tested</span>'
        (New-GIConnectionChipHtml -State Connected -At '2026-11-25T10:30:00+00:00') | Should -Match 'chip ok" data-conn-chip>Connected</span>.*Tested 2026-11-25'
        (New-GIConnectionChipHtml -State Failed -At 'garbage') | Should -Match 'chip bad" data-conn-chip>Failed</span> <span class="muted small" data-conn-time></span>'
        $h = New-GISettingsSectionPage -Schema $asch -SectionKey AppVolumes -SectionData $adata -Token t -BodyOnly -StatusHtml (New-GIConnectionChipHtml -State NotTested)
        $h | Should -Match '<h2>App Volumes <span class="conn">'
    }
    It 'points the test button at the image endpoint when given an image id, and escapes it' {
        (New-GITestConnectionCard -Section Pools -ImageId 'w11-gi-01') | Should -Match 'data-test-section="Pools" data-test-url="/api/images/w11-gi-01/settings/Pools/test"'
        (New-GITestConnectionCard -Section vCenter) | Should -Not -Match 'data-test-url'
        (Get-Content (Join-Path $PSScriptRoot '..' 'Web' 'Components.ps1') -Raw) | Should -Match "getAttribute\('data-test-url'\)"
    }
}

Describe 'Confirm dialog script (gap 11)' {
    BeforeAll { $script:ui = Get-Content (Join-Path $PSScriptRoot '..' 'Web' 'Components.ps1') -Raw }
    It 'asks in a dialog when a confirm checkbox changes, ticks the hidden box and submits' {
        $ui | Should -Match "input\[data-confirm-dialog\]"
        $ui | Should -Match "e\.preventDefault\(\);var bd=d\.getElementById\(c\.getAttribute\('data-confirm-dialog'\)\)"
        $ui | Should -Match "cf\.checked=true"
        $ui | Should -Match "f\.requestSubmit"
        $ui | Should -Match "\.confirmbox'\)\.forEach\(function\(x\)\{x\.hidden=true\}"
    }
    It 'has no external script and no hex colour' {
        $ui | Should -Not -Match '<script[^>]+src='
        (($ui -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n") | Should -Not -Match '#[0-9a-fA-F]{6}\b'
    }
}
