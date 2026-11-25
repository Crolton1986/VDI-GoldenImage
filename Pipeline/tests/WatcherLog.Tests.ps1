BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'src' 'State.ps1')
    . (Join-Path $PSScriptRoot '..' 'src' 'WatcherLog.ps1')
    function script:New-Line([string]$Level, [string]$Step, [string]$Text, [string]$At = '2026-11-25T10:00:00.0000000+01:00') { "$At`t$Level`t$Step`t$Text" }
    function script:Write-Bytes([string]$Path, [string]$Text, [switch]$Bom, [switch]$Append) {
        $b = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
        if ($Bom) { $b = [byte[]](0xEF, 0xBB, 0xBF) + $b }
        $fs = [System.IO.File]::Open($Path, $(if ($Append) { 'Append' } else { 'Create' }), 'Write', 'ReadWrite')
        try { $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
    }
}

Describe 'Read-GIWatcherLogSlice' {
    BeforeEach { $script:log = Join-Path $TestDrive "w-$([guid]::NewGuid().ToString('N')).log" }

    It 'reads from 0 and filters by step id' {
        $t = (@(
                (New-Line INFO '-' 'watcher up'), (New-Line OUT 'Pkg:Horizon' 'h1'), (New-Line OUT 'Pkg:DEM' 'd1'),
                (New-Line WARN 'Pkg:Horizon' 'h2')) -join "`r`n") + "`r`n"
        Write-Bytes $log $t
        $r = Read-GIWatcherLogSlice -Path $log -StepId 'Pkg:Horizon' -Offset 0
        @($r.Lines).Count | Should -Be 2
        $r.Lines[0].text | Should -Be 'h1'
        $r.Lines[1].level | Should -Be 'WARN'
        $r.Lines[0].at | Should -Match '^2026-11-25T'
        $r.Offset | Should -Be ([System.IO.FileInfo]$log).Length
        @((Read-GIWatcherLogSlice -Path $log -StepId 'Pkg:DEM' -Offset 0).Lines).Count | Should -Be 1
        (@((Read-GIWatcherLogSlice -Path $log -StepId '-' -Offset 0).Lines))[0].text | Should -Be 'watcher up'
    }
    It 'continues from a mid-file offset' {
        Write-Bytes $log ((New-Line OUT 'EnableUpdates' 'one') + "`n")
        $a = Read-GIWatcherLogSlice -Path $log -StepId 'EnableUpdates' -Offset 0
        Write-Bytes $log ((New-Line OUT 'EnableUpdates' 'two') + "`n") -Append
        $b = Read-GIWatcherLogSlice -Path $log -StepId 'EnableUpdates' -Offset $a.Offset
        @($b.Lines).Count | Should -Be 1
        $b.Lines[0].text | Should -Be 'two'
    }
    It 'leaves a trailing partial line and returns it once complete' {
        $full = New-Line OUT 'Pkg:DEM' 'partial text'
        Write-Bytes $log ((New-Line OUT 'Pkg:DEM' 'whole') + "`r`n" + $full.Substring(0, 30))
        $a = Read-GIWatcherLogSlice -Path $log -StepId 'Pkg:DEM' -Offset 0
        @($a.Lines).Count | Should -Be 1
        $a.Offset | Should -Be ([System.Text.Encoding]::UTF8.GetByteCount((New-Line OUT 'Pkg:DEM' 'whole') + "`r`n"))
        $same = Read-GIWatcherLogSlice -Path $log -StepId 'Pkg:DEM' -Offset $a.Offset
        @($same.Lines).Count | Should -Be 0
        $same.Offset | Should -Be $a.Offset
        Write-Bytes $log ($full.Substring(30) + "`r`n") -Append
        $b = Read-GIWatcherLogSlice -Path $log -StepId 'Pkg:DEM' -Offset $a.Offset
        @($b.Lines).Count | Should -Be 1
        $b.Lines[0].text | Should -Be 'partial text'
    }
    It 'handles CRLF without leaving carriage returns' {
        Write-Bytes $log ((New-Line OUT 'WindowsUpdate' 'a') + "`r`n" + (New-Line OUT 'WindowsUpdate' 'b') + "`r`n")
        $r = Read-GIWatcherLogSlice -Path $log -StepId 'WindowsUpdate' -Offset 0
        ($r.Lines.text) -join '|' | Should -Be 'a|b'
    }
    It 'never splits a multibyte character at the MaxBytes boundary' {
        $line1 = New-Line OUT 'Pkg:DEM' ('caf' + [char]0xE9 + ' ' + [char]0x20AC + [char]0x20AC)
        $line2 = New-Line OUT 'Pkg:DEM' 'second'
        Write-Bytes $log ($line1 + "`n" + $line2 + "`n")
        $len1 = [System.Text.Encoding]::UTF8.GetByteCount($line1 + "`n")
        # an overlong line (no newline within MaxBytes) is cut on a character boundary, never inside the euro signs
        $r = Read-GIWatcherLogSlice -Path $log -StepId 'Pkg:DEM' -Offset 0 -MaxBytes ($len1 - 3)
        $r.Lines[0].text | Should -Not -Match ([string][char]0xFFFD)
        # the limit falls inside line 2: only line 1 is returned
        $r = Read-GIWatcherLogSlice -Path $log -StepId 'Pkg:DEM' -Offset 0 -MaxBytes ($len1 + 5)
        @($r.Lines).Count | Should -Be 1
        $r.Lines[0].text | Should -Be ('caf' + [char]0xE9 + ' ' + [char]0x20AC + [char]0x20AC)
        $r.Offset | Should -Be $len1
        $r2 = Read-GIWatcherLogSlice -Path $log -StepId 'Pkg:DEM' -Offset $r.Offset
        $r2.Lines[0].text | Should -Be 'second'
    }
    It 'resets to 0 when the offset is beyond the file' {
        Write-Bytes $log ((New-Line OUT 'EnableUpdates' 'fresh') + "`n")
        $r = Read-GIWatcherLogSlice -Path $log -StepId 'EnableUpdates' -Offset 99999
        @($r.Lines).Count | Should -Be 1
        $r.Lines[0].text | Should -Be 'fresh'
    }
    It 'strips a BOM at the start of the file' {
        Write-Bytes $log ((New-Line OUT 'EnableUpdates' 'bom') + "`n") -Bom
        $r = Read-GIWatcherLogSlice -Path $log -StepId 'EnableUpdates' -Offset 0
        @($r.Lines).Count | Should -Be 1
        $r.Lines[0].at | Should -Not -Match '﻿'
    }
    It 'returns no lines and the same offset for a missing file' {
        $r = Read-GIWatcherLogSlice -Path (Join-Path $TestDrive 'nope.log') -StepId 'Pkg:DEM' -Offset 42
        @($r.Lines).Count | Should -Be 0
        $r.Offset | Should -Be 42
    }
    It 'treats lines with too few fields as INFO from step -' {
        Write-Bytes $log "garbage without tabs`n"
        $r = Read-GIWatcherLogSlice -Path $log -StepId '-' -Offset 0
        $r.Lines[0].level | Should -Be 'INFO'
        $r.Lines[0].text | Should -Be 'garbage without tabs'
    }
    It 'works while another handle appends to the file' {
        Write-Bytes $log ((New-Line OUT 'Pkg:DEM' 'x') + "`n")
        $w = [System.IO.FileStream]::new($log, 'Append', 'Write', 'Read')
        try { @((Read-GIWatcherLogSlice -Path $log -StepId 'Pkg:DEM' -Offset 0).Lines).Count | Should -Be 1 } finally { $w.Dispose() }
    }
}

