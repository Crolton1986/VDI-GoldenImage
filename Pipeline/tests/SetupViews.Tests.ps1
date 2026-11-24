BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'Web' 'DashboardViews.ps1')
    . (Join-Path $PSScriptRoot '..' 'Web' 'SettingsViews.ps1')
    . (Join-Path $PSScriptRoot '..' 'Web' 'SetupViews.ps1')

    function script:New-State {
        param([hashtable]$Status = @{}, [hashtable]$Extra = @{}, [bool]$Locked = $false)
        $o = [ordered]@{ schemaVersion = 1; mode = $null; modeLocked = $Locked; options = @{ invalidCertAction = 'Warn' }; updatedAt = '2026-01-01T10:00:00.0000000Z'; steps = [ordered]@{} }
        foreach ($n in 'Mode', 'Prerequisites', 'Modules', 'PowerCLI', 'Vault', 'DashboardAccess', 'Tasks', 'Finish') {
            $s = 'pending'
            if ($Status.ContainsKey($n)) { $s = $Status[$n] }
            $step = [ordered]@{ status = $s; message = ''; detail = @(); data = @{} }
            if ($Extra.ContainsKey($n)) { foreach ($k in $Extra[$n].Keys) { $step[$k] = $Extra[$n][$k] } }
            $o.steps[$n] = $step
        }
        ($o | ConvertTo-Json -Depth 8) | ConvertFrom-Json
    }
    $script:certs = @(
        @{ Thumbprint = 'AB12CD'; Subject = 'CN=dash.example.com'; NotAfter = [datetime]'2027-03-04' }
        @{ Thumbprint = 'EF34'; Subject = 'CN=<script>alert(1)</script>'; NotAfter = [datetime]'2027-05-06' })
    $script:tasks = @(@{ Name = 'GI-Nightly'; Description = 'Runs the pipeline'; Trigger = @{ Type = 'Weekly'; Day = 'Sunday'; Time = '22:00' } })
}

