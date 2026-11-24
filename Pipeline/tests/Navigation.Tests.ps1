BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'VDI-GIPipeline.psd1') -Force
    . (Join-Path $PSScriptRoot '..' 'Web' 'DashboardViews.ps1')
    . (Join-Path $PSScriptRoot '..' 'Web' 'SettingsViews.ps1')
    . (Join-Path $PSScriptRoot '..' 'Web' 'SetupViews.ps1')

    $script:schema = Get-GISettingsSchema
    $script:run = [pscustomobject]@{ runId = '20261124-120000'; status = 'Succeeded'; stages = @() }
    function script:Ctx($path = '/', $admin = $true, $setupMode = $false, $setupComplete = $true) {
        $global:GINavContext = @{ Path = $path; IsAdmin = $admin; IsApprover = $admin; SetupMode = $setupMode; SetupComplete = $setupComplete }
    }
    function script:NavItems([string]$Html) {
        # ordered list of 'label|href|disabled|active' for the top-level items and the settings children
        $nav = [regex]::Match($Html, '<nav class="sidenav".*?</nav>', 'Singleline').Value
        $out = foreach ($m in [regex]::Matches($nav, '<(?<tag>a|span) class="(?<cls>navitem|navchild)(?<rest>[^"]*)"(?<attrs>[^>]*)>(?:<svg.*?</svg>)?(?:<span class="label">)?(?<label>[^<]+)')) {
            $href = [regex]::Match($m.Groups['attrs'].Value, 'href="([^"]*)"').Groups[1].Value
            '{0}|{1}|{2}|{3}|{4}' -f $m.Groups['cls'].Value, $m.Groups['label'].Value, $href, ($m.Groups['rest'].Value -match 'disabled'), ($m.Groups['rest'].Value -match 'active')
        }
        $out
    }
    function script:Hrefs([string]$Html) {
        NavItems $Html | ForEach-Object { ($_ -split '\|')[1, 2] -join '|' }
    }
    function script:Pages {
        [ordered]@{
            list     = { New-GIRunListPage -Runs @($script:run) }
            detail   = { New-GIRunDetailPage -Run $script:run }
            pools    = { New-GIPoolsPage -LastKnownGood $null -Runs @($script:run) -TestPoolName 'TST' }
            notfound = { New-GINotFoundPage }
            settings = { New-GISettingsSectionPage -Schema $script:schema -SectionKey 'vCenter' -SectionData @{ Values = @{} } -Token 't' }
            runctl   = { New-GIRunControlPage -Runs @($script:run) -Lock $null -PendingRequest $null -Token 't' -Stages @('Preflight') -TestPool 'TST' -ProdPools @('PRD') -LastKnownGood '' }
            audit    = { New-GIAuditPage -Entries @() }
            setup    = { New-GISetupPage -State ([pscustomobject]@{ schemaVersion = 1; mode = $null; modeLocked = $false; options = [pscustomobject]@{ invalidCertAction = 'Warn' }; updatedAt = ''; steps = [pscustomobject]@{} }) -Token 't' }
        }
    }
}

AfterAll { Remove-Variable -Name GINavContext -Scope Global -ErrorAction SilentlyContinue }