Describe 'Get-GIWatcherStepLines' {
    It 'returns the last N lines and an offset to continue from' {
        $log = Join-Path $TestDrive 'last.log'
        $t = (1..30 | ForEach-Object { New-Line OUT 'Pkg:DEM' "l$_" }) -join "`n"
        Write-Bytes $log ($t + "`n" + (New-Line OUT 'Pkg:Other' 'x') + "`n")
        $r = Get-GIWatcherStepLines -Path $log -StepId 'Pkg:DEM' -Last 5
        @($r.Lines).Count | Should -Be 5
        $r.Lines[0].text | Should -Be 'l26'
        $r.Lines[4].text | Should -Be 'l30'
        $r.Offset | Should -Be ([System.IO.FileInfo]$log).Length
    }
    It 'handles a missing file' {
        $r = Get-GIWatcherStepLines -Path (Join-Path $TestDrive 'none.log') -StepId 'Pkg:DEM'
        @($r.Lines).Count | Should -Be 0
        $r.Offset | Should -Be 0
    }
}

Describe 'Watching marker' {
    BeforeAll {
        $d = Join-Path $TestDrive 'wstate'; $null = New-Item -ItemType Directory $d
        $script:cfg = @{ Paths = @{ State = $d; Logs = (Join-Path $TestDrive 'wlogs') } }
    }
    It 'age is MaxValue when absent' { Get-GIRunWatchingAge -Config $cfg -RunId '20261125-010101' | Should -Be ([double]::MaxValue) }
    It 'age is small after Set-GIRunWatching and updates an existing marker' {
        Set-GIRunWatching -Config $cfg -RunId '20261125-010101'
        Get-GIRunWatchingAge -Config $cfg -RunId '20261125-010101' | Should -BeLessThan 5
        (Get-Item (Join-Path $cfg.Paths.State '20261125-010101.watching')).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-10)
        Get-GIRunWatchingAge -Config $cfg -RunId '20261125-010101' | Should -BeGreaterThan 500
        Set-GIRunWatching -Config $cfg -RunId '20261125-010101'
        Get-GIRunWatchingAge -Config $cfg -RunId '20261125-010101' | Should -BeLessThan 5
    }
    It 'does not throw for a bad run id or missing state dir' {
        { Set-GIRunWatching -Config $cfg -RunId '../x' -WarningAction SilentlyContinue } | Should -Not -Throw
        { Set-GIRunWatching -Config @{ Paths = @{ State = '/nonexistent/zz/\0' } } -RunId '20261125-010101' -WarningAction SilentlyContinue } | Should -Not -Throw
    }
}

