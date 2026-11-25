BeforeAll {
    $script:GuestDir = (Resolve-Path (Join-Path $PSScriptRoot '..' 'guest')).Path
    . (Join-Path $script:GuestDir 'GIWatcher.Core.ps1')

    $script:RegErr = 'ERROR: Installation failed: This command cannot be run due to the error: Illegal operation attempted on a registry key that has been marked for deletion.'

    function New-FixFile {
        param([string] $Dir, [string] $Id, [int] $Priority = 100, [string] $Actions = "'*'", [int] $MaxAttempts = 2,
              [int] $RebootFrom = 0, [string] $ExitCodes = '1', [string] $Patterns = "'registry key that has been marked for deletion'",
              [string] $Sources = "'Errors', 'Output', 'Log'")
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $body = @"
`$GIFix = @{
    Id = '$Id'
    Description = 'test fix $Id'
    Priority = $Priority
    Actions = @($Actions)
    MaxAttempts = $MaxAttempts
    RebootFromAttempt = $RebootFrom
    Match = @{ ExitCodes = @($ExitCodes); Patterns = @($Patterns); Sources = @($Sources) }
}
function Invoke-GIFix { param(`$Context) return @{ Ok = `$true; Message = 'ok' } }
"@
        $p = Join-Path $Dir "$Id.ps1"
        Set-Content -LiteralPath $p -Value $body -Encoding UTF8
        return $p
    }
    function New-Entry {
        # Catalog entry without touching the disk
        param([string] $Id, [int] $MaxAttempts = 2, [int] $RebootFrom = 0, [string[]] $Actions = @('*'), [int[]] $Codes = @(1),
              [string[]] $Patterns = @('registry key'), [string[]] $Sources = @('Errors', 'Output', 'Log'))
        [pscustomobject]@{ Id = $Id; File = "$Id.ps1"; Valid = $true; Errors = @(); Meta = @{
            Id = $Id; Description = 'd'; Priority = 100; Actions = $Actions; MaxAttempts = $MaxAttempts; RebootFromAttempt = $RebootFrom
            Match = @{ ExitCodes = $Codes; Patterns = $Patterns; Sources = $Sources } } }
    }
}

Describe 'Get-GIStepFileId' {
    It 'replaces the colon' {
        Get-GIStepFileId -Id 'Pkg:Horizon' | Should -Be 'Pkg_Horizon'
        Get-GIStepFileId -Id 'WindowsUpdate' | Should -Be 'WindowsUpdate'
    }
}

Describe 'Fix catalog and matcher' {
    BeforeAll {
        $script:Fixes = Join-Path $TestDrive 'fixes'
        New-FixFile -Dir $script:Fixes -Id 'ZetaFix' -Priority 100 | Out-Null
        New-FixFile -Dir $script:Fixes -Id 'AlphaFix' -Priority 100 -Actions "'Horizon'" | Out-Null
        New-FixFile -Dir $script:Fixes -Id 'EarlyFix' -Priority 10 -Actions "'VmTools'" | Out-Null
        New-FixFile -Dir $script:Fixes -Id 'LogOnlyFix' -Priority 50 -Sources "'Log'" | Out-Null
        # Code inside $GIFix must make the file invalid and must never run
        $evil = @'
$GIFix = @{ Id = 'EvilFix'; Description = 'x'; Priority = 1; Actions = @('*'); MaxAttempts = 1; RebootFromAttempt = 0
    Match = @{ ExitCodes = @(1); Patterns = @((New-Item -ItemType File -Path (Join-Path $env:TEMP 'gi-evil-ran.txt') -Force)) } }
function Invoke-GIFix { param($Context) @{ Ok = $true; Message = '' } }
'@
        Set-Content -LiteralPath (Join-Path $script:Fixes 'EvilFix.ps1') -Value $evil
        Set-Content -LiteralPath (Join-Path $script:Fixes 'NoFunc.ps1') -Value "`$GIFix = @{ Id = 'NoFunc'; Description = 'x'; Priority = 1; Actions = @('*'); MaxAttempts = 1; RebootFromAttempt = 0; Match = @{ Patterns = @('x') } }"
        $script:Cat = @(Read-GIFixCatalog -Path $script:Fixes)
        $script:Et = @{ Errors = $script:RegErr; Output = ''; Log = '' }
    }

    It 'returns an empty catalog for a missing folder' {
        @(Read-GIFixCatalog -Path (Join-Path $TestDrive 'nope')).Count | Should -Be 0
    }
    It 'marks code in $GIFix and a missing Invoke-GIFix invalid, and does not execute the file' {
        $evil = $script:Cat | Where-Object Id -eq 'EvilFix'
        $evil.Valid | Should -BeFalse
        $evil.Errors.Count | Should -BeGreaterThan 0
        (Test-Path (Join-Path ([IO.Path]::GetTempPath()) 'gi-evil-ran.txt')) | Should -BeFalse
        ($script:Cat | Where-Object Id -eq 'NoFunc').Valid | Should -BeFalse
        ($script:Cat | Where-Object Id -eq 'NoFunc').Errors -join ' ' | Should -Match 'Invoke-GIFix'
    }
    It 'sorts by Priority then file name, invalid ones last' {
        $valid = @($script:Cat | Where-Object Valid | ForEach-Object Id)
        $valid | Should -Be @('EarlyFix', 'LogOnlyFix', 'AlphaFix', 'ZetaFix')
        $script:Cat[-1].Valid | Should -BeFalse
    }
    It 'picks the first match by priority and honors the action filter' {
        $s = Select-GIFix -Catalog $script:Cat -Action 'Horizon' -ExitCode 1 -ErrorText $script:Et
        $s.Fix.Id | Should -Be 'AlphaFix'
        $s.FixAttempt | Should -Be 1
        (Select-GIFix -Catalog $script:Cat -Action 'VmTools' -ExitCode 1 -ErrorText $script:Et).Fix.Id | Should -Be 'EarlyFix'
        (Select-GIFix -Catalog $script:Cat -Action 'Update' -ExitCode 1 -ErrorText $script:Et).Fix.Id | Should -Be 'ZetaFix'
    }
    It 'honors the exit code filter and treats empty ExitCodes as any non-zero' {
        Select-GIFix -Catalog $script:Cat -Action 'Horizon' -ExitCode 5 -ErrorText $script:Et | Should -BeNullOrEmpty
        $any = @(New-Entry -Id 'Any' -Codes @())
        Select-GIFix -Catalog $any -Action 'Horizon' -ExitCode 5 -ErrorText $script:Et | Should -Not -BeNullOrEmpty
        Select-GIFix -Catalog $any -Action 'Horizon' -ExitCode 0 -ErrorText $script:Et | Should -BeNullOrEmpty
    }
    It 'matches the pattern case-insensitively on each listed source only' {
        $log = @{ Errors = ''; Output = ''; Log = 'foo REGISTRY KEY THAT HAS BEEN MARKED FOR DELETION bar' }
        # LogOnlyFix (priority 50) is the only one that looks at Log first; the others also have all sources
        (Select-GIFix -Catalog @($script:Cat | Where-Object Id -eq 'LogOnlyFix') -Action 'Horizon' -ExitCode 1 -ErrorText $log).Fix.Id | Should -Be 'LogOnlyFix'
        Select-GIFix -Catalog @($script:Cat | Where-Object Id -eq 'LogOnlyFix') -Action 'Horizon' -ExitCode 1 -ErrorText $script:Et | Should -BeNullOrEmpty
        $out = @{ Errors = ''; Output = "line1`n$($script:RegErr)"; Log = '' }
        Select-GIFix -Catalog @($script:Cat | Where-Object Id -eq 'ZetaFix') -Action 'Horizon' -ExitCode 1 -ErrorText $out | Should -Not -BeNullOrEmpty
    }
    It 'returns $null when nothing matches' {
        $none = @{ Errors = 'disk full'; Output = ''; Log = '' }
        Select-GIFix -Catalog $script:Cat -Action 'Horizon' -ExitCode 1 -ErrorText $none | Should -BeNullOrEmpty
        Select-GIFix -Catalog @() -Action 'Horizon' -ExitCode 1 -ErrorText $script:Et | Should -BeNullOrEmpty
    }
    It 'validates metadata' {
        (Test-GIFixMetadata -Meta @{ Id = 'x' }).Count | Should -BeGreaterThan 3
        (Test-GIFixMetadata -Meta (New-Entry -Id 'GoodFix').Meta).Count | Should -Be 0
        $bad = (New-Entry -Id 'GoodFix').Meta; $bad.MaxAttempts = 9
        @(Test-GIFixMetadata -Meta $bad) | Should -Contain 'MaxAttempts must be an integer 1..5'
    }
}

