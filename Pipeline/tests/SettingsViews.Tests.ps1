BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'Web' 'DashboardViews.ps1')
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
    It 'lists all sections and highlights the active one' {
        $h = New-GISettingsLayout -Schema $schema -ActiveSection 'Dashboard' -ContentHtml '<p>x</p>'
        $h | Should -Match 'href="/settings/vCenter"'
        $h | Should -Match 'href="/settings/Dashboard" class="active"'
        $h | Should -Not -Match 'href="/settings/vCenter" class="active"'
    }
}

Describe 'Settings section page' {
    It 'posts to the section with hidden token and admin nav' {
        $h = Page
        $h | Should -Match '<form method="post" action="/settings/vCenter" class="settings-form"><input type="hidden" name="token" value="tok123">'
        $h | Should -Match 'href="/settings"'
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
        $h | Should -Not -Match '\sdisabled[\s>]'
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

Describe 'Run control page' {
    BeforeAll {
        $script:runs = @(1..25 | ForEach-Object { [pscustomobject]@{ runId = ('20261101-0000{0:00}' -f $_); status = 'Succeeded' } })
        $script:stages = @('Preflight', 'Maintain', 'Validate')
        function script:RC($lock = $null, $pending = $null) {
            New-GIRunControlPage -Runs $script:runs -Lock $lock -PendingRequest $pending -Token 'tok' -Stages $script:stages -TestPool 'TST-W11' -ProdPools @('PRD-W11') -LastKnownGood 'GI-<lkg>'
        }
    }
    It 'is idle and enabled without a lock' {
        $h = RC
        $h | Should -Match '<strong>Idle</strong>'
        $h | Should -Not -Match '\sdisabled[\s>]'
        $h | Should -Match 'action="/run/start"'
        $h | Should -Match 'name="action" value="All"'
        $h | Should -Match 'No stop button|no stop button'
        $h | Should -Match 'VDI-GI-Runner'
    }
    It 'limits run list to newest 20' {
        $h = RC
        ([regex]::Matches($h, '<option value="20261101-')).Count | Should -Be 20
        $h | Should -Match '20261101-000025 \(Succeeded\)'
        $h | Should -Not -Match '20261101-000001 '
    }
    It 'is busy and disabled with an active lock' {
        $h = RC ([pscustomobject]@{ stage = 'Maintain'; runId = 'R<1>'; requestedBy = 'D\x'; startedAt = '2026-11-24T10:00:00'; stale = $false })
        $h | Should -Match '<strong>Busy</strong>'
        $h | Should -Match 'R&lt;1&gt;'
        $h | Should -Match '\sdisabled[\s>]'
        ([regex]::Matches($h, '<button type="submit"[^>]*disabled')).Count | Should -BeGreaterOrEqual 4
    }
    It 'is enabled with a stale lock' {
        $h = RC ([pscustomobject]@{ stage = 'Maintain'; runId = 'R1'; requestedBy = 'x'; startedAt = '2026-11-24T10:00:00'; stale = $true })
        $h | Should -Match 'Stale lock'
        $h | Should -Not -Match '\sdisabled[\s>]'
    }
    It 'shows queued request and disables' {
        $h = RC $null ([pscustomobject]@{ action = 'All'; requestedBy = 'x'; requestedAt = '2026-11-24T10:00:00' })
        $h | Should -Match 'Queued, waiting for the runner'
        $h | Should -Match 'action="/run/cancel-request"'
        $h | Should -Match 'Cancel queued request'
        $h | Should -Match '\sdisabled[\s>]'
    }
    It 'has modes and rollback form with confirmPool' {
        $h = RC
        $h | Should -Match 'name="action" value="FromStage"'
        $h | Should -Match 'name="action" value="Stage"'
        $h | Should -Match 'name="action" value="PostCheck"'
        $h | Should -Match 'action="/run/rollback"'
        $h | Should -Match 'name="confirmPool"'
        $h | Should -Match 'name="forceLogoff"'
        $h | Should -Match 'Ends active sessions on that pool'
        $h | Should -Match 'GI-&lt;lkg&gt;'
        $h | Should -Match '<option value="PRD-W11">'
        $h | Should -Match '<option value="TST-W11">'
    }
    It 'every form carries the token' {
        $h = RC
        ([regex]::Matches($h, '<form ')).Count | Should -Be ([regex]::Matches($h, 'name="token" value="tok"')).Count
    }
}

Describe 'Audit page' {
    It 'renders rows, diff lines and encodes' {
        $e = @(
            [pscustomobject]@{ at = '2026-11-24T10:00:00'; user = 'D\<a>'; action = 'settings.save'; target = 'vCenter'
                detail = [pscustomobject]@{ changes = [pscustomobject]@{ Server = [pscustomobject]@{ old = 'a'; new = 'b<c' } } } },
            @{ at = '2026-11-24T11:00:00'; user = 'u'; action = 'run.request'; target = 'All'; detail = @{ stage = 'Validate' } }
        )
        $h = New-GIAuditPage -Entries $e
        $h | Should -Match 'Server: a -&gt; b&lt;c'
        $h | Should -Match 'stage: Validate'
        $h | Should -Match 'D\\&lt;a&gt;'
        $h | Should -Match 'settings.save'
    }
    It 'handles empty' { (New-GIAuditPage -Entries @()) | Should -Match 'No audit entries' }
}

Describe 'Run actions' {
    It 'Failed shows retry and rerun' {
        $h = New-GIRunActionsHtml -Run ([pscustomobject]@{ runId = '20261124-213005'; status = 'Failed'; currentStage = 'Validate' }) -Token 'tk'
        $h | Should -Match 'Retry from Validate'
        $h | Should -Match 'Re-run Validate only'
        $h | Should -Match 'value="FromStage"'
        $h | Should -Match 'name="runId" value="20261124-213005"'
        $h | Should -Match 'name="token" value="tk"'
        $h | Should -Not -Match '\sdisabled[\s>]'
    }
    It 'Scheduled shows PostCheck' {
        (New-GIRunActionsHtml -Run ([pscustomobject]@{ runId = 'r'; status = 'Scheduled' }) -Token 't') | Should -Match 'value="PostCheck"'
    }
    It 'other statuses return empty' {
        (New-GIRunActionsHtml -Run ([pscustomobject]@{ runId = 'r'; status = 'Succeeded' }) -Token 't') | Should -Be ''
    }
    It 'disables when busy' {
        (New-GIRunActionsHtml -Run ([pscustomobject]@{ runId = 'r'; status = 'Failed'; currentStage = 'X' }) -Token 't' -Busy $true) | Should -Match '\sdisabled[\s>]'
    }
}
