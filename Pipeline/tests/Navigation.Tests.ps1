BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'VDI-GIPipeline.psd1') -Force
    . (Join-Path $PSScriptRoot '..' 'Web' 'DashboardViews.ps1')
    . (Join-Path $PSScriptRoot '..' 'Web' 'Components.ps1')
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
            $h = @(Hrefs (& $kv.Value))
            if ($null -eq $expected) { $expected = $h } else { ($h -join ';') | Should -Be ($expected -join ';') -Because $kv.Key }
        }
        $expected -join ';' | Should -Be 'Golden images|/;Audit log|/audit;Global settings|/settings;Setup|/setup;JSON API|/api/runs'
    }
    It 'has no Runs item and no settings children' {
        Ctx '/' $true
        $html = New-GIRunListPage -Runs @()
        (NavItems $html) -join ';' | Should -Not -CMatch 'navitem\|Runs\|'
        $html | Should -Not -Match 'navchild'
        $html | Should -Match '<hr class="navdivider">'
    }
    It 'hides Setup and disables Global settings for a viewer' {
        Ctx '/' $false
        $html = New-GIRunListPage -Runs @()
        $items = @(NavItems $html)
        $items | Where-Object { $_ -like '*|Setup|*' } | Should -BeNullOrEmpty
        $items | Where-Object { $_ -like 'navitem|Global settings|*' } | Should -Match '\|True\|'
        foreach ($l in 'Golden images', 'Audit log', 'JSON API') { $items | Where-Object { $_ -like "navitem|$l|*" } | Should -Match '\|False\|' -Because $l }
        $html | Should -Not -Match 'href="/setup"'
    }
    It 'enables every item for an admin' {
        Ctx '/' $true
        @(NavItems (New-GIRunListPage -Runs @())) | Where-Object { $_ -match '\|True\|' } | Should -BeNullOrEmpty
    }
    It 'disables everything except Setup while setup is incomplete' {
        Ctx '/setup' $true $true $false
        $html = New-GIRunListPage -Runs @()
        $enabled = @(NavItems $html | Where-Object { $_ -match '^navitem\|.*\|False\|' })
        $enabled.Count | Should -Be 1
        $enabled[0] | Should -Match '^navitem\|Setup\|/setup\|False\|True$'
        $html | Should -Match 'title="Finish setup first"'
    }
    It 'behaves normally in setup mode once setup is complete' {
        Ctx '/' $true $true $true
        @(NavItems (New-GIRunListPage -Runs @())) | Where-Object { $_ -match '^navitem\|.*\|True\|' } | Should -BeNullOrEmpty
    }
    It 'marks the active item' {
        Ctx '/' $true
        NavItems (New-GIRunListPage -Runs @()) | Where-Object { $_ -match '^navitem.*\|True$' } | Should -Be 'navitem|Golden images|/|False|True'
        Ctx '/runs/20261124-120000' $true
        NavItems (New-GIRunDetailPage -Run $script:run) | Where-Object { $_ -match '^navitem.*\|True$' } | Should -Be 'navitem|Golden images|/|False|True'
        Ctx '/settings/Pools' $true
        NavItems (New-GINotFoundPage) | Where-Object { $_ -match '^navitem.*\|True$' } | Should -Be 'navitem|Global settings|/settings|False|True'
    }
    It 'shows the user name and role badge in the top bar' {
        $global:GINavContext = @{ Path = '/'; IsAdmin = $false; IsApprover = $true; UserName = 'LAB\approver1'; Role = 'Approver'; SetupMode = $false; SetupComplete = $true }
        $html = New-GIRunListPage -Runs @()
        $html | Should -Match '<span>LAB\\approver1</span><span class="rolepill">Approver</span>'
        $html | Should -Match '<div class="apptitle">VDI Golden Image Pipeline</div>'
    }
    It 'has landmarks, a skip link and a live region' {
        Ctx '/' $true
        $html = New-GIRunListPage -Runs @()
        $html | Should -Match '<header class="topbar">'
        $html | Should -Match '<nav class="sidenav" id="sidenav" aria-label="Main">'
        $html | Should -Match '<main id="main"'
        $html | Should -Match 'id="gi-live"[^>]*aria-live="polite"'
        $html | Should -Match 'id="gi-expired"'
        $html | Should -Match 'href="#main"'
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
        $items | Where-Object { $_ -like 'navitem|Golden images|*' } | Should -Match '\|False\|'
        $items | Where-Object { $_ -like 'navitem|Global settings|*' } | Should -Match '\|True\|'
    }
    It 'uses tokens only: hex colors appear solely in the :root token block' {
        $root = Join-Path $PSScriptRoot '..' 'Web'
        foreach ($f in Get-ChildItem $root -Filter *.ps1) {
            $lines = Get-Content $f.FullName | Where-Object { $_ -match '#[0-9a-fA-F]{3,8}\b' -and $_ -notmatch '^:root\{' -and $_ -notmatch '^--' -and $_ -notmatch '&#\d' -and $_ -notmatch '^\s*#' }
            $lines | Should -BeNullOrEmpty -Because $f.Name
        }
    }
    It 'leaves no Add-GIAdminNav or ShowAdminNav references' {
        $root = Join-Path $PSScriptRoot '..'
        $self = (Resolve-Path $PSCommandPath).Path
        $hits = Get-ChildItem -Path (Join-Path $root 'Web'), (Join-Path $root 'src') -Recurse -File |
            Select-String -Pattern 'Add-GIAdminNav|ShowAdminNav' | Where-Object { $_.Path -ne $self }
        $hits | Should -BeNullOrEmpty
    }
}