Describe 'Retry caps' {
    It 'passes over a fix whose MaxAttempts are used and falls through to the next match' {
        $cat = @((New-Entry -Id 'First' -MaxAttempts 2), (New-Entry -Id 'Second' -MaxAttempts 1))
        $et = @{ Errors = $script:RegErr; Output = ''; Log = '' }
        $applied = @(@{ id = 'First'; fixAttempt = 1 }, [pscustomobject]@{ id = 'First'; fixAttempt = 2 })
        $s = Select-GIFix -Catalog $cat -Action 'Horizon' -ExitCode 1 -ErrorText $et -Applied $applied
        $s.Fix.Id | Should -Be 'Second'
        $s.FixAttempt | Should -Be 1
        $applied += @{ id = 'Second'; fixAttempt = 1 }
        Select-GIFix -Catalog $cat -Action 'Horizon' -ExitCode 1 -ErrorText $et -Applied $applied | Should -BeNullOrEmpty
    }
    It 'counts fix attempts and sets RebootBeforeRetry from RebootFromAttempt' {
        $cat = @(New-Entry -Id 'Reboots' -MaxAttempts 3 -RebootFrom 2)
        $et = @{ Errors = $script:RegErr; Output = ''; Log = '' }
        $s1 = Select-GIFix -Catalog $cat -Action 'Horizon' -ExitCode 1 -ErrorText $et
        $s1.FixAttempt | Should -Be 1; $s1.RebootBeforeRetry | Should -BeFalse
        $s2 = Select-GIFix -Catalog $cat -Action 'Horizon' -ExitCode 1 -ErrorText $et -Applied @(@{ id = 'Reboots' })
        $s2.FixAttempt | Should -Be 2; $s2.RebootBeforeRetry | Should -BeTrue
        $s3 = Select-GIFix -Catalog @(New-Entry -Id 'Never' -RebootFrom 0) -Action 'Horizon' -ExitCode 1 -ErrorText $et
        $s3.RebootBeforeRetry | Should -BeFalse
    }
    It 'stops step attempts at maxStepAttempts' {
        Test-GIAttemptAllowed -StepFile ([pscustomobject]@{ attempt = 3 }) -MaxAttempts 4 | Should -BeTrue
        Test-GIAttemptAllowed -StepFile ([pscustomobject]@{ attempt = 4 }) -MaxAttempts 4 | Should -BeFalse
        Test-GIAttemptAllowed -StepFile @{ attempt = 0 } -MaxAttempts 1 | Should -BeTrue
    }
}

