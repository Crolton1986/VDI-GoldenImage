BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'VDI-GIPipeline.psd1') -Force

    $global:GITestCtx = @{}
    function Set-ModVar { param([string] $Name, $Value) $global:GITestCtx[$Name] = $Value }

    function New-WConfig {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $c = @{
            Root        = $root
            Paths       = @{ State = (Join-Path $root 'state'); Reports = (Join-Path $root 'reports'); Logs = (Join-Path $root 'logs') }
            GoldenImage = @{ VmName = 'GI-VM'; GuestCredentialSecret = 'GI-GuestAdmin'; ScriptPathInGuest = 'C:\ProgramData\VDI\VDI-GoldenImage.ps1'
                CopyScript = $false; Actions = @('VmTools'); FinalizeAction = 'Finalize'; WindowsUpdate = @{ Enabled = $true; MaxPasses = 3 }
                ActionTimeoutMin = 60; Watcher = @{ MaxRelaunches = 1; MaxStepAttempts = 5; FixTimeoutSec = 300 } }
        }
        New-Item -ItemType Directory -Path $c.Paths.State -Force | Out-Null
        $c
    }
    function New-WRun($Config) {
        $r = New-GIRun -Config $Config -RunId '20261125-100000'
        $null = Initialize-GIMaintainSteps -Config $Config -Run $r -Plan (Get-GIMaintainStepPlan -Config $Config)
        $r
    }
    function New-GStep($Id, $Status = 'Running', $Attempt = 1, $Message = 'working', $Started = '2026-11-25T09:59:00+00:00', $Extra = @{}) {
        $s = @{ schemaVersion = 1; runId = '20261125-100000'; attemptId = 'A1'; id = $Id; status = $Status; attempt = $Attempt
            attemptStartedAt = $Started; startedAt = $Started; message = $Message; fixApplied = @(); data = @{} }
        foreach ($k in $Extra.Keys) { $s[$k] = $Extra[$k] }
        $s
    }
    function New-PollText {
        param($Now = '2026-11-25T10:00:00+00:00', $Boot = '2026-11-25T09:00:00+00:00', $Watcher = $null, [bool] $PidAlive = $true, $Task = 'Running',
            [long] $Offset = 0, [long] $Size = 0, [byte[]] $LogBytes = @(), $Steps)
        $o = [ordered]@{ now = $Now; boot = $Boot; watcher = $(if ($Watcher) { $Watcher | ConvertTo-Json -Compress } else { $null }); pidAlive = $PidAlive
            task = $Task; offset = $Offset; size = $Size; log = [Convert]::ToBase64String($LogBytes); steps = $null }
        if ($PSBoundParameters.ContainsKey('Steps')) { $o.steps = @($Steps | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 }) }
        $o | ConvertTo-Json -Compress -Depth 5
    }
    function New-GWatcher($State = 'Running', $Reason = $null, $Launch = 'L1', $Heartbeat = '2026-11-25T09:59:50+00:00', $Step = 'Pkg:VmTools') {
        @{ schemaVersion = 1; pid = 4242; launchId = $Launch; attemptId = 'A1'; startedAt = '2026-11-25T09:00:00+00:00'; heartbeat = $Heartbeat
           currentStep = $Step; state = $State; exitReason = $Reason; endedAt = $null }
    }
    function Get-AllDoneSteps { @((New-GStep 'EnableUpdates' 'Succeeded'), (New-GStep 'WindowsUpdate' 'Succeeded'), (New-GStep 'Pkg:VmTools' 'Succeeded')) }
}

AfterAll { Remove-Variable -Name GITestCtx -Scope Global -ErrorAction SilentlyContinue }