Describe 'Test-GIWatcherStep' {
    It 'accepts <_>' -ForEach @('EnableUpdates', 'WindowsUpdate', 'Pkg:Horizon', 'Pkg:DEM') { Test-GIWatcherStep -Id $_ | Should -BeTrue }
    It 'rejects <_>' -ForEach @('SafetySnapshot', 'Reboot', 'Pkg:', 'Pkg:A:B', 'Pkg:Hor1zon', 'Pkg', '', "Pkg:DEM`n") { Test-GIWatcherStep -Id $_ | Should -BeFalse }
}

Describe 'Get-GIStepLogResponse' {
    BeforeAll {
        $s = Join-Path $TestDrive 'rstate'; $l = Join-Path $TestDrive 'rlogs'
        $null = New-Item -ItemType Directory $s, $l
        $script:cfg = @{ Paths = @{ State = $s; Logs = $l }; GoldenImage = @{ VmName = 'W11' } }
        $r = New-GIRun -Config $cfg -RunId '20261125-040404'
        $plan = @(
            [pscustomobject]@{ Id = 'EnableUpdates'; Label = 'Enable'; Resumable = $true; Applies = $true; SkipReason = '' }
            [pscustomobject]@{ Id = 'Pkg:Horizon'; Label = 'Horizon'; Resumable = $true; Applies = $true; SkipReason = '' })
        $null = Initialize-GIMaintainSteps -Config $cfg -Run $r -Plan $plan
        Set-GIStep -Config $cfg -Run $r -Id 'Pkg:Horizon' -Status Running -Message 'go'
        Set-GIStep -Config $cfg -Run $r -Id 'EnableUpdates' -Status Succeeded -Message 'done'
        Write-Bytes (Join-Path $l '20261125-040404.watcher.log') ((New-Line OUT 'Pkg:Horizon' 'hello') + "`r`n" + (New-Line OUT 'Pkg:DEM' 'no') + "`r`n")
    }
    It 'returns lines, offset and running=true for a Running step and touches the marker' {
        $x = Get-GIStepLogResponse -Config $cfg -RunId '20261125-040404' -StepId 'Pkg:Horizon' -Offset '0'
        $x.Status | Should -Be 200
        @($x.Body.lines).Count | Should -Be 1
        $x.Body.lines[0].text | Should -Be 'hello'
        $x.Body.offset | Should -BeGreaterThan 0
        $x.Body.running | Should -BeTrue
        Get-GIRunWatchingAge -Config $cfg -RunId '20261125-040404' | Should -BeLessThan 5
    }
    It 'accepts a percent-encoded step id and an empty offset' {
        (Get-GIStepLogResponse -Config $cfg -RunId '20261125-040404' -StepId 'Pkg%3AHorizon' -Offset '').Body.lines.Count | Should -Be 1
    }
    It 'running is false for a Succeeded step and for an unknown step' {
        (Get-GIStepLogResponse -Config $cfg -RunId '20261125-040404' -StepId 'EnableUpdates' -Offset '0').Body.running | Should -BeFalse
        (Get-GIStepLogResponse -Config $cfg -RunId '20261125-040404' -StepId 'Pkg:Nope' -Offset '0').Body.running | Should -BeFalse
    }
    It 'returns 400 for bad run id <r>' -ForEach @(@{ r = '../x' }, @{ r = '' }, @{ r = '20261125-04040' }) {
        (Get-GIStepLogResponse -Config $cfg -RunId $r -StepId 'Pkg:Horizon' -Offset '0').Status | Should -Be 400
    }
    It 'returns 400 for bad step id <s>' -ForEach @(@{ s = '..' }, @{ s = '' }, @{ s = 'a:b:c' }, @{ s = 'Pkg:1' }, @{ s = '../x' }, @{ s = 'Pkg:Hor/izon' }) {
        (Get-GIStepLogResponse -Config $cfg -RunId '20261125-040404' -StepId $s -Offset '0').Status | Should -Be 400
    }
    It 'returns 400 for bad offset <o>' -ForEach @(@{ o = '-1' }, @{ o = 'abc' }, @{ o = '1.5' }, @{ o = '99999999999999999999' }) {
        (Get-GIStepLogResponse -Config $cfg -RunId '20261125-040404' -StepId 'Pkg:Horizon' -Offset $o).Status | Should -Be 400
    }
    It 'returns 404 for an unknown run' {
        (Get-GIStepLogResponse -Config $cfg -RunId '20200101-000000' -StepId 'Pkg:Horizon' -Offset '0').Status | Should -Be 404
    }
}

Describe 'Get-GIRunStepLogs' {
    It 'covers only watcher steps of the run' {
        $s = Join-Path $TestDrive 'gstate'; $l = Join-Path $TestDrive 'glogs'
        $null = New-Item -ItemType Directory $s, $l
        $cfg = @{ Paths = @{ State = $s; Logs = $l }; GoldenImage = @{ VmName = 'W11' } }
        $r = New-GIRun -Config $cfg -RunId '20261125-050505'
        $plan = @(
            [pscustomobject]@{ Id = 'SafetySnapshot'; Label = 'Safety'; Resumable = $true; Applies = $true; SkipReason = '' }
            [pscustomobject]@{ Id = 'Pkg:DEM'; Label = 'DEM'; Resumable = $true; Applies = $true; SkipReason = '' })
        $null = Initialize-GIMaintainSteps -Config $cfg -Run $r -Plan $plan
        $x = Get-GIRunStepLogs -Config $cfg -Run (Get-GIRun -Config $cfg -RunId '20261125-050505')
        $x.Keys | Should -Be @('Pkg:DEM')
        @($x['Pkg:DEM'].Lines).Count | Should -Be 0
    }
}