Describe 'Get-GIStepStartDecision' {
    BeforeAll {
        $script:Plan = [pscustomobject]@{ runId = 'R1'; attemptId = 'A1' }
        function New-StepFile { param($Status, $RunId = 'R1', $AttemptId = 'A1') [pscustomobject]@{ runId = $RunId; attemptId = $AttemptId; status = $Status } }
    }
    It 'skips Succeeded of the same run' { Get-GIStepStartDecision -Plan $script:Plan -StepFile (New-StepFile Succeeded) | Should -Be 'Skip' }
    It 'resets without a file or for another attemptId' {
        Get-GIStepStartDecision -Plan $script:Plan -StepFile $null | Should -Be 'Reset'
        Get-GIStepStartDecision -Plan $script:Plan -StepFile (New-StepFile Running -AttemptId 'A0') | Should -Be 'Reset'
        Get-GIStepStartDecision -Plan $script:Plan -StepFile (New-StepFile Succeeded -RunId 'R0' -AttemptId 'A0') | Should -Be 'Reset'
    }
    It 'resumes interrupted Running/Fixing steps of the same attempt' {
        Get-GIStepStartDecision -Plan $script:Plan -StepFile (New-StepFile Running) | Should -Be 'Resume'
        Get-GIStepStartDecision -Plan $script:Plan -StepFile (New-StepFile Fixing) | Should -Be 'Resume'
    }
    It 'continues after a reboot' { Get-GIStepStartDecision -Plan $script:Plan -StepFile (New-StepFile RebootRequired) | Should -Be 'AfterReboot' }
    It 'stops at a Failed step of the same attempt' { Get-GIStepStartDecision -Plan $script:Plan -StepFile (New-StepFile Failed) | Should -Be 'Stop' }
}