Describe 'Guest watcher host side' {
BeforeEach {
    InModuleScope VDI-GIPipeline {
        function script:Copy-VMGuestFile { param($Source, $Destination, $VM, [switch] $LocalToGuest, [switch] $GuestToLocal, $GuestCredential, [switch] $Force, $ErrorAction) }
    }
    Mock -ModuleName VDI-GIPipeline Write-GILog { }
    Mock -ModuleName VDI-GIPipeline Start-Sleep { }
    $script:cfg = New-WConfig
    $script:cred = [pscredential]::new('admin', (ConvertTo-SecureString 'x' -AsPlainText -Force))
    $script:vm = [pscustomobject]@{ Name = 'GI-VM'; Id = 'vm-1' }
}

Describe 'Test-GIWatcherDead' {
    BeforeAll { $script:now = '2026-11-25T10:00:00+00:00' }
    It 'is true only for an old heartbeat and a dead pid' {
        Test-GIWatcherDead -Watcher @{ state = 'Running'; heartbeat = '2026-11-25T09:50:00+00:00' } -PidAlive $false -Now $now -StaleSec 180 | Should -BeTrue
    }
    It 'is false for a fresh heartbeat' {
        Test-GIWatcherDead -Watcher @{ state = 'Running'; heartbeat = '2026-11-25T09:59:30+00:00' } -PidAlive $false -Now $now -StaleSec 180 | Should -BeFalse
    }
    It 'is false while the pid is alive, however old the heartbeat' {
        Test-GIWatcherDead -Watcher @{ state = 'Running'; heartbeat = '2026-11-25T08:00:00+00:00' } -PidAlive $true -Now $now -StaleSec 180 | Should -BeFalse
    }
    It 'is false for Exited (AllDone) and RebootRequested' {
        Test-GIWatcherDead -Watcher @{ state = 'Exited'; exitReason = 'AllDone'; heartbeat = '2026-11-25T08:00:00+00:00' } -PidAlive $false -Now $now -StaleSec 180 | Should -BeFalse
        Test-GIWatcherDead -Watcher @{ state = 'RebootRequested'; heartbeat = '2026-11-25T08:00:00+00:00' } -PidAlive $false -Now $now -StaleSec 180 | Should -BeFalse
    }
    It 'is false without a watcher file' {
        Test-GIWatcherDead -Watcher $null -PidAlive $false -Now $now -StaleSec 180 | Should -BeFalse
    }
    It 'uses the guest time, not the host clock' {
        # The heartbeat is years behind the host clock but only 60 s behind the guest's "now"
        Test-GIWatcherDead -Watcher @{ state = 'Running'; heartbeat = '2020-01-01T00:00:00+00:00' } -PidAlive $false -Now '2020-01-01T00:01:00+00:00' -StaleSec 180 | Should -BeFalse
        Test-GIWatcherDead -Watcher @{ state = 'Running'; heartbeat = '2020-01-01T00:00:00+00:00' } -PidAlive $false -Now '2020-01-01T00:05:00+00:00' -StaleSec 180 | Should -BeTrue
    }
    It 'reads datetime values as well as strings' {
        Test-GIWatcherDead -Watcher ([pscustomobject]@{ state = 'Running'; heartbeat = [datetime]'2026-11-25T09:00:00Z' }) -PidAlive $false -Now ([datetime]'2026-11-25T10:00:00Z') -StaleSec 180 | Should -BeTrue
    }
}

Describe 'Split-GIWatcherLogChunk' {
    function script:B([string] $t) { , [System.Text.Encoding]::UTF8.GetBytes($t) }
    It 'returns complete lines and the offset after the last LF' {
        $r = Split-GIWatcherLogChunk -Bytes (B "a`r`nb`r`n") -Offset 100
        $r.Lines | Should -Be @('a', 'b')
        $r.NextOffset | Should -Be 106
    }
    It 'leaves a trailing partial line for the next tick' {
        $r = Split-GIWatcherLogChunk -Bytes (B "one`ntwo-part") -Offset 0
        $r.Lines | Should -Be @('one')
        $r.NextOffset | Should -Be 4
        $r2 = Split-GIWatcherLogChunk -Bytes (B "two-partial`n") -Offset $r.NextOffset
        $r2.Lines | Should -Be @('two-partial')
        $r2.NextOffset | Should -Be 16
    }
    It 'handles bare LF, CRLF and blank lines' {
        (Split-GIWatcherLogChunk -Bytes (B "a`n`nb`r`n") -Offset 0).Lines | Should -Be @('a', '', 'b')
    }
    It 'handles a single complete line' {
        $r = Split-GIWatcherLogChunk -Bytes (B "only`n") -Offset 7
        $r.Lines | Should -Be @('only')
        $r.NextOffset | Should -Be 12
    }
    It 'does not split a multibyte character across ticks' {
        $all = [System.Text.Encoding]::UTF8.GetBytes("x`u{00E9}`u{20AC}y`nrest")   # e-acute (2 bytes), euro (3 bytes)
        # First read ends inside the euro sign and has no LF yet: nothing is delivered, offset stays
        $first = $all[0..3]
        $r1 = Split-GIWatcherLogChunk -Bytes $first -Offset 0
        $r1.Lines.Count | Should -Be 0
        $r1.NextOffset | Should -Be 0
        # Next read starts at the same offset and covers the whole line
        $r2 = Split-GIWatcherLogChunk -Bytes $all -Offset 0
        $r2.Lines | Should -Be @("x`u{00E9}`u{20AC}y")
        $r2.NextOffset | Should -Be 8
    }
    It 'returns nothing for an empty chunk' {
        $r = Split-GIWatcherLogChunk -Bytes ([byte[]]@()) -Offset 55
        $r.Lines.Count | Should -Be 0
        $r.NextOffset | Should -Be 55
        (Split-GIWatcherLogChunk -Bytes $null -Offset 3).NextOffset | Should -Be 3
    }
    It 'delivers a maximum-size chunk without any LF as one line so a huge line cannot stall the log' {
        $big = [byte[]]::new(65536); [array]::Fill($big, [byte]65)
        $r = Split-GIWatcherLogChunk -Bytes $big -Offset 0
        $r.Lines.Count | Should -Be 1
        $r.NextOffset | Should -Be 65536
    }
}

Describe 'Poll script and parsing' {
    It 'builds a 5.1-safe script with the offset, quoted folder and a share-friendly log open' {
        $t = Get-GIWatcherPollScript -WorkDir "C:\Data\O'Brien" -LogOffset 1234 -IncludeSteps
        $t | Should -Match ([regex]::Escape("`$w = 'C:\Data\O''Brien'"))
        $t | Should -Match '\[long\]1234'
        $t | Should -Match '\$inc = \$true'
        $t | Should -Match 'FileShare\]::ReadWrite'
        $t | Should -Match '65536'
        $t | Should -Not -Match '\?\?'
        (Get-GIWatcherPollScript -WorkDir 'C:\W' -LogOffset 0) | Should -Match '\$inc = \$false'
        [scriptblock]::Create($t) | Should -Not -BeNullOrEmpty
    }
    It 'rejects a work folder that could break the quoting' {
        { Get-GIWatcherPollScript -WorkDir 'C:\W"; calc; "' -LogOffset 0 } | Should -Throw '*not a usable absolute guest path*'
    }
    It 'parses a tick, keeps the last good JSON and decodes the log bytes' {
        $p = ConvertFrom-GIWatcherPoll -Text ("noise`r`n" + (New-PollText -Watcher (New-GWatcher) -Offset 5 -Size 9 -LogBytes ([System.Text.Encoding]::UTF8.GetBytes("hi`n")) -Steps @((New-GStep 'Pkg:VmTools'))) + "`r`n")
        $p.Now | Should -BeOfType [datetimeoffset]
        $p.Watcher.state | Should -Be 'Running'
        $p.PidAlive | Should -BeTrue
        @($p.Steps).Count | Should -Be 1
        $p.Steps[0].attemptStartedAt | Should -BeOfType [string]
        $p.Log.Offset | Should -Be 5
        [System.Text.Encoding]::UTF8.GetString($p.Log.Bytes) | Should -Be "hi`n"
    }
    It 'returns null steps when they were not requested and null for unparsable watcher.json' {
        $o = New-PollText
        $p = ConvertFrom-GIWatcherPoll -Text $o
        $p.Steps | Should -BeNullOrEmpty
        $p.Watcher | Should -BeNullOrEmpty
        $bad = ($o | ConvertFrom-Json); $bad.watcher = '{not json'
        (ConvertFrom-GIWatcherPoll -Text ($bad | ConvertTo-Json -Compress)).Watcher | Should -BeNullOrEmpty
    }
    It 'throws on output that is not a poll result' {
        { ConvertFrom-GIWatcherPoll -Text 'Access denied' } | Should -Throw '*Unexpected guest watcher poll output*'
    }
}

Describe 'Get-GIWatcherPollInterval' {
    It 'uses the fast interval while the run page is watched, the idle one otherwise' {
        Mock -ModuleName VDI-GIPipeline Get-GIRunWatchingAge { 5.0 }
        Get-GIWatcherPollInterval -Config $cfg -RunId 'r' | Should -Be 10
        Mock -ModuleName VDI-GIPipeline Get-GIRunWatchingAge { 31.0 }
        Get-GIWatcherPollInterval -Config $cfg -RunId 'r' | Should -Be 60
        Mock -ModuleName VDI-GIPipeline Get-GIRunWatchingAge { [double]::MaxValue }
        Get-GIWatcherPollInterval -Config $cfg -RunId 'r' | Should -Be 60
    }
    It 'honors configured values' {
        $cfg.GoldenImage.Watcher = @{ LogPollSec = 3; IdlePollSec = 20; WatchingWindowSec = 100 }
        Mock -ModuleName VDI-GIPipeline Get-GIRunWatchingAge { 50.0 }
        Get-GIWatcherPollInterval -Config $cfg -RunId 'r' | Should -Be 3
    }
}

Describe 'ConvertTo-GIRunStepUpdate' {
    It 'maps Pending' {
        $u = ConvertTo-GIRunStepUpdate -GuestStep (New-GStep 'Pkg:VmTools' 'Pending' 0 '')
        $u.Status | Should -Be 'Pending'; $u.Message | Should -Be ''
    }
    It 'maps Running with and without an attempt prefix' {
        (ConvertTo-GIRunStepUpdate -GuestStep (New-GStep 'Pkg:VmTools' 'Running' 1 'Installing')).Message | Should -Be 'Installing'
        $u = ConvertTo-GIRunStepUpdate -GuestStep (New-GStep 'Pkg:VmTools' 'Running' 2 'Installing')
        $u.Status | Should -Be 'Running'; $u.Message | Should -Be 'Attempt 2: Installing'; $u.Attempt | Should -Be 2
    }
    It 'maps Fixing to Running with the fix id' {
        $u = ConvertTo-GIRunStepUpdate -GuestStep (New-GStep 'Pkg:VmTools' 'Fixing' 2 'Attempt 1 failed; applying fix RegistryKeyMarkedForDeletion')
        $u.Status | Should -Be 'Running'
        $u.Message | Should -Be 'Attempt 2: applying fix RegistryKeyMarkedForDeletion'
    }
    It 'maps RebootRequired for a pending fix, Windows Update and an installer' {
        (ConvertTo-GIRunStepUpdate -GuestStep (New-GStep 'Pkg:VmTools' 'RebootRequired' 2 'x' -Extra @{ pendingFix = @{ id = 'FixA'; fixAttempt = 2 } })).Message | Should -Be 'Reboot requested (FixA)'
        (ConvertTo-GIRunStepUpdate -GuestStep (New-GStep 'WindowsUpdate' 'RebootRequired' 1 'x' -Extra @{ data = @{ pass = 2 } })).Message | Should -Be 'Reboot requested (Windows Update pass 2)'
        $u = ConvertTo-GIRunStepUpdate -GuestStep (New-GStep 'Pkg:Horizon' 'RebootRequired' 1 'x')
        $u.Status | Should -Be 'Running'; $u.Message | Should -Be 'Reboot requested (installer)'
    }
    It 'maps Succeeded, adding the fixes that were applied' {
        (ConvertTo-GIRunStepUpdate -GuestStep (New-GStep 'Pkg:VmTools' 'Succeeded' 1 'Installed version 12.5')).Message | Should -Be 'Installed version 12.5'
        $fx = @(@{ id = 'FixA'; fixAttempt = 1; outcome = 'Applied' }, @{ id = 'FixA'; fixAttempt = 2; outcome = 'Applied' }, @{ id = 'FixB'; fixAttempt = 1; outcome = 'FixFailed' })
        $u = ConvertTo-GIRunStepUpdate -GuestStep (New-GStep 'Pkg:VmTools' 'Succeeded' 3 'Installed version 12.5' -Extra @{ fixApplied = $fx })
        $u.Status | Should -Be 'Succeeded'
        $u.Message | Should -Be 'Installed version 12.5; fixed by FixA, FixB'
        @($u.Fixes).Count | Should -Be 3
        $u.Fixes[0].id | Should -Be 'FixA'
    }
    It 'maps Failed with the guest message' {
        $u = ConvertTo-GIRunStepUpdate -GuestStep (New-GStep 'Pkg:VmTools' 'Failed' 4 "In-guest action 'VmTools' exited 1: boom")
        $u.Status | Should -Be 'Failed'; $u.Message | Should -Be "In-guest action 'VmTools' exited 1: boom"
    }
    It 'tolerates a step file with missing fields' {
        { ConvertTo-GIRunStepUpdate -GuestStep ([pscustomobject]@{ id = 'WindowsUpdate'; status = 'Running' }) } | Should -Not -Throw
    }
}

Describe 'Sync-GIWatcherSteps' {
    It 'sets status, message, attempt and fixes on the run step' {
        $run = New-WRun $cfg
        $g = New-GStep 'Pkg:VmTools' 'Running' 2 'Installing' -Extra @{ fixApplied = @(@{ id = 'FixA'; fixAttempt = 1; outcome = 'Applied' }) }
        Sync-GIWatcherSteps -Config $cfg -Run $run -GuestSteps @($g) -AttemptId 'A1' | Should -Be 1
        $s = Get-GIStep -Run $run -Id 'Pkg:VmTools'
        $s.status | Should -Be 'Running'
        $s.message | Should -Be 'Attempt 2: Installing'
        $s.attempt | Should -Be 2
        @($s.fixes).Count | Should -Be 1
        $s.fixes[0].id | Should -Be 'FixA'
        $s.startedAt | Should -Not -BeNullOrEmpty
    }
    It 'does not save the run when nothing changed' {
        $run = New-WRun $cfg
        $g = New-GStep 'Pkg:VmTools' 'Running' 1 'Installing'
        $null = Sync-GIWatcherSteps -Config $cfg -Run $run -GuestSteps @($g) -AttemptId 'A1'
        Mock -ModuleName VDI-GIPipeline Save-GIRun { }
        Sync-GIWatcherSteps -Config $cfg -Run $run -GuestSteps @($g) -AttemptId 'A1' | Should -Be 0
        Should -Invoke -ModuleName VDI-GIPipeline Save-GIRun -Times 0 -Exactly
    }
    It 'keeps startedAt while a running step only changes its message' {
        $run = New-WRun $cfg
        $null = Sync-GIWatcherSteps -Config $cfg -Run $run -GuestSteps @((New-GStep 'Pkg:VmTools' 'Running' 1 'one')) -AttemptId 'A1'
        $started = (Get-GIStep -Run $run -Id 'Pkg:VmTools').startedAt
        $null = Sync-GIWatcherSteps -Config $cfg -Run $run -GuestSteps @((New-GStep 'Pkg:VmTools' 'Running' 1 'two')) -AttemptId 'A1'
        (Get-GIStep -Run $run -Id 'Pkg:VmTools').startedAt | Should -Be $started
        (Get-GIStep -Run $run -Id 'Pkg:VmTools').message | Should -Be 'two'
    }
    It 'ignores steps of another attempt, unknown ids and skipped steps' {
        $run = New-WRun $cfg
        $old = New-GStep 'Pkg:VmTools' 'Succeeded'; $old.attemptId = 'OLD'
        Sync-GIWatcherSteps -Config $cfg -Run $run -GuestSteps @($old, (New-GStep 'Pkg:Nope' 'Running')) -AttemptId 'A1' | Should -Be 0
        (Get-GIStep -Run $run -Id 'Pkg:VmTools').status | Should -Be 'Pending'
        $cfg.GoldenImage.WindowsUpdate.Enabled = $false
        $run2 = New-WRun $cfg
        Sync-GIWatcherSteps -Config $cfg -Run $run2 -GuestSteps @((New-GStep 'WindowsUpdate' 'Running')) -AttemptId 'A1' | Should -Be 0
        (Get-GIStep -Run $run2 -Id 'WindowsUpdate').status | Should -Be 'Skipped'
    }
}

Describe 'Test-GIStepTimedOut' {
    It 'measures the current attempt, not the first start of the step' {
        $s = New-GStep 'Pkg:VmTools' 'Running' 2 -Started '2026-11-25T07:00:00+00:00' -Extra @{ attemptStartedAt = '2026-11-25T09:30:00+00:00' }
        Test-GIStepTimedOut -Step $s -Now '2026-11-25T10:00:00+00:00' -TimeoutMin 60 | Should -BeFalse
        Test-GIStepTimedOut -Step $s -Now '2026-11-25T10:31:00+00:00' -TimeoutMin 60 | Should -BeTrue
    }
    It 'applies to Running and Fixing only' {
        foreach ($st in 'Pending', 'RebootRequired', 'Succeeded', 'Failed') {
            Test-GIStepTimedOut -Step (New-GStep 'Pkg:VmTools' $st -Started '2026-11-25T01:00:00+00:00' -Extra @{ attemptStartedAt = '2026-11-25T01:00:00+00:00' }) -Now '2026-11-25T10:00:00+00:00' -TimeoutMin 60 | Should -BeFalse
        }
        Test-GIStepTimedOut -Step (New-GStep 'Pkg:VmTools' 'Fixing' -Extra @{ attemptStartedAt = '2026-11-25T01:00:00+00:00' }) -Now '2026-11-25T10:00:00+00:00' -TimeoutMin 60 | Should -BeTrue
    }
}

Describe 'New-GIWatcherPlan' {
    It 'lists the guest steps in order with ids matching the run and the config values' {
        $run = New-WRun $cfg
        $p = New-GIWatcherPlan -Config $cfg -Run $run -AttemptId 'att-1' -LaunchId 'l-1'
        @($p.steps.id) | Should -Be @('EnableUpdates', 'WindowsUpdate', 'Pkg:VmTools')
        @($p.steps.id | Where-Object { $_ -in @(Get-GIStepList -Run $run).id }).Count | Should -Be 3
        $p.steps[0].action | Should -Be 'Update'
        $p.steps[1].kind | Should -Be 'WindowsUpdate'
        $p.steps[1].maxPasses | Should -Be 3
        $p.steps[2].action | Should -Be 'VmTools'
        $p.attemptId | Should -Be 'att-1'; $p.launchId | Should -Be 'l-1'; $p.runId | Should -Be $run.runId
        $p.workDir | Should -Be 'C:\ProgramData\VDI\Pipeline'
        $p.installDir | Should -Be 'C:\ProgramData\VDI\Install'
        $p.logDir | Should -Be 'C:\ProgramData\VDI\Logs'
        $p.scriptPath | Should -Be 'C:\ProgramData\VDI\VDI-GoldenImage.ps1'
        $p.settings.heartbeatSec | Should -Be 15
        $p.settings.maxStepAttempts | Should -Be 5
        $p.settings.fixTimeoutSec | Should -Be 300
    }
    It 'leaves out Succeeded and Skipped steps' {
        $cfg.GoldenImage.Actions = @('VmTools', 'Horizon')
        $run = New-WRun $cfg
        Set-GIStep -Config $cfg -Run $run -Id 'EnableUpdates' -Status Succeeded -Message 'Done'
        Set-GIStep -Config $cfg -Run $run -Id 'Pkg:VmTools' -Status Succeeded -Message 'Done'
        @((New-GIWatcherPlan -Config $cfg -Run $run -AttemptId 'a').steps.id) | Should -Be @('WindowsUpdate', 'Pkg:Horizon')
        $cfg.GoldenImage.WindowsUpdate.Enabled = $false
        $run2 = New-WRun $cfg
        @((New-GIWatcherPlan -Config $cfg -Run $run2 -AttemptId 'a').steps.id) | Should -Be @('EnableUpdates', 'Pkg:VmTools', 'Pkg:Horizon')
    }
    It 'is empty when no guest step is left' {
        $cfg.GoldenImage.Actions = @(); $cfg.GoldenImage.WindowsUpdate.Enabled = $false
        $run = New-WRun $cfg
        Set-GIStep -Config $cfg -Run $run -Id 'EnableUpdates' -Status Succeeded -Message 'Done'
        @((New-GIWatcherPlan -Config $cfg -Run $run -AttemptId 'a').steps).Count | Should -Be 0
        @(Get-GIWatcherStepIds -Run $run).Count | Should -Be 0
    }
}

Describe 'Test-GIGuestWorkDirSafe' {
    It 'accepts a pipeline-owned subfolder' {
        Test-GIGuestWorkDirSafe -WorkDir 'C:\ProgramData\VDI\Pipeline' -ScriptPath 'C:\ProgramData\VDI\VDI-GoldenImage.ps1' | Should -BeTrue
        Test-GIGuestWorkDirSafe -WorkDir 'C:\ProgramData\VDI\Pipeline\' -ScriptPath 'C:\ProgramData\VDI\VDI-GoldenImage.ps1' | Should -BeTrue
    }
    It 'refuses empty, relative and root paths' {
        foreach ($bad in '', '  ', 'Pipeline', 'C:', 'C:\', 'c:\\', '\\server\share') {
            Test-GIGuestWorkDirSafe -WorkDir $bad -ScriptPath 'C:\ProgramData\VDI\VDI-GoldenImage.ps1' | Should -BeFalse -Because "'$bad'"
        }
    }
    It 'refuses the script folder and its parents, any case' {
        Test-GIGuestWorkDirSafe -WorkDir 'C:\ProgramData\VDI' -ScriptPath 'C:\ProgramData\VDI\VDI-GoldenImage.ps1' | Should -BeFalse
        Test-GIGuestWorkDirSafe -WorkDir 'c:\programdata\vdi\' -ScriptPath 'C:\ProgramData\VDI\VDI-GoldenImage.ps1' | Should -BeFalse
        Test-GIGuestWorkDirSafe -WorkDir 'C:\ProgramData' -ScriptPath 'C:\ProgramData\VDI\VDI-GoldenImage.ps1' | Should -BeFalse
        Test-GIGuestWorkDirSafe -WorkDir 'C:\ProgramData\VDI\..\VDI' -ScriptPath 'C:\ProgramData\VDI\VDI-GoldenImage.ps1' | Should -BeFalse
    }
    It 'accepts a sibling whose name starts like the script folder' {
        Test-GIGuestWorkDirSafe -WorkDir 'C:\ProgramData\VDI2' -ScriptPath 'C:\ProgramData\VDI\VDI-GoldenImage.ps1' | Should -BeTrue
    }
}

Describe 'Start-GIGuestWatcher' {
    BeforeEach {
        $src = Join-Path $cfg.Root 'guest'
        New-Item -ItemType Directory -Path (Join-Path $src 'fixes') -Force | Out-Null
        foreach ($f in 'Invoke-GIWatcher.ps1', 'GIWatcher.Core.ps1', 'Invoke-GIFixRunner.ps1', 'Invoke-GIWindowsUpdate.ps1', 'fixes/FixA.ps1') { Set-Content -LiteralPath (Join-Path $src $f) -Value '# x' }
        Set-ModVar Scripts ([System.Collections.Generic.List[string]]::new())
        Set-ModVar Copies ([System.Collections.Generic.List[object]]::new())
        Set-ModVar Plan $null
        Mock -ModuleName VDI-GIPipeline Invoke-GIGuestScript { $global:GITestCtx.Scripts.Add($ScriptText); [pscustomobject]@{ ExitCode = 0; ScriptOutput = "2026-11-25T09:00:00.0000000+00:00`r`n" } }
        Mock -ModuleName VDI-GIPipeline Copy-VMGuestFile {
            $global:GITestCtx.Copies.Add(@{ Source = $Source; Destination = $Destination })
            if ($Source -like '*.json') { $global:GITestCtx.Plan = Get-Content -LiteralPath $Source -Raw | ConvertFrom-Json }
        }
    }
    It 'copies the watcher files and fixes, writes plan.json and starts the task' {
        $run = New-WRun $cfg
        $r = Start-GIGuestWatcher -Config $cfg -Run $run -VM $vm -Credential $cred -AttemptId 'att-1'
        $dest = @($global:GITestCtx.Copies | ForEach-Object { "$($_.Destination)" })
        @($global:GITestCtx.Copies | Where-Object { $_.Destination -eq 'C:\ProgramData\VDI\Pipeline\watcher\' } | ForEach-Object { Split-Path $_.Source -Leaf }) |
            Should -Be @('Invoke-GIWatcher.ps1', 'GIWatcher.Core.ps1', 'Invoke-GIFixRunner.ps1', 'Invoke-GIWindowsUpdate.ps1')
        @($global:GITestCtx.Copies | Where-Object { $_.Destination -eq 'C:\ProgramData\VDI\Pipeline\fixes\' } | ForEach-Object { Split-Path $_.Source -Leaf }) | Should -Be @('FixA.ps1')
        $dest | Should -Contain 'C:\ProgramData\VDI\Pipeline\plan.json'
        $global:GITestCtx.Plan.attemptId | Should -Be 'att-1'
        $global:GITestCtx.Plan.launchId | Should -Be $r.LaunchId
        @($global:GITestCtx.Plan.steps.id) | Should -Be @('EnableUpdates', 'WindowsUpdate', 'Pkg:VmTools')
        $r.BootTime | Should -Be '2026-11-25T09:00:00.0000000+00:00'
        $launch = $global:GITestCtx.Scripts[-1]
        $launch | Should -Match 'New-ScheduledTaskSettingsSet -ExecutionTimeLimit \(\[TimeSpan\]::Zero\)'
        $launch | Should -Match "-User 'SYSTEM' -RunLevel Highest -Force"
        $launch | Should -Match 'Start-ScheduledTask -TaskName ''VDI-GI-Watcher'''
        $launch | Should -Match 'Invoke-GIWatcher.ps1'
        $launch | Should -Match '-WorkDir'
        [scriptblock]::Create($launch) | Should -Not -BeNullOrEmpty
        $prep = $global:GITestCtx.Scripts[0]
        $prep | Should -Match 'Remove-Item -Path "\$w\\fixes\\\*"'
        $prep | Should -Not -Match 'steps'
    }
    It 'deletes the steps folder (and old log) with -ResetSteps' {
        $run = New-WRun $cfg
        $null = Start-GIGuestWatcher -Config $cfg -Run $run -VM $vm -Credential $cred -AttemptId 'a' -ResetSteps
        $global:GITestCtx.Scripts[0] | Should -Match '\$w\\steps'
        [scriptblock]::Create($global:GITestCtx.Scripts[0]) | Should -Not -BeNullOrEmpty
    }
    It 'gives every launch a new launch id' {
        $run = New-WRun $cfg
        $a = Start-GIGuestWatcher -Config $cfg -Run $run -VM $vm -Credential $cred -AttemptId 'a'
        $b = Start-GIGuestWatcher -Config $cfg -Run $run -VM $vm -Credential $cred -AttemptId 'a'
        $a.LaunchId | Should -Not -Be $b.LaunchId
    }
    It 'throws a clear error, before touching the guest, when a source file is missing' {
        Remove-Item -LiteralPath (Join-Path $cfg.Root 'guest/Invoke-GIFixRunner.ps1')
        $run = New-WRun $cfg
        { Start-GIGuestWatcher -Config $cfg -Run $run -VM $vm -Credential $cred -AttemptId 'a' } | Should -Throw '*Invoke-GIFixRunner.ps1*'
        Should -Invoke -ModuleName VDI-GIPipeline Invoke-GIGuestScript -Times 0 -Exactly
    }
}

Describe 'Stop-GIGuestWatcher' {
    It 'stops the task, the watcher tree, msiexec and install-folder processes' {
        Set-ModVar Scripts ([System.Collections.Generic.List[string]]::new())
        Mock -ModuleName VDI-GIPipeline Invoke-GIGuestScript { $global:GITestCtx.Scripts.Add($ScriptText); [pscustomobject]@{ ExitCode = 0; ScriptOutput = '' } }
        Stop-GIGuestWatcher -VM $vm -Credential $cred -WorkDir 'C:\W' -Pid 4242 -InstallDir "C:\Data\O'B\Install"
        $t = $global:GITestCtx.Scripts[0]
        $t | Should -Match 'Stop-ScheduledTask'
        $t | Should -Match 'Stop-Tree 4242'
        $t | Should -Match 'msiexec'
        $t | Should -Match ([regex]::Escape("-like 'C:\Data\O''B\Install\*'"))
    }
}

Describe 'Remove-GIGuestWatcher' {
    BeforeEach {
        Set-ModVar Order ([System.Collections.Generic.List[string]]::new())
        Set-ModVar Scripts ([System.Collections.Generic.List[string]]::new())
        Set-ModVar CopyFails $false
        Mock -ModuleName VDI-GIPipeline Copy-VMGuestFile {
            $global:GITestCtx.Order.Add("copy:$Source->$Destination")
            if ($global:GITestCtx.CopyFails) { throw 'file not found' }
        }
        Mock -ModuleName VDI-GIPipeline Invoke-GIGuestScript { $global:GITestCtx.Order.Add('script'); $global:GITestCtx.Scripts.Add($ScriptText); [pscustomobject]@{ ExitCode = 0; ScriptOutput = '' } }
        $script:run = New-WRun $cfg
    }
    It 'copies the guest log first, then unregisters the task and deletes the folder' {
        Remove-GIGuestWatcher -Config $cfg -Run $run -VM $vm -Credential $cred
        $global:GITestCtx.Order[0] | Should -BeLike 'copy:C:\ProgramData\VDI\Pipeline\watcher.log->*20261125-100000.watcher.guest.log'
        $global:GITestCtx.Order[1] | Should -Be 'script'
        $t = $global:GITestCtx.Scripts[0]
        $t | Should -Match 'Unregister-ScheduledTask -TaskName ''VDI-GI-Watcher'''
        $t | Should -Match ([regex]::Escape("`$w = 'C:\ProgramData\VDI\Pipeline'"))
        $t | Should -Match 'Remove-Item -LiteralPath \$w -Recurse -Force'
    }
    It 'still deletes when the log copy fails, and only warns' {
        Set-ModVar CopyFails $true
        { Remove-GIGuestWatcher -Config $cfg -Run $run -VM $vm -Credential $cred } | Should -Not -Throw
        @($global:GITestCtx.Scripts).Count | Should -Be 1
        Should -Invoke -ModuleName VDI-GIPipeline Write-GILog -ParameterFilter { $Level -eq 'Warn' -and $Message -like "*Couldn't copy*file not found*" }
    }
    It 'refuses an unsafe folder without calling the guest' {
        foreach ($bad in 'C:\', 'C:\ProgramData\VDI', 'C:\ProgramData') {
            $cfg.GoldenImage.GuestWorkDir = $bad
            { Remove-GIGuestWatcher -Config $cfg -Run $run -VM $vm -Credential $cred } | Should -Throw '*Refusing to delete guest folder*'
        }
        Should -Invoke -ModuleName VDI-GIPipeline Invoke-GIGuestScript -Times 0 -Exactly
        Should -Invoke -ModuleName VDI-GIPipeline Copy-VMGuestFile -Times 0 -Exactly
    }
}

Describe 'Wait-GIGuestWatcher' {
    BeforeEach {
        Set-ModVar Queue ([System.Collections.Generic.List[string]]::new())
        Set-ModVar Scripts ([System.Collections.Generic.List[string]]::new())
        Set-ModVar Starts ([System.Collections.Generic.List[hashtable]]::new())
        Set-ModVar Stops ([System.Collections.Generic.List[hashtable]]::new())
        Set-ModVar Restarts 0
        Set-ModVar NextBoot '2026-11-25T09:00:00+00:00'
        Mock -ModuleName VDI-GIPipeline Get-GIRunWatchingAge { 1.0 }
        Mock -ModuleName VDI-GIPipeline Invoke-GIGuestScript {
            $global:GITestCtx.Scripts.Add($ScriptText)
            $q = $global:GITestCtx.Queue
            if (-not $q.Count) { throw 'queue empty' }
            $x = $q[0]; $q.RemoveAt(0)
            if ($x -eq 'THROW') { throw 'guest operations unavailable' }
            [pscustomobject]@{ ExitCode = 0; ScriptOutput = $x }
        }
        Mock -ModuleName VDI-GIPipeline Restart-GIGuest { $global:GITestCtx.Restarts++ }
        Mock -ModuleName VDI-GIPipeline Start-GIGuestWatcher {
            $global:GITestCtx.Starts.Add(@{ AttemptId = $AttemptId; Reset = [bool]$ResetSteps })
            @{ LaunchId = "L$($global:GITestCtx.Starts.Count + 1)"; BootTime = $global:GITestCtx.NextBoot }
        }
        Mock -ModuleName VDI-GIPipeline Stop-GIGuestWatcher { $global:GITestCtx.Stops.Add(@{ Pid = $WatcherPid; Install = $InstallDir }) }
        $script:run = New-WRun $cfg
        Set-GIWatcherState -Config $cfg -Run $run -State @{ logOffset = 0; launchId = 'L1'; attemptId = 'A1'; bootTime = '2026-11-25T09:00:00+00:00'; relaunches = 0 }
        $script:slept = [System.Collections.Generic.List[double]]::new()
        $script:sleep = { param($s) $script:slept.Add($s) }
        function script:Q([string[]] $Items) { foreach ($i in $Items) { $global:GITestCtx.Queue.Add($i) } }
        function script:Run { Wait-GIGuestWatcher -Config $cfg -Run $run -VM $vm -Credential $cred -AttemptId 'A1' -SleepAction $script:sleep }
        function script:Saved { (Get-GIRun -Config $cfg -RunId $run.runId).stages.Maintain.data.watcher }
        $script:hostLog = Join-Path $cfg.Paths.Logs "$($run.runId).watcher.log"
    }

    It 'returns at once when no guest step is left' {
        foreach ($id in 'EnableUpdates', 'WindowsUpdate', 'Pkg:VmTools') { Set-GIStep -Config $cfg -Run $run -Id $id -Status Succeeded -Message 'x' }
        @(Run).Count | Should -Be 0
        Should -Invoke -ModuleName VDI-GIPipeline Invoke-GIGuestScript -Times 0 -Exactly
    }

    It 'finishes when the watcher exited AllDone with every step Succeeded, mirroring the steps' {
        $steps = @((New-GStep 'EnableUpdates' 'Succeeded' 1 'Done'), (New-GStep 'WindowsUpdate' 'Succeeded' 1 '1 pass(es), 3 update(s) installed'), (New-GStep 'Pkg:VmTools' 'Succeeded' 2 'Installed version 12.5'))
        Q (New-PollText -Watcher (New-GWatcher 'Exited' 'AllDone') -Steps $steps)
        $r = Run
        @($r).Count | Should -Be 3
        (Get-GIStep -Run $run -Id 'Pkg:VmTools').status | Should -Be 'Succeeded'
        (Get-GIStep -Run $run -Id 'Pkg:VmTools').message | Should -Be 'Installed version 12.5'
        (Get-GIStep -Run $run -Id 'Pkg:VmTools').attempt | Should -Be 2
        $script:slept.Count | Should -Be 0
    }

    It 'asks for steps on the first tick only, then every StatusPollSec' {
        $cfg.GoldenImage.Watcher.StatusPollSec = 60
        Mock -ModuleName VDI-GIPipeline Get-GIRunWatchingAge { [double]::MaxValue }   # idle interval 60 s
        $running = New-GWatcher
        Q (New-PollText -Watcher $running -Steps @((New-GStep 'Pkg:VmTools')))
        Q (New-PollText -Watcher $running)
        Q (New-PollText -Watcher (New-GWatcher 'Exited' 'AllDone') -Steps (Get-AllDoneSteps))
        $null = Run
        $global:GITestCtx.Scripts[0] | Should -Match '\$inc = \$true'
        $global:GITestCtx.Scripts[1] | Should -Match '\$inc = \$true'   # 60 s idle tick reached StatusPollSec
        @($script:slept) | Should -Be @(60, 60)
    }

    It 'appends complete log lines, stores the offset and leaves a partial line for the next tick' {
        $w = New-GWatcher
        $b1 = [System.Text.Encoding]::UTF8.GetBytes("l1`r`nl2`r`npart")
        Q (New-PollText -Watcher $w -Offset 0 -Size 15 -LogBytes $b1 -Steps @((New-GStep 'Pkg:VmTools')))
        Q (New-PollText -Watcher (New-GWatcher 'Exited' 'AllDone') -Offset 8 -Size 16 -LogBytes ([System.Text.Encoding]::UTF8.GetBytes("part-2`r`n")) -Steps (Get-AllDoneSteps))
        $null = Run
        (Get-Content -LiteralPath $hostLog -Raw) | Should -Be "l1`r`nl2`r`npart-2`r`n"
        $global:GITestCtx.Scripts[1] | Should -Match '\[long\]8'
        (Saved).logOffset | Should -Be 16
    }

    It 'resets the offset when the guest log is shorter than the stored offset' {
        Set-GIWatcherState -Config $cfg -Run $run -State @{ logOffset = 500; launchId = 'L1'; attemptId = 'A1'; bootTime = '2026-11-25T09:00:00+00:00'; relaunches = 0 }
        Q (New-PollText -Watcher (New-GWatcher) -Offset 500 -Size 100 -Steps @((New-GStep 'Pkg:VmTools')))
        Q (New-PollText -Watcher (New-GWatcher 'Exited' 'AllDone') -Offset 0 -Size 6 -LogBytes ([System.Text.Encoding]::UTF8.GetBytes("fresh`n")) -Steps (Get-AllDoneSteps))
        $null = Run
        $global:GITestCtx.Scripts[1] | Should -Match '\[long\]0'
        (Get-Content -LiteralPath $hostLog -Raw) | Should -Be "fresh`r`n"
        (Saved).logOffset | Should -Be 6
    }

    It 'restarts the guest on RebootRequested, relaunches with the same attempt id and does not count it' {
        $steps1 = @((New-GStep 'EnableUpdates' 'Succeeded'), (New-GStep 'WindowsUpdate' 'RebootRequired' 1 'x' -Extra @{ data = @{ pass = 1 } }))
        Set-ModVar NextBoot '2026-11-25T11:00:00+00:00'
        Q (New-PollText -Watcher (New-GWatcher 'RebootRequested' 'RebootRequested' 'L1' -Step 'WindowsUpdate') -Steps $steps1)
        Q (New-PollText -Boot '2026-11-25T11:00:00+00:00' -Watcher (New-GWatcher 'Exited' 'AllDone' 'L2') -Steps (Get-AllDoneSteps))
        $null = Run
        $global:GITestCtx.Restarts | Should -Be 1
        $global:GITestCtx.Starts.Count | Should -Be 1
        $global:GITestCtx.Starts[0].AttemptId | Should -Be 'A1'
        $global:GITestCtx.Starts[0].Reset | Should -BeFalse
        (Saved).relaunches | Should -Be 0
        (Saved).launchId | Should -Be 'L2'
        Should -Invoke -ModuleName VDI-GIPipeline Restart-GIGuest -Times 1 -Exactly
    }

    It 'counts a boot-time change without a host reboot as a relaunch' {
        Set-ModVar NextBoot '2026-11-25T09:45:00+00:00'
        Q (New-PollText -Boot '2026-11-25T09:45:00+00:00' -Watcher (New-GWatcher) -Steps @((New-GStep 'Pkg:VmTools')))
        Q (New-PollText -Boot '2026-11-25T09:45:00+00:00' -Watcher (New-GWatcher 'Exited' 'AllDone' 'L2') -Steps (Get-AllDoneSteps))
        $null = Run
        $global:GITestCtx.Restarts | Should -Be 0
        $global:GITestCtx.Starts.Count | Should -Be 1
        (Saved).relaunches | Should -Be 1
    }

    It 'relaunches a watcher whose heartbeat is stale and whose pid is gone' {
        Q (New-PollText -Watcher (New-GWatcher -Heartbeat '2026-11-25T09:50:00+00:00') -PidAlive $false -Steps @((New-GStep 'Pkg:VmTools')))
        Q (New-PollText -Watcher (New-GWatcher 'Exited' 'AllDone' 'L2') -Steps (Get-AllDoneSteps))
        $null = Run
        (Saved).relaunches | Should -Be 1
    }

    It 'warns once, without relaunching, when the heartbeat is stale but the pid is alive' {
        $stale = New-GWatcher -Heartbeat '2026-11-25T09:50:00+00:00'
        $st = @((New-GStep 'Pkg:VmTools'))
        Q (New-PollText -Watcher $stale -PidAlive $true -Steps $st)
        Q (New-PollText -Watcher $stale -PidAlive $true -Steps $st)
        Q (New-PollText -Watcher (New-GWatcher 'Exited' 'AllDone') -Steps (Get-AllDoneSteps))
        $null = Run
        $global:GITestCtx.Starts.Count | Should -Be 0
        Should -Invoke -ModuleName VDI-GIPipeline Write-GILog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warn' -and $Message -like '*heartbeat*' }
    }

    It 'relaunches after Exited/Crashed (counted)' {
        Q (New-PollText -Watcher (New-GWatcher 'Exited' 'Crashed') -Steps @((New-GStep 'Pkg:VmTools')))
        Q (New-PollText -Watcher (New-GWatcher 'Exited' 'AllDone' 'L2') -Steps (Get-AllDoneSteps))
        $null = Run
        (Saved).relaunches | Should -Be 1
    }

    It 'throws when the watcher died more often than MaxRelaunches and marks a step Failed' {
        Set-ModVar NextBoot '2026-11-25T09:45:00+00:00'
        Q (New-PollText -Boot '2026-11-25T09:45:00+00:00' -Watcher (New-GWatcher) -Steps @((New-GStep 'Pkg:VmTools')))
        Q (New-PollText -Boot '2026-11-25T08:00:00+00:00' -Watcher (New-GWatcher -Launch 'L2') -Steps @((New-GStep 'Pkg:VmTools')))
        { Run } | Should -Throw '*Guest watcher died 2 times*'
        $global:GITestCtx.Starts.Count | Should -Be 1
        @(Get-GIStepList -Run $run | Where-Object status -eq 'Failed').Count | Should -Be 1
    }

    It 'starts a never-started watcher again after three ticks without watcher.json' {
        $none = New-PollText -Task 'Ready' -Steps @()
        Q $none, $none, $none
        Q (New-PollText -Watcher (New-GWatcher 'Exited' 'AllDone' 'L2') -Steps (Get-AllDoneSteps))
        $null = Run
        $global:GITestCtx.Starts.Count | Should -Be 1
        (Saved).relaunches | Should -Be 1
    }

    It 'ignores a watcher.json of an earlier launch' {
        Q (New-PollText -Watcher (New-GWatcher 'Exited' 'AllDone' 'OLD-LAUNCH') -Task 'Running' -Steps @())
        Q (New-PollText -Watcher (New-GWatcher 'Exited' 'AllDone' 'L1') -Steps (Get-AllDoneSteps))
        $null = Run
        $global:GITestCtx.Starts.Count | Should -Be 0
    }

    It 'fails the step with the contract message and stops the watcher when an attempt times out' {
        $late = New-GStep 'Pkg:VmTools' 'Running' 1 'Installing' -Extra @{ attemptStartedAt = '2026-11-25T08:30:00+00:00' }
        Q (New-PollText -Watcher (New-GWatcher) -Steps @($late))
        $msg = 'Timed out after 60 min (attempt 1); installer processes were stopped. See the install logs in C:\ProgramData\VDI\Logs.'
        { Run } | Should -Throw '*Timed out after 60 min (attempt 1); installer processes were stopped.*'
        $global:GITestCtx.Stops.Count | Should -Be 1
        $global:GITestCtx.Stops[0].Pid | Should -Be 4242
        $global:GITestCtx.Stops[0].Install | Should -Be 'C:\ProgramData\VDI\Install'
        $s = Get-GIStep -Run $run -Id 'Pkg:VmTools'
        $s.status | Should -Be 'Failed'
        $s.message | Should -Be $msg
    }

    It 'does not time out a step whose current attempt is young even if the step started long ago' {
        $s = New-GStep 'Pkg:VmTools' 'Running' 3 'Installing' -Started '2026-11-25T07:00:00+00:00' -Extra @{ attemptStartedAt = '2026-11-25T09:50:00+00:00' }
        Q (New-PollText -Watcher (New-GWatcher) -Steps @($s))
        Q (New-PollText -Watcher (New-GWatcher 'Exited' 'AllDone') -Steps (Get-AllDoneSteps))
        { Run } | Should -Not -Throw
        $global:GITestCtx.Stops.Count | Should -Be 0
    }

    It 'uses PassTimeoutMin for the Windows Update step' {
        $cfg.GoldenImage.WindowsUpdate.PassTimeoutMin = 30
        $wu = New-GStep 'WindowsUpdate' 'Running' 1 'pass 1' -Extra @{ attemptStartedAt = '2026-11-25T09:15:00+00:00' }
        Q (New-PollText -Watcher (New-GWatcher -Step 'WindowsUpdate') -Steps @($wu))
        { Run } | Should -Throw '*Timed out after 30 min (attempt 1)*'
        (Get-GIStep -Run $run -Id 'WindowsUpdate').status | Should -Be 'Failed'
    }

    It 'throws the message of a failed guest step and leaves it Failed in the run' {
        $f = New-GStep 'Pkg:VmTools' 'Failed' 4 "In-guest action 'VmTools' exited 1: installer exited with code 1603"
        Q (New-PollText -Watcher (New-GWatcher 'Exited' 'StepFailed') -Steps @($f))
        { Run } | Should -Throw "*exited 1: installer exited with code 1603*"
        (Get-GIStep -Run $run -Id 'Pkg:VmTools').status | Should -Be 'Failed'
        (Get-GIStep -Run $run -Id 'Pkg:VmTools').message | Should -BeLike '*1603*'
    }

    It 'tolerates failed guest calls and gives up after 10 in a row' {
        Q 'THROW', 'THROW', (New-PollText -Watcher (New-GWatcher 'Exited' 'AllDone') -Steps (Get-AllDoneSteps))
        { Run } | Should -Not -Throw
    }

    It 'gives up with Lost contact after 10 failed guest calls in a row and marks a step Failed' {
        Q (@('THROW') * 10)
        { Run } | Should -Throw '*Lost contact with the guest watcher*'
        @(Get-GIStepList -Run $run | Where-Object status -eq 'Failed').Count | Should -Be 1
    }

    It 'throws when the watcher is AllDone but a step is not Succeeded' {
        $steps = @((New-GStep 'EnableUpdates' 'Succeeded'), (New-GStep 'WindowsUpdate' 'Succeeded'))
        Q (New-PollText -Watcher (New-GWatcher 'Exited' 'AllDone') -Steps $steps)
        { Run } | Should -Throw "*step 'Pkg:VmTools' is missing*"
    }

    It 'ignores step files of another attempt' {
        $old = @((New-GStep 'EnableUpdates' 'Succeeded'), (New-GStep 'WindowsUpdate' 'Succeeded'), (New-GStep 'Pkg:VmTools' 'Succeeded'))
        $old | ForEach-Object { $_.attemptId = 'OLD' }
        Q (New-PollText -Watcher (New-GWatcher 'Exited' 'AllDone') -Steps $old)
        { Run } | Should -Throw "*is missing*"
        (Get-GIStep -Run $run -Id 'Pkg:VmTools').status | Should -Not -Be 'Succeeded'
    }
}
}
