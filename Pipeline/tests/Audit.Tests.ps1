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