Describe 'Atomic JSON and log' {
    It 'round-trips and leaves no .tmp behind when overwriting' {
        $p = Join-Path $TestDrive 'sub\a.json'
        Write-GIWatcherJson -Path $p -InputObject @{ a = 1; list = @('x', 'y') }
        (Read-GIWatcherJson -Path $p).a | Should -Be 1
        Write-GIWatcherJson -Path $p -InputObject @{ a = 2; list = @() }
        (Read-GIWatcherJson -Path $p).a | Should -Be 2
        Test-Path "$p.tmp" | Should -BeFalse
        $bytes = [IO.File]::ReadAllBytes($p)
        $bytes[0] | Should -Not -Be 0xEF
    }
    It 'returns $null for missing, empty and truncated files without throwing' {
        Read-GIWatcherJson -Path (Join-Path $TestDrive 'missing.json') | Should -BeNullOrEmpty
        $e = Join-Path $TestDrive 'empty.json'; Set-Content -LiteralPath $e -Value '' -NoNewline
        { Read-GIWatcherJson -Path $e } | Should -Not -Throw
        Read-GIWatcherJson -Path $e | Should -BeNullOrEmpty
        $t = Join-Path $TestDrive 'trunc.json'; Set-Content -LiteralPath $t -Value '{ "a": 1, "b": [1, 2' -NoNewline
        Read-GIWatcherJson -Path $t | Should -BeNullOrEmpty
    }
    It 'writes tab-separated CRLF lines, UTF-8 without BOM, with tabs and newlines sanitized' {
        $p = Join-Path $TestDrive 'w.log'
        Write-GIWatcherLog -Path $p -Level 'WARN' -StepId 'Pkg:Horizon' -Message "a`tb`r`nc"
        Write-GIWatcherLog -Path $p -Level 'INFO' -Message 'watcher level'
        $bytes = [IO.File]::ReadAllBytes($p)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        $lines = $text -split "`r`n"
        $lines.Count | Should -Be 3     # two lines + empty tail after the final CRLF
        $lines[2] | Should -Be ''
        $f = $lines[0] -split "`t"
        $f.Count | Should -Be 4
        { [datetimeoffset]::Parse($f[0]) } | Should -Not -Throw
        $f[1] | Should -Be 'WARN'; $f[2] | Should -Be 'Pkg:Horizon'; $f[3] | Should -Be 'a b c'
        ($lines[1] -split "`t")[2] | Should -Be '-'
    }
    It 'tails only complete lines until -Final' {
        $p = Join-Path $TestDrive 'out.txt'
        [IO.File]::WriteAllText($p, "one`r`ntwo`r`npart")
        $t = Read-GIOutTail -Path $p -Offset 0
        $t.Lines | Should -Be @('one', 'two')
        [IO.File]::AppendAllText($p, "ial`r`n")
        $t2 = Read-GIOutTail -Path $p -Offset $t.NextOffset
        $t2.Lines | Should -Be @('partial')
        [IO.File]::AppendAllText($p, 'tail')
        (Read-GIOutTail -Path $p -Offset $t2.NextOffset).Lines.Count | Should -Be 0
        (Read-GIOutTail -Path $p -Offset $t2.NextOffset -Final).Lines | Should -Be @('tail')
    }
}

Describe 'Get-GIAttemptOutcome' {
    It 'Action: success with version' {
        $r = [pscustomobject]@{ action = 'Horizon'; success = $true; errors = @(); rebootRequired = $false; versions = [pscustomobject]@{ Horizon = '2406' } }
        $o = Get-GIAttemptOutcome -Kind Action -ExitCode 0 -Result $r
        $o.Status | Should -Be 'Succeeded'; $o.Message | Should -Be 'Installed version 2406'; $o.RebootAfter | Should -BeFalse
    }
    It 'Action: success without a version says Done' {
        $r = [pscustomobject]@{ action = 'Exit'; success = $true; versions = [pscustomobject]@{} }
        (Get-GIAttemptOutcome -Kind Action -ExitCode 0 -Result $r).Message | Should -Be 'Done'
    }
    It 'Action: rebootRequired sets RebootAfter' {
        $r = [pscustomobject]@{ action = 'Horizon'; success = $true; rebootRequired = $true; versions = [pscustomobject]@{} }
        $o = Get-GIAttemptOutcome -Kind Action -ExitCode 0 -Result $r
        $o.Status | Should -Be 'Succeeded'; $o.RebootAfter | Should -BeTrue
    }
    It 'Action: exit 1, success false and a missing result are failures' {
        $ok = [pscustomobject]@{ action = 'Horizon'; success = $true }
        (Get-GIAttemptOutcome -Kind Action -ExitCode 1 -Result $ok).Status | Should -Be 'Failed'
        (Get-GIAttemptOutcome -Kind Action -ExitCode 0 -Result ([pscustomobject]@{ success = $false })).Status | Should -Be 'Failed'
        (Get-GIAttemptOutcome -Kind Action -ExitCode 0 -Result $null).Status | Should -Be 'Failed'
    }
    It 'WindowsUpdate: reboot, found = 0, next pass, maxPasses and error' {
        function wu($found, $reboot = $false, $err = $null) { [pscustomobject]@{ found = $found; installed = $found; failed = 0; rebootRequired = $reboot; error = $err } }
        $o = Get-GIAttemptOutcome -Kind WindowsUpdate -ExitCode 0 -Result (wu 3 $true) -MaxPasses 5 -Pass 2
        $o.Status | Should -Be 'RebootRequired'; $o.Data.pass | Should -Be 2; $o.PassEntry.reboot | Should -BeTrue
        $o = Get-GIAttemptOutcome -Kind WindowsUpdate -ExitCode 0 -Result (wu 0) -MaxPasses 5 -Pass 1
        $o.Status | Should -Be 'Succeeded'; $o.Message | Should -Not -Match 'still pending'
        (Get-GIAttemptOutcome -Kind WindowsUpdate -ExitCode 0 -Result (wu 2) -MaxPasses 5 -Pass 1).Status | Should -Be 'NextPass'
        $o = Get-GIAttemptOutcome -Kind WindowsUpdate -ExitCode 0 -Result (wu 2) -MaxPasses 5 -Pass 5
        $o.Status | Should -Be 'Succeeded'; $o.Message | Should -Match 'Updates still pending after 5 passes'
        $o = Get-GIAttemptOutcome -Kind WindowsUpdate -ExitCode 0 -Result (wu 0 $false 'boom') -Pass 1
        $o.Status | Should -Be 'Failed'; $o.Message | Should -Match 'boom'
        (Get-GIAttemptOutcome -Kind WindowsUpdate -ExitCode 0 -Result $null).Status | Should -Be 'Failed'
    }
}