Describe 'New-GISetupPage' {
    It 'renders title and all 8 step cards in order' {
        $html = New-GISetupPage -State (New-State) -Token 't'
        $html | Should -Match 'Set up the golden image pipeline'
        $pos = foreach ($n in 'Mode', 'Prerequisites', 'Modules', 'PowerCLI', 'Vault', 'DashboardAccess', 'Tasks', 'Finish') { $html.IndexOf("id=""step-$n""") }
        @($pos | Where-Object { $_ -ge 0 }).Count | Should -Be 8
        ($pos | Sort-Object) -join ',' | Should -Be ($pos -join ',')
    }
    It 'gives only the active step a form and later steps a waits note' {
        $html = New-GISetupPage -State (New-State -Status @{ Mode = 'done'; Prerequisites = 'done' }) -Token 'tok'
        ([regex]::Matches($html, '<form ')).Count | Should -Be 1
        $html | Should -Match 'action="/setup/Modules"'
        $html | Should -Match 'name="token" value="tok"'
        $html | Should -Match 'waits for step 3'
    }
    It 'shows the mode form with explanations and cert action select' {
        $html = New-GISetupPage -State (New-State) -Token 't'
        $html | Should -Match 'value="Production"'
        $html | Should -Match 'value="Lab"'
        $html | Should -Match 'name="invalidCertAction"'
        $html | Should -Match "When vCenter/Horizon certificates aren't trusted"
    }
    It 'shows Lab-only form when mode is locked' {
        $html = New-GISetupPage -State (New-State -Locked $true) -Token 't'
        $html | Should -Match 'Lab mode \(started with -LocalAdmin\)'
        $html | Should -Match 'type="hidden" name="mode" value="Lab"'
        $html | Should -Not -Match 'value="Production"'
        $html | Should -Match 'Continue'
    }
    It 'polls and disables forms while a step runs' {
        $st = New-State -Status @{ Mode = 'done'; Prerequisites = 'done'; Modules = 'running' } -Extra @{ Modules = @{ detail = @('Installing Pode') } }
        $html = New-GISetupPage -State $st -Token 't'
        $html | Should -Match '/setup/status'
        $html | Should -Match '2000'
        $html | Should -Match '<body data-version="2026-01-01T10:00:00.0000000Z">'
        $html | Should -Match '<noscript><meta http-equiv="refresh" content="3"></noscript>'
        $html | Should -Match '<fieldset disabled>'
        $html | Should -Match 'class="spinner"'
        $html | Should -Match '<details open>'
    }
    It 'has no polling when idle' {
        $html = New-GISetupPage -State (New-State -Status @{ Mode = 'done' }) -Token 't'
        $html | Should -Not -Match '/setup/status'
        $html | Should -Not -Match 'http-equiv="refresh"'
        $html | Should -Not -Match '<fieldset disabled>'
    }
    It 'shows Retry, message and detail lines for a failed step' {
        $st = New-State -Status @{ Mode = 'done'; Prerequisites = 'failed' } -Extra @{ Prerequisites = @{ message = 'No admin'; detail = @('line one', '<script>x()</script>') } }
        $html = New-GISetupPage -State $st -Token 't'
        $html | Should -Match 'Retry'
        $html | Should -Match 'No admin'
        $html | Should -Match 'line one'
        $html | Should -Match '&lt;script&gt;x\(\)&lt;/script&gt;'
        $html | Should -Not -Match '<script>x\(\)'
    }
    It 'keeps only the last 15 detail lines' {
        $lines = 1..20 | ForEach-Object { "row-$_-end" }
        $html = New-GISetupPage -State (New-State -Status @{ Mode = 'done'; Prerequisites = 'failed' } -Extra @{ Prerequisites = @{ detail = $lines } }) -Token 't'
        $html | Should -Not -Match 'row-5-end'
        $html | Should -Match 'row-6-end'
        $html | Should -Match 'row-20-end'
    }
    It 'renders the Modules table' {
        $items = @(@{ name = 'Pode'; required = '2.10.0'; installed = '2.14.2'; status = 'ok' }, @{ name = 'Pester'; required = '5.5.0'; installed = ''; status = 'missing' })
        $st = New-State -Status @{ Mode = 'done'; Prerequisites = 'done'; Modules = 'failed' } -Extra @{ Modules = @{ data = @{ items = $items } } }
        $html = New-GISetupPage -State $st -Token 't'
        $html | Should -Match '<td>Pode</td><td>2.10.0</td><td>2.14.2</td><td><span class="badge st-ok">ok</span></td>'
        $html | Should -Match '<td>Pester</td>'
        $html | Should -Match 'missing'
    }
    It 'warns on the Vault card' {
        $st = New-State -Status @{ Mode = 'done'; Prerequisites = 'done'; Modules = 'done'; PowerCLI = 'done' }
        $html = New-GISetupPage -State $st -Token 't' -CurrentUser 'CORP\bob<x>'
        $html | Should -Match 'open without a password for this Windows user'
        $html | Should -Match 'CORP\\bob&lt;x&gt;'
    }
    It 'renders the DashboardAccess form with certificates (encoded) and self-signed option' {
        $st = New-State -Status @{ Mode = 'done'; Prerequisites = 'done'; Modules = 'done'; PowerCLI = 'done'; Vault = 'done' }
        $html = New-GISetupPage -State $st -Token 't' -Certificates $script:certs
        $html | Should -Match 'name="port" value="8443"'
        $html | Should -Match 'value="AB12CD">CN=dash.example.com \(expires 2027-03-04\) - AB12CD'
        $html | Should -Match 'value="__selfsigned__">Create a self-signed certificate for this server \(browsers will warn\)'
        $html | Should -Match 'CN=&lt;script&gt;alert\(1\)&lt;/script&gt;'
        $html | Should -Not -Match '<script>alert'
        $html | Should -Match 'name="viewerGroup"'
        $html | Should -Match 'name="approverGroup"'
        $html | Should -Match 'name="adminGroup"'
        $html | Should -Match 'DOMAIN\\VDI-Pipeline-Viewers'
        $html | Should -Match 'Groups are checked in Active Directory before saving'
    }
    It 'renders the Tasks form with a separate skip form' {
        $st = New-State -Status @{ Mode = 'done'; Prerequisites = 'done'; Modules = 'done'; PowerCLI = 'done'; Vault = 'done'; DashboardAccess = 'done' }
        $html = New-GISetupPage -State $st -Token 't' -TaskDefinitions $script:tasks -CurrentUser 'CORP\bob'
        $html | Should -Match 'GI-Nightly'
        $html | Should -Match 'Runs the pipeline'
        $html | Should -Match 'Weekly Sunday 22:00'
        $html | Should -Match 'type="password"[^>]*autocomplete="current-password"'
        $html | Should -Match 'value="CORP\\bob" readonly'
        $html | Should -Match 'name="action" value="register"'
        ([regex]::Matches($html, 'action="/setup/Tasks"')).Count | Should -Be 2
        $html | Should -Match 'name="action" value="skip"'
        $html | Should -Match 'Skip \(leave Task Scheduler untouched\)'
    }
    It 'renders the Finish button' {
        $st = New-State -Status @{ Mode = 'done'; Prerequisites = 'done'; Modules = 'done'; PowerCLI = 'done'; Vault = 'done'; DashboardAccess = 'skipped'; Tasks = 'skipped' }
        (New-GISetupPage -State $st -Token 't') | Should -Match 'Finish setup'
    }
    It 'encodes notice and token' {
        $html = New-GISetupPage -State (New-State) -Token 'a"b' -Notice '<b>hi</b>'
        $html | Should -Match '&lt;b&gt;hi&lt;/b&gt;'
        $html | Should -Match 'value="a&quot;b"'
    }
    It 'shows the completion banner and no forms when complete and read-only' {
        $all = @{}
        foreach ($n in 'Mode', 'Prerequisites', 'Modules', 'PowerCLI', 'Vault', 'DashboardAccess', 'Tasks', 'Finish') { $all[$n] = 'done' }
        $html = New-GISetupPage -State (New-State -Status $all) -Token 't' -IsComplete $true -ReadOnly $true
        $html | Should -Match 'Setup is complete\.'
        $html | Should -Match 'href="/settings"'
        $html | Should -Match 'href="/"'
        $html | Should -Match 'Start-GIPipeline\.ps1 -ResetSetup'
        $html | Should -Not -Match '<form'
    }
    It 'shows no forms on a read-only incomplete page' {
        $html = New-GISetupPage -State (New-State) -Token 't' -ReadOnly $true
        $html | Should -Not -Match '<form'
    }
}

Describe 'New-GISetupStatusJson' {
    It 'returns compact JSON with version, running and steps' {
        $st = New-State -Status @{ Mode = 'done'; Prerequisites = 'running' }
        $j = New-GISetupStatusJson -State $st
        $j | Should -Not -Match "`n"
        $o = $j | ConvertFrom-Json
        $j | Should -Match '"version":"2026-01-01T10:00:00.0000000Z"'
        $o.running | Should -Be 'Prerequisites'
        $o.steps.Mode | Should -Be 'done'
        @($o.steps.PSObject.Properties).Count | Should -Be 8
    }
    It 'reports running null when idle and falls back to a hash version' {
        $st = New-State
        $st.PSObject.Properties.Remove('updatedAt')
        $o = New-GISetupStatusJson -State $st | ConvertFrom-Json
        $o.running | Should -BeNullOrEmpty
        $o.version | Should -Match '^[0-9a-f]{16}$'
    }
}
