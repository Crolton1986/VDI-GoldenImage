BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'Web' 'DashboardViews.ps1')
    . (Join-Path $PSScriptRoot '..' 'Web' 'Components.ps1')
    # Page-wide assertions below look at markup only, not the shared page script
    function Get-GIUiScript { '' }
    . (Join-Path $PSScriptRoot '..' 'Web' 'SettingsViews.ps1')

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
        $h | Should -Match 'name="AutoPromote" value="on">'
        $h | Should -Match 'name="confirm_AutoPromote"'
        $h | Should -Match 'Promotes without approval'
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
        $h | Should -Match 'id="pkg_VmTools" name="Actions" value="VmTools" checked'
        $h | Should -Not -Match 'value="MsTeams" checked'
    }
    It 'shows the host file and a status badge per package' {
        $h = Get-GIPackagesFieldHtml -Field $pf -Value @('VmTools', 'Horizon') -Installers $inst
        $h | Should -Match 'VMware-tools-12\.5\.0-x86_64\.exe'
        $h | Should -Match 'v12\.5\.0, 110\.2 MB, 2026-11-01'
        $h | Should -Match 'st-bad">Missing'
        $h | Should -Match 'st-pending">Missing'
        $h | Should -Match 'Downloads automatically'
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
        $h | Should -Match 'value="Horizon" checked'
        $h | Should -Match 'Installer on host'
    }
}