Describe 'Error text' {
    It 'builds Errors, Output tail and the newest log since the attempt start' {
        $out = Join-Path $TestDrive 'o.txt'
        Set-Content -LiteralPath $out -Value (1..300 | ForEach-Object { "line $_" })
        $logs = Join-Path $TestDrive 'logs'; New-Item -ItemType Directory -Path $logs | Out-Null
        $old = Join-Path $logs 'old.log'; Set-Content $old 'old log'; (Get-Item $old).LastWriteTime = (Get-Date).AddHours(-2)
        $new = Join-Path $logs 'new.log'; Set-Content $new 'new log text'
        $res = [pscustomobject]@{ errors = @('e1', 'e2') }
        $et = Get-GIStepErrorText -Result $res -OutFile $out -LogDir $logs -Since (Get-Date).AddMinutes(-5).ToString('o')
        $et.Errors | Should -Be 'e1; e2'
        @($et.Output -split "`n").Count | Should -Be 200
        $et.Output | Should -Match 'line 300'
        $et.Log | Should -Be 'new log text'
        (Get-GIStepErrorText -Result ([pscustomobject]@{ error = 'wu bad' }) -OutFile $null -LogDir $null -Since $null).Errors | Should -Be 'wu bad'
        (Get-GIStepErrorText -Result $null -OutFile $out -LogDir $logs -Since (Get-Date).AddHours(1).ToString('o')).Log | Should -Be ''
    }
    It 'Get-GIOriginalError falls back to the last output line, then the exit code' {
        Get-GIOriginalError -ErrorText @{ Errors = 'real'; Output = 'x' } -ExitCode 1 | Should -Be 'real'
        Get-GIOriginalError -ErrorText @{ Errors = ''; Output = "a`nlast one`n`n" } -ExitCode 1 | Should -Be 'last one'
        Get-GIOriginalError -ErrorText @{ Errors = ''; Output = '' } -ExitCode 7 | Should -Be 'exit code 7'
    }
}

Describe 'Process allowlist' {
    It 'allows msiexec and InstallDir images, never protected pids' {
        Test-GIProcessStoppable -ProcessId 10 -Name 'msiexec' -Path 'C:\Windows\System32\msiexec.exe' -InstallDir 'C:\Install' | Should -BeTrue
        Test-GIProcessStoppable -ProcessId 10 -Name 'setup' -Path 'C:\Install\Horizon\setup.exe' -InstallDir 'C:\Install' | Should -BeTrue
        Test-GIProcessStoppable -ProcessId 10 -Name 'setup' -Path 'C:\InstallOther\setup.exe' -InstallDir 'C:\Install' | Should -BeFalse
        Test-GIProcessStoppable -ProcessId 10 -Name 'powershell' -Path 'C:\Windows\powershell.exe' -InstallDir 'C:\Install' | Should -BeFalse
        Test-GIProcessStoppable -ProcessId 10 -Name 'msiexec' -InstallDir 'C:\Install' -ProtectedPids @(10) | Should -BeFalse
        Test-GIProcessStoppable -ProcessId 10 -Name 'msiexec' -InstallDir 'C:\Install' -InstallDirOnly | Should -BeFalse
    }
}

