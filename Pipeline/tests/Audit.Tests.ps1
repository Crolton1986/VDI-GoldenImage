BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'VDI-GIPipeline.psd1') -Force
}

Describe 'Write-GIAudit / Get-GIAudit' {
    BeforeEach {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir
        $script:cfg = @{ Paths = @{ State = $dir } }
    }

    It 'returns nothing when there is no audit file' {
        @(Get-GIAudit -Config $cfg).Count | Should -Be 0
    }

    It 'appends one JSON line per entry with the contract fields' {
        Write-GIAudit -Config $cfg -User 'DOMAIN\x' -Action 'settings.save' -Target 'vCenter' -Detail @{ changes = @(@{ key = 'Server'; old = 'a'; new = 'b' }) }
        Write-GIAudit -Config $cfg -User 'DOMAIN\y' -Action 'run.request' -Target 'All'
        $lines = [System.IO.File]::ReadAllLines((Join-Path $cfg.Paths.State 'audit.jsonl'))
        $lines.Count | Should -Be 2
        $e = $lines[0] | ConvertFrom-Json
        $e.user | Should -Be 'DOMAIN\x'
        $e.action | Should -Be 'settings.save'
        $e.target | Should -Be 'vCenter'
        $e.detail.changes[0].new | Should -Be 'b'
        $e.at | Should -Not -BeNullOrEmpty
    }

    It 'reads newest first and honours -Last' {
        1..5 | ForEach-Object { Write-GIAudit -Config $cfg -User 'u' -Action 'a' -Target "t$_" }
        $all = @(Get-GIAudit -Config $cfg)
        $all.Count | Should -Be 5
        $all[0].target | Should -Be 't5'
        $all[4].target | Should -Be 't1'
        $all[0].at | Should -BeOfType [string]
        @(Get-GIAudit -Config $cfg -Last 2).target | Should -Be @('t5', 't4')
    }

    It 'skips corrupt lines' {
        Write-GIAudit -Config $cfg -User 'u' -Action 'a' -Target 'ok'
        [System.IO.File]::AppendAllText((Join-Path $cfg.Paths.State 'audit.jsonl'), "garbage{`n")
        @(Get-GIAudit -Config $cfg).Count | Should -Be 1
    }

    It 'never throws on an unwritable path' {
        $blocker = Join-Path $TestDrive 'iamafile'
        Set-Content -LiteralPath $blocker -Value 'x'
        $bad = @{ Paths = @{ State = (Join-Path $blocker 'sub') } }
        { Write-GIAudit -Config $bad -User 'u' -Action 'a' -Target 't' -WarningAction SilentlyContinue } | Should -Not -Throw
        { Write-GIAudit -Config $bad -User 'u' -Action 'a' -Target 't' -WarningVariable w -WarningAction SilentlyContinue; $w | Should -Not -BeNullOrEmpty } | Should -Not -Throw
    }
}

Describe 'Search and sign-in audit' {
    BeforeEach {
        $script:cfg = @{ Paths = @{ State = (New-Item -ItemType Directory (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))).FullName } }
    }
    It 'records a sign-in once per user per period and skips system users' {
        Write-GISignIn -Config $script:cfg -User 'LAB\jwood' -Role Admin | Should -BeTrue
        Write-GISignIn -Config $script:cfg -User 'LAB\jwood' -Role Admin | Should -BeFalse
        Write-GISignIn -Config $script:cfg -User 'LAB\other' -Role Viewer | Should -BeTrue
        Write-GISignIn -Config $script:cfg -User 'local-admin' | Should -BeFalse
        @(Get-GIAudit -Config $script:cfg | Where-Object action -eq 'auth.signin').Count | Should -Be 2
    }
    It 'filters by image, category, user and date and pages newest first' {
        Write-GIAudit -Config $script:cfg -User 'a' -Action 'settings.update' -Image 'x' -Detail @{ section = 'Packages' }
        Write-GIAudit -Config $script:cfg -User 'b' -Action 'vm.power' -Image 'y'
        Write-GIAudit -Config $script:cfg -User 'a' -Action 'auth.signin'
        (Search-GIAudit -Config $script:cfg -Image 'x').Total | Should -Be 1
        (Search-GIAudit -Config $script:cfg -Category 'signin').Total | Should -Be 1
        (Search-GIAudit -Config $script:cfg -User 'a').Total | Should -Be 2
        (Search-GIAudit -Config $script:cfg -From ([datetime]'2999-01-01')).Total | Should -Be 0
        $p = Search-GIAudit -Config $script:cfg -PageSize 2 -Page 2
        @($p.Entries).Count | Should -Be 1
        $p.Total | Should -Be 3
    }
    It 'never shows secret-like detail keys and defaults old entries sensibly' {
        $e = [pscustomobject]@{ at = '2026-01-01T00:00:00'; user = 'u'; action = 'credential.set'; detail = [pscustomobject]@{ section = 'vCenter'; password = 'x'; userName = 'svc' } }
        (Get-GIAuditDetailText $e) | Should -Not -Match 'x$'
        (Get-GIAuditDetailText $e) | Should -Not -Match 'password'
        Get-GIAuditResult $e | Should -Be 'Saved'
    }
}
