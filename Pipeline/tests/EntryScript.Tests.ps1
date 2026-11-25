BeforeAll {
    $script:Entry = (Resolve-Path (Join-Path $PSScriptRoot '..' 'Invoke-GIPipeline.ps1')).Path
    $script:Src = (Resolve-Path (Join-Path $PSScriptRoot '..' 'pipeline.config.psd1')).Path
    $script:Pwsh = (Get-Process -Id $PID).Path

    function New-EntryEnv {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        Copy-Item $script:Src (Join-Path $dir 'pipeline.config.psd1')
        $state = Join-Path $dir 'state'
        New-Item -ItemType Directory -Path $state -Force | Out-Null
        [pscustomobject]@{ Dir = $dir; Config = (Join-Path $dir 'pipeline.config.psd1'); State = $state
            Lock = (Join-Path $state 'pipeline.lock'); Request = (Join-Path $state 'run-request.json') }
    }
    function Invoke-Entry {
        param($Env, [string[]] $Arguments)
        $out = & $script:Pwsh -NoProfile -File $script:Entry @Arguments -ConfigPath $Env.Config 2>&1 | Out-String
        [pscustomobject]@{ Exit = $LASTEXITCODE; Output = $out }
    }
    function Write-Request {
        param($Env, $Action = 'All', $Pool = $null)
        @{ id = [guid]::NewGuid().ToString(); action = $Action; stage = $null; runId = $null; pool = $Pool; snapshotName = $null
            forceLogoff = $false; requestedBy = 'tester'; requestedAt = (Get-Date).ToString('o') } |
            ConvertTo-Json | Set-Content -LiteralPath $Env.Request
    }
}

Describe 'Invoke-GIPipeline.ps1' {
    BeforeEach {
        $e = New-EntryEnv
        $script:Sleeper = $null
    }
    AfterEach {
        if ($script:Sleeper) { Stop-Process -Id $script:Sleeper.Id -Force -ErrorAction SilentlyContinue; $script:Sleeper = $null }
    }

    Context 'no lock' {
        It '-FromRequest with nothing queued exits 0' {
            $r = Invoke-Entry $e @('-FromRequest')
            $r.Exit | Should -Be 0
            $r.Output | Should -Match 'No queued request'
            Test-Path $e.Lock | Should -BeFalse
        }

        It '-Stage All fails to connect, releases the lock and records a Failed run' {
            $r = Invoke-Entry $e @('-Stage', 'All')
            $r.Exit | Should -Be 1
            Test-Path $e.Lock | Should -BeFalse
            $runFile = Get-ChildItem $e.State -Filter '*.json' | Where-Object Name -Match '^\d{8}-\d{6}\.json$' | Select-Object -First 1
            $runFile | Should -Not -BeNullOrEmpty
            (Get-Content $runFile.FullName -Raw | ConvertFrom-Json).status | Should -Be 'Failed'
        }

        It 'a queued Rollback for an unknown pool exits 1 and clears request and lock' {
            Write-Request $e -Action 'Rollback' -Pool 'NOT-A-POOL'
            $r = Invoke-Entry $e @('-FromRequest')
            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'rejected'
            Test-Path $e.Request | Should -BeFalse
            Test-Path $e.Lock | Should -BeFalse
        }

        It '-FromStep without Maintain exits non-zero and leaves no lock' {
            $r = Invoke-Entry $e @('-FromStage', 'TestPush', '-RunId', '20261124-213005', '-FromStep', 'Pkg:Horizon')
            $r.Exit | Should -Not -Be 0
            $r.Output | Should -Match 'FromStep only works with'
            Test-Path $e.Lock | Should -BeFalse
        }

        It '-FromStage without -RunId exits non-zero and leaves no lock' {
            $r = Invoke-Entry $e @('-FromStage', 'TestPush')
            $r.Exit | Should -Not -Be 0
            $r.Output | Should -Match 'needs -RunId'
            Test-Path $e.Lock | Should -BeFalse
        }
    }

    Context 'lock held by another live process' {
        BeforeEach {
            $script:Sleeper = Start-Process -FilePath $script:Pwsh -ArgumentList '-NoProfile', '-c', 'Start-Sleep 60' -PassThru
            @{ pid = $script:Sleeper.Id; host = [Environment]::MachineName; runId = $null; stage = 'Snapshot'
                startedAt = (Get-Date).ToString('o'); requestedBy = 'other' } | ConvertTo-Json -Compress | Set-Content -LiteralPath $e.Lock
        }

        It '-Stage PostCheck exits 3' {
            (Invoke-Entry $e @('-Stage', 'PostCheck')).Exit | Should -Be 3
            Test-Path $e.Lock | Should -BeTrue
        }

        It '-Stage All exits 1' {
            (Invoke-Entry $e @('-Stage', 'All')).Exit | Should -Be 1
            Test-Path $e.Lock | Should -BeTrue
        }

        It '-FromRequest exits 1 and keeps the queued request' {
            Write-Request $e -Action 'All'
            (Invoke-Entry $e @('-FromRequest')).Exit | Should -Be 1
            Test-Path $e.Request | Should -BeTrue
            Test-Path $e.Lock | Should -BeTrue
        }
    }
}