Describe 'Watcher main loop' {
    BeforeAll {
        # Dot-source the entry: defines the functions only, the main loop does not run
        . (Join-Path $script:GuestDir 'Invoke-GIWatcher.ps1') -WorkDir (Join-Path $TestDrive 'dotsource')

        function New-Work {
            param([object[]] $Steps, [hashtable] $Settings = @{ heartbeatSec = 1; maxStepAttempts = 4; fixTimeoutSec = 30 })
            $w = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $w | Out-Null
            @{ schemaVersion = 1; runId = 'R1'; attemptId = 'A1'; launchId = 'L1'; createdAt = (Get-Date).ToString('o')
               scriptPath = 'C:\x\VDI-GoldenImage.ps1'; workDir = $w; installDir = (Join-Path $w 'Install'); logDir = (Join-Path $w 'Logs')
               settings = $Settings; steps = $Steps } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $w 'plan.json')
            return $w
        }
    }
    BeforeEach {
        $script:StepCalls = @()
        $script:Script = @{}    # step id -> list of scriptblocks-like result specs per attempt
        Mock Start-GIStepProcess {
            $script:StepCalls += $StepId
            $n = @($script:StepCalls | Where-Object { $_ -eq $StepId }).Count
            $spec = $script:Script[$StepId][$n - 1]
            Set-Content -LiteralPath $OutFile -Value "child output attempt $n"
            if ($spec.Result) { $spec.Result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultFile }
            return @{ ExitCode = $spec.Exit; TimedOut = $false }
        }
        Mock Start-GIFixProcess {
            @{ ok = $true; message = 'fixed'; outcome = 'Applied' } | ConvertTo-Json | Set-Content -LiteralPath $ResultPath
            return @{ ExitCode = 0; TimedOut = $false }
        }
    }

    It 'retries after the registry error, records the fix and finishes AllDone' {
        $w = New-Work -Steps @(
            @{ id = 'EnableUpdates'; kind = 'Action'; action = 'Update' },
            @{ id = 'Pkg:Horizon'; kind = 'Action'; action = 'Horizon' })
        New-FixFile -Dir (Join-Path $w 'fixes') -Id 'RegistryKeyMarkedForDeletion' -MaxAttempts 2 | Out-Null
        $ok = { param($a) @{ action = $a; success = $true; errors = @(); rebootRequired = $false; versions = @{ $a = '1.0' } } }
        $script:Script['EnableUpdates'] = @(@{ Exit = 0; Result = (& $ok 'Update') })
        $script:Script['Pkg:Horizon'] = @(
            @{ Exit = 1; Result = @{ action = 'Horizon'; success = $false; errors = @($script:RegErr) } },
            @{ Exit = 0; Result = (& $ok 'Horizon') })

        $code = @(Invoke-GIWatcherMain -WorkDir $w -ScriptDir $script:GuestDir)[-1]

        $code | Should -Be 0
        $s = Read-GIWatcherJson -Path (Join-Path $w 'steps\Pkg_Horizon.json')
        $s.status | Should -Be 'Succeeded'
        $s.attempt | Should -Be 2
        $s.originalError | Should -Be $script:RegErr
        @($s.fixApplied).Count | Should -Be 1
        $s.fixApplied[0].id | Should -Be 'RegistryKeyMarkedForDeletion'
        $s.fixApplied[0].outcome | Should -Be 'Applied'
        $s.message | Should -Be 'Installed version 1.0'
        (Read-GIWatcherJson -Path (Join-Path $w 'steps\EnableUpdates.json')).status | Should -Be 'Succeeded'
        $wj = Read-GIWatcherJson -Path (Join-Path $w 'watcher.json')
        $wj.state | Should -Be 'Exited'; $wj.exitReason | Should -Be 'AllDone'
        $log = Get-Content -LiteralPath (Join-Path $w 'watcher.log') -Raw
        $log | Should -Match "OUT\tPkg:Horizon\tchild output attempt 1"
        Should -Invoke Start-GIFixProcess -Times 1 -Exactly
    }

    It 'requests a reboot with a pending fix when RebootFromAttempt = 1, then continues after the relaunch' {
        $w = New-Work -Steps @(@{ id = 'Pkg:Horizon'; kind = 'Action'; action = 'Horizon' })
        New-FixFile -Dir (Join-Path $w 'fixes') -Id 'RegistryKeyMarkedForDeletion' -MaxAttempts 2 -RebootFrom 1 | Out-Null
        $script:Script['Pkg:Horizon'] = @(
            @{ Exit = 1; Result = @{ action = 'Horizon'; success = $false; errors = @($script:RegErr) } },
            @{ Exit = 0; Result = @{ action = 'Horizon'; success = $true; errors = @(); versions = @{ Horizon = '2' } } })

        $code = @(Invoke-GIWatcherMain -WorkDir $w -ScriptDir $script:GuestDir)[-1]
        $code | Should -Be 0
        $s = Read-GIWatcherJson -Path (Join-Path $w 'steps\Pkg_Horizon.json')
        $s.status | Should -Be 'RebootRequired'
        $s.pendingFix.id | Should -Be 'RegistryKeyMarkedForDeletion'
        $s.pendingFix.fixAttempt | Should -Be 1
        $wj = Read-GIWatcherJson -Path (Join-Path $w 'watcher.json')
        $wj.state | Should -Be 'RebootRequested'; $wj.exitReason | Should -Be 'RebootRequested'
        Should -Invoke Start-GIStepProcess -Times 1 -Exactly

        # Host relaunch: same attemptId, new launchId
        $plan = Read-GIWatcherJson -Path (Join-Path $w 'plan.json'); $plan.launchId = 'L2'
        Write-GIWatcherJson -Path (Join-Path $w 'plan.json') -InputObject $plan
        $code = @(Invoke-GIWatcherMain -WorkDir $w -ScriptDir $script:GuestDir)[-1]
        $code | Should -Be 0
        $s = Read-GIWatcherJson -Path (Join-Path $w 'steps\Pkg_Horizon.json')
        $s.status | Should -Be 'Succeeded'; $s.attempt | Should -Be 2; $s.pendingFix | Should -BeNullOrEmpty
        (Read-GIWatcherJson -Path (Join-Path $w 'watcher.json')).exitReason | Should -Be 'AllDone'
        Should -Invoke Start-GIFixProcess -Times 2 -Exactly   # BeforeRetry + AfterReboot
    }

    It 'fails the step with the in-guest wording when no fix matches' {
        $w = New-Work -Steps @(@{ id = 'Pkg:Horizon'; kind = 'Action'; action = 'Horizon' }, @{ id = 'Pkg:Fslogix'; kind = 'Action'; action = 'Fslogix' })
        $script:Script['Pkg:Horizon'] = @(@{ Exit = 1; Result = @{ action = 'Horizon'; success = $false; errors = @('disk full') } })
        $code = @(Invoke-GIWatcherMain -WorkDir $w -ScriptDir $script:GuestDir)[-1]
        $code | Should -Be 1
        $s = Read-GIWatcherJson -Path (Join-Path $w 'steps\Pkg_Horizon.json')
        $s.status | Should -Be 'Failed'
        $s.message | Should -Be "In-guest action 'Horizon' exited 1: disk full"
        (Read-GIWatcherJson -Path (Join-Path $w 'watcher.json')).exitReason | Should -Be 'StepFailed'
        Test-Path (Join-Path $w 'steps\Pkg_Fslogix.json') | Should -BeFalse
    }

    It 'gives up after maxStepAttempts' {
        $w = New-Work -Steps @(@{ id = 'Pkg:Horizon'; kind = 'Action'; action = 'Horizon' }) -Settings @{ heartbeatSec = 1; maxStepAttempts = 2; fixTimeoutSec = 30 }
        New-FixFile -Dir (Join-Path $w 'fixes') -Id 'RegistryKeyMarkedForDeletion' -MaxAttempts 5 | Out-Null
        $bad = @{ Exit = 1; Result = @{ action = 'Horizon'; success = $false; errors = @($script:RegErr) } }
        $script:Script['Pkg:Horizon'] = @($bad, $bad, $bad)
        $code = @(Invoke-GIWatcherMain -WorkDir $w -ScriptDir $script:GuestDir)[-1]
        $code | Should -Be 1
        (Read-GIWatcherJson -Path (Join-Path $w 'steps\Pkg_Horizon.json')).message | Should -Be "Gave up after 2 attempts: $($script:RegErr)"
    }

    It 'runs Windows Update passes in one launch and stops at found = 0' {
        $w = New-Work -Steps @(@{ id = 'WindowsUpdate'; kind = 'WindowsUpdate'; maxPasses = 5 })
        $script:Script['WindowsUpdate'] = @(
            @{ Exit = 0; Result = @{ found = 2; installed = 2; failed = 0; rebootRequired = $false; error = $null } },
            @{ Exit = 0; Result = @{ found = 0; installed = 0; failed = 0; rebootRequired = $false; error = $null } })
        $code = @(Invoke-GIWatcherMain -WorkDir $w -ScriptDir $script:GuestDir)[-1]
        $code | Should -Be 0
        $s = Read-GIWatcherJson -Path (Join-Path $w 'steps\WindowsUpdate.json')
        $s.status | Should -Be 'Succeeded'; $s.data.pass | Should -Be 2; @($s.data.passes).Count | Should -Be 2
    }

    It 'writes PlanError for a missing plan and Crashed on unexpected errors' {
        $w = Join-Path $TestDrive 'noplan'; New-Item -ItemType Directory -Path $w | Out-Null
        @(Invoke-GIWatcherMain -WorkDir $w -ScriptDir $script:GuestDir)[-1] | Should -Be 2
        (Read-GIWatcherJson -Path (Join-Path $w 'watcher.json')).exitReason | Should -Be 'PlanError'

        $w2 = New-Work -Steps @(@{ id = 'Pkg:Horizon'; kind = 'Action'; action = 'Horizon' })
        Mock Start-GIStepProcess { throw 'launcher exploded' }
        @(Invoke-GIWatcherMain -WorkDir $w2 -ScriptDir $script:GuestDir)[-1] | Should -Be 3
        $wj = Read-GIWatcherJson -Path (Join-Path $w2 'watcher.json')
        $wj.state | Should -Be 'Exited'; $wj.exitReason | Should -Be 'Crashed'
        Get-Content -LiteralPath (Join-Path $w2 'watcher.log') -Raw | Should -Match "ERROR\t-\tWatcher crashed: launcher exploded"
    }
}