Describe 'Side navigation' {
    AfterEach { Remove-Variable -Name GINavContext -Scope Global -ErrorAction SilentlyContinue }
    It 'has the same items in the same order on every page' {
        $expected = $null
        foreach ($kv in (Pages).GetEnumerator()) {
            Ctx '/' $true
            $html = & $kv.Value
            $h = @(Hrefs $html)
            $h.Count | Should -BeGreaterThan 7 -Because $kv.Key
            if ($null -eq $expected) { $expected = $h } else { ($h -join ';') | Should -Be ($expected -join ';') -Because $kv.Key }
        }
        ($expected | Select-Object -First 3) -join ';' | Should -Be 'Runs|/;Pools|/pools;Run control|/run'
        $expected | Should -Contain 'JSON API|/api/runs'
        $expected | Should -Contain 'vCenter|/settings/vCenter'
    }
    It 'disables admin items for a viewer, with a tooltip and no href' {
        Ctx '/' $false
        $html = New-GIRunListPage -Runs @()
        $items = @(NavItems $html)
        foreach ($l in 'Run control', 'Settings', 'Audit', 'Setup') { $items | Where-Object { $_ -like "navitem|$l|*" } | Should -Match '\|True\|' -Because $l }
        foreach ($l in 'Runs', 'Pools', 'JSON API') { $items | Where-Object { $_ -like "navitem|$l|*" } | Should -Match '\|False\|' -Because $l }
        $html | Should -Match 'class="navitem disabled" aria-disabled="true" title="Admins only"'
        $html | Should -Not -Match 'href="/run"'
        $html | Should -Not -Match 'href="/settings'
    }
    It 'enables every item for an admin' {
        Ctx '/' $true
        $items = @(NavItems (New-GIRunListPage -Runs @()))
        $items | Where-Object { $_ -match '\|True\|' } | Should -BeNullOrEmpty
    }
    It 'disables everything except Setup while setup is incomplete' {
        Ctx '/setup' $true $true $false
        $html = New-GIRunListPage -Runs @()
        $items = @(NavItems $html)
        ($items | Where-Object { $_ -match '^navitem\|.*\|False\|' }) -join ';' | Should -Match '^navitem\|Setup\|/setup\|False\|True$'
        @($items | Where-Object { $_ -match '^navitem\|.*\|False\|' }).Count | Should -Be 1
        $html | Should -Match 'title="Finish setup first"'
    }
    It 'behaves normally in setup mode once setup is complete' {
        Ctx '/' $true $true $true
        (NavItems (New-GIRunListPage -Runs @())) | Where-Object { $_ -match '\|True\|' -and $_ -notmatch '\|True$' } | Should -BeNullOrEmpty
        (NavItems (New-GIRunListPage -Runs @())) | Where-Object { $_ -match '^navitem\|.*\|True\|' } | Should -BeNullOrEmpty
    }
    It 'marks the active item' {
        Ctx '/' $true
        NavItems (New-GIRunListPage -Runs @()) | Where-Object { $_ -match '^navitem.*\|True$' } | Should -Be 'navitem|Runs|/|False|True'
        Ctx '/runs/20261124-120000' $true
        NavItems (New-GIRunDetailPage -Run $script:run) | Where-Object { $_ -match '^navitem.*\|True$' } | Should -Be 'navitem|Runs|/|False|True'
        Ctx '/pools' $true
        NavItems (New-GINotFoundPage) | Where-Object { $_ -match '^navitem.*\|True$' } | Should -Be 'navitem|Pools|/pools|False|True'
    }
    It 'marks Settings and the child section active and opens the group' {
        Ctx '/settings/Pools' $true
        $html = New-GISettingsSectionPage -Schema $script:schema -SectionKey 'Pools' -SectionData @{ Values = @{} } -Token 't'
        $items = @(NavItems $html)
        $items | Where-Object { $_ -match '^navitem.*\|True$' } | Should -Be 'navitem|Settings|/settings|False|True'
        $items | Where-Object { $_ -match '^navchild.*\|True$' } | Should -Match '^navchild\|[^|]+\|/settings/Pools\|False\|True$'
        $html | Should -Match '<details class="navsub" open>'
        Ctx '/' $true
        (New-GIRunListPage -Runs @()) | Should -Not -Match '<details class="navsub" open>'
    }
    It 'has no second settings sidemenu' {
        Ctx '/settings/vCenter' $true
        New-GISettingsSectionPage -Schema $script:schema -SectionKey 'vCenter' -SectionData @{ Values = @{} } -Token 't' | Should -Not -Match 'sidemenu'
    }
    It 'has the collapse and mobile toggle buttons and the storage script' {
        Ctx '/' $true
        $html = New-GIRunListPage -Runs @()
        $html | Should -Match '<button type="button" class="navcollapse" aria-expanded="true"'
        $html | Should -Match 'class="navtoggle-mobile" aria-controls="sidenav" aria-expanded="false"'
        $html | Should -Match 'giNavCollapsed'
    }
    It 'renders with admin items disabled when no context is set' {
        Remove-Variable -Name GINavContext -Scope Global -ErrorAction SilentlyContinue
        $items = @(NavItems (New-GINotFoundPage))
        $items | Where-Object { $_ -like 'navitem|Runs|*' } | Should -Match '\|False\|'
        $items | Where-Object { $_ -like 'navitem|Settings|*' } | Should -Match '\|True\|'
    }
    It 'leaves no Add-GIAdminNav or ShowAdminNav references' {
        $root = Join-Path $PSScriptRoot '..'
        $self = (Resolve-Path $PSCommandPath).Path
        $hits = Get-ChildItem -Path (Join-Path $root 'Web'), (Join-Path $root 'src') -Recurse -File |
            Select-String -Pattern 'Add-GIAdminNav|ShowAdminNav' | Where-Object { $_.Path -ne $self }
        $hits | Should -BeNullOrEmpty
    }
}