Describe 'Invoke-GIFixRunner.ps1' {
    BeforeAll { $script:Pwsh = (Get-Process -Id $PID).Path }
    It 'writes an Applied result and exposes the helpers' {
        $w = Join-Path $TestDrive 'runner'; New-Item -ItemType Directory -Path $w | Out-Null
        $fix = Join-Path $w 'F.ps1'
        Set-Content -LiteralPath $fix -Value @'
$GIFix = @{ Id = 'F' }
function Invoke-GIFix { param($Context)
    Write-GIFixLog -Message 'hello'
    $s = @(Stop-GIAllowedProcess -Name 'pwsh')
    return @{ Ok = ($s.Count -eq 0); Message = "phase $($Context.Phase), stopped $($s.Count)" } }
'@
        $ctx = Join-Path $w 'c.json'; $res = Join-Path $w 'r.json'
        @{ StepId = 'Pkg:Horizon'; Phase = 'BeforeRetry'; WorkDir = $w; InstallDir = (Join-Path $w 'Install'); WatcherPid = $PID; ProtectedPids = @($PID) } | ConvertTo-Json | Set-Content $ctx
        & $script:Pwsh -NoProfile -File (Join-Path $script:GuestDir 'Invoke-GIFixRunner.ps1') -FixPath $fix -ContextPath $ctx -ResultPath $res | Out-Null
        $r = Read-GIWatcherJson -Path $res
        $r.ok | Should -BeTrue; $r.outcome | Should -Be 'Applied'; $r.message | Should -Be 'phase BeforeRetry, stopped 0'
        Get-Content -LiteralPath (Join-Path $w 'watcher.log') -Raw | Should -Match "INFO\tPkg:Horizon\t\[fix\] hello"
    }
    It 'turns a throw into FixFailed' {
        $w = Join-Path $TestDrive 'runner2'; New-Item -ItemType Directory -Path $w | Out-Null
        $fix = Join-Path $w 'F.ps1'
        Set-Content -LiteralPath $fix -Value "function Invoke-GIFix { param(`$Context) throw 'nope' }"
        $ctx = Join-Path $w 'c.json'; $res = Join-Path $w 'r.json'
        @{ StepId = 'X'; WorkDir = $w; InstallDir = 'C:\none'; WatcherPid = $PID; ProtectedPids = @() } | ConvertTo-Json | Set-Content $ctx
        & $script:Pwsh -NoProfile -File (Join-Path $script:GuestDir 'Invoke-GIFixRunner.ps1') -FixPath $fix -ContextPath $ctx -ResultPath $res | Out-Null
        $r = Read-GIWatcherJson -Path $res
        $r.ok | Should -BeFalse; $r.outcome | Should -Be 'FixFailed'; $r.message | Should -Match 'nope'
    }
}
