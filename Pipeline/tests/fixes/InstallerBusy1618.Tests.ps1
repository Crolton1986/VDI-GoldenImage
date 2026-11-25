BeforeAll {
    $script:GuestDir = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'guest')).Path
    $script:FixesDir = Join-Path $script:GuestDir 'fixes'
    $script:FixFile = Join-Path $script:FixesDir 'InstallerBusy1618.ps1'
    . (Join-Path $script:GuestDir 'GIWatcher.Core.ps1')
    $script:DemErr = 'ERROR: Dynamic Environment Manager installer exited with code 1618. See C:\ProgramData\VDI\Logs\Log_DEMAgent_install_20261125_090850.txt'
    $script:RegErr = 'ERROR: Installation failed: This command cannot be run due to the error: Illegal operation attempted on a registry key that has been marked for deletion.'
    $script:Cat = @(Read-GIFixCatalog -Path $script:FixesDir)
    function Get-Sel {
        param([string] $Errors = '', [string] $Output = '', [string] $Log = '', [int] $Exit = 1, [string] $Action = 'DEM', [object[]] $Applied = @())
        Select-GIFix -Catalog $script:Cat -Action $Action -ExitCode $Exit -ErrorText @{ Errors = $Errors; Output = $Output; Log = $Log } -Applied $Applied
    }
}

Describe 'InstallerBusy1618 selection (real catalog)' {
    It 'is selected for the field error, attempt 1, no reboot' {
        $s = Get-Sel -Errors $script:DemErr
        $s.Fix.Id | Should -Be 'InstallerBusy1618'
        $s.FixAttempt | Should -Be 1
        $s.RebootBeforeRetry | Should -BeFalse
    }
    It 'is selected on the other texts and sources' {
        (Get-Sel -Output 'MSI: Another installation is already in progress. Complete that installation').Fix.Id | Should -Be 'InstallerBusy1618'
        (Get-Sel -Output 'Another installation is in progress').Fix.Id | Should -Be 'InstallerBusy1618'
        (Get-Sel -Log 'x ERROR_INSTALL_ALREADY_RUNNING y').Fix.Id | Should -Be 'InstallerBusy1618'
    }
    It 'is not selected for other codes or exit codes' {
        Get-Sel -Errors 'installer exited with code 16180' | Should -BeNullOrEmpty
        Get-Sel -Errors 'installer exited with code 1603' | Should -BeNullOrEmpty
        Get-Sel -Errors $script:DemErr -Exit 0 | Should -BeNullOrEmpty
    }
    It 'does not cross-match the registry fix' {
        (Get-Sel -Errors $script:RegErr).Fix.Id | Should -Be 'RegistryKeyMarkedForDeletion'
    }
    It 'reboots on the third use and stops at the cap' {
        $one = @(@{ id = 'InstallerBusy1618'; fixAttempt = 1 })
        $s = Get-Sel -Errors $script:DemErr -Applied $one
        $s.FixAttempt | Should -Be 2
        $s.RebootBeforeRetry | Should -BeFalse
        $two = $one + @{ id = 'InstallerBusy1618'; fixAttempt = 2 }
        $s = Get-Sel -Errors $script:DemErr -Applied $two
        $s.FixAttempt | Should -Be 3
        $s.RebootBeforeRetry | Should -BeTrue
        Get-Sel -Errors $script:DemErr -Applied ($two + @{ id = 'InstallerBusy1618'; fixAttempt = 3 }) | Should -BeNullOrEmpty
    }
}

Describe 'InstallerBusy1618 in the watcher main loop' {
    BeforeAll {
        . (Join-Path $script:GuestDir 'Invoke-GIWatcher.ps1') -WorkDir (Join-Path $TestDrive 'dotsource')
        function New-Work {
            $w = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $w | Out-Null
            Copy-Item -LiteralPath $script:FixesDir -Destination (Join-Path $w 'fixes') -Recurse
            @{ schemaVersion = 1; runId = 'R1'; attemptId = 'A1'; launchId = 'L1'; createdAt = (Get-Date).ToString('o')
               scriptPath = 'C:\x\VDI-GoldenImage.ps1'; workDir = $w; installDir = (Join-Path $w 'Install'); logDir = (Join-Path $w 'Logs')
               settings = @{ heartbeatSec = 1; maxStepAttempts = 4; fixTimeoutSec = 30 }
               steps = @(@{ id = 'Pkg:DEM'; kind = 'Action'; action = 'DEM' }) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $w 'plan.json')
            return $w
        }
        $script:Fail = @{ Exit = 1; Result = @{ action = 'DEM'; success = $false; errors = @($script:DemErr) } }
        $script:Good = @{ Exit = 0; Result = @{ action = 'DEM'; success = $true; errors = @(); rebootRequired = $false; versions = @{ DEM = '1.0' } } }
    }
    BeforeEach {
        $script:StepCalls = 0
        $script:Specs = @()
        Mock Start-GIStepProcess {
            $spec = $script:Specs[$script:StepCalls]
            $script:StepCalls++
            Set-Content -LiteralPath $OutFile -Value 'out'
            $spec.Result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultFile
            return @{ ExitCode = $spec.Exit; TimedOut = $false }
        }
        Mock Start-GIFixProcess {
            @{ ok = $true; message = 'fixed'; outcome = 'Applied' } | ConvertTo-Json | Set-Content -LiteralPath $ResultPath
            return @{ ExitCode = 0; TimedOut = $false }
        }
    }

    It 'retries once and succeeds' {
        $w = New-Work
        $script:Specs = @($script:Fail, $script:Good)
        @(Invoke-GIWatcherMain -WorkDir $w -ScriptDir $script:GuestDir)[-1] | Should -Be 0
        $s = Read-GIWatcherJson -Path (Join-Path $w 'steps\Pkg_DEM.json')
        $s.status | Should -Be 'Succeeded'
        $s.attempt | Should -Be 2
        $s.fixApplied[0].id | Should -Be 'InstallerBusy1618'
        $s.fixApplied[0].fixAttempt | Should -Be 1
        Should -Invoke Start-GIStepProcess -Times 2 -Exactly
    }

    It 'reboots after the third failure and succeeds on attempt 4' {
        $w = New-Work
        $script:Specs = @($script:Fail, $script:Fail, $script:Fail, $script:Good)
        @(Invoke-GIWatcherMain -WorkDir $w -ScriptDir $script:GuestDir)[-1] | Should -Be 0
        $s = Read-GIWatcherJson -Path (Join-Path $w 'steps\Pkg_DEM.json')
        $s.status | Should -Be 'RebootRequired'
        $s.attempt | Should -Be 3
        $s.pendingFix.id | Should -Be 'InstallerBusy1618'
        $s.pendingFix.fixAttempt | Should -Be 3
        (Read-GIWatcherJson -Path (Join-Path $w 'watcher.json')).state | Should -Be 'RebootRequested'

        $plan = Read-GIWatcherJson -Path (Join-Path $w 'plan.json'); $plan.launchId = 'L2'
        Write-GIWatcherJson -Path (Join-Path $w 'plan.json') -InputObject $plan
        @(Invoke-GIWatcherMain -WorkDir $w -ScriptDir $script:GuestDir)[-1] | Should -Be 0
        $s = Read-GIWatcherJson -Path (Join-Path $w 'steps\Pkg_DEM.json')
        $s.status | Should -Be 'Succeeded'
        $s.attempt | Should -Be 4
        @($s.fixApplied).Count | Should -Be 3
        Should -Invoke Start-GIStepProcess -Times 4 -Exactly
    }
}

Describe 'Invoke-GIFix' {
    BeforeAll {
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        $script:IdleQueue = [System.Collections.Generic.Queue[bool]]::new()
        function Write-GIFixLog { param([string] $Message) $script:Calls.Add("log:$Message") }
        function Stop-GIAllowedProcess {
            param([string] $Name, [switch] $InstallDirOnly)
            $script:Calls.Add($(if ($InstallDirOnly) { 'stop:installdir' } else { "stop:$Name" }))
            return @(1234)
        }
        function Wait-GIMsiIdle { param([int] $TimeoutSec = 300) $script:Calls.Add("wait:$TimeoutSec"); return $script:IdleQueue.Dequeue() }
        function Get-CimInstance {
            [CmdletBinding()] param([string] $ClassName, [string] $Filter)
            if ($ClassName -eq 'Win32_Process') {
                return @([pscustomobject]@{ ProcessId = 4321; CommandLine = ('msiexec.exe /i ' + ('x' * 400)) })
            }
            return [pscustomobject]@{ LastBootUpTime = 'BOOTTIME' }
        }
        . $script:FixFile
        function Get-Ctx { param([int] $Attempt, [string] $Phase = 'BeforeRetry') [pscustomobject]@{ Phase = $Phase; StepId = 'Pkg:DEM'; FixAttempt = $Attempt } }
    }
    BeforeEach { $script:Calls.Clear(); $script:IdleQueue.Clear() }

    It 'logs msiexec pid and a command line truncated to 300 chars' {
        $script:IdleQueue.Enqueue($true)
        $null = Invoke-GIFix -Context (Get-Ctx 1)
        $line = @($script:Calls | Where-Object { $_ -like 'log:*pid 4321*' })
        $line.Count | Should -Be 1
        $line[0].Length | Should -BeLessThan 400
        $line[0] | Should -Not -Match 'x{301}'
    }
    It 'attempt 1 waits 540 and stops nothing' {
        $script:IdleQueue.Enqueue($true)
        $r = Invoke-GIFix -Context (Get-Ctx 1)
        $r.Ok | Should -BeTrue
        @($script:Calls | Where-Object { $_ -like 'wait:*' }) | Should -Be @('wait:540')
        @($script:Calls | Where-Object { $_ -like 'stop:*' }).Count | Should -Be 0
    }
    It 'attempt 1 returns Ok = false when still busy' {
        $script:IdleQueue.Enqueue($false)
        (Invoke-GIFix -Context (Get-Ctx 1)).Ok | Should -BeFalse
        @($script:Calls | Where-Object { $_ -like 'stop:*' }).Count | Should -Be 0
    }
    It 'attempt 2 busy stops InstallDir and msiexec, then waits again' {
        $script:IdleQueue.Enqueue($false); $script:IdleQueue.Enqueue($true)
        $r = Invoke-GIFix -Context (Get-Ctx 2)
        $r.Ok | Should -BeTrue
        @($script:Calls | Where-Object { $_ -like 'wait:*' -or $_ -like 'stop:*' }) | Should -Be @('wait:120', 'stop:installdir', 'stop:msiexec', 'wait:120')
    }
    It 'attempt 2 idle stops nothing' {
        $script:IdleQueue.Enqueue($true)
        $r = Invoke-GIFix -Context (Get-Ctx 2)
        $r.Ok | Should -BeTrue
        @($script:Calls | Where-Object { $_ -like 'stop:*' }).Count | Should -Be 0
    }
    It 'attempt 3 BeforeRetry stops InstallDir only and returns Ok' {
        $r = Invoke-GIFix -Context (Get-Ctx 3)
        $r.Ok | Should -BeTrue
        @($script:Calls | Where-Object { $_ -like 'stop:*' }) | Should -Be @('stop:installdir')
        @($script:Calls | Where-Object { $_ -like 'wait:*' }).Count | Should -Be 0
        @($script:Calls | Where-Object { $_ -like 'log:*reboot*' }).Count | Should -BeGreaterThan 0
    }
    It 'attempt 3 AfterReboot logs the boot time, waits 300 and stops nothing' {
        $script:IdleQueue.Enqueue($true)
        $r = Invoke-GIFix -Context (Get-Ctx 3 'AfterReboot')
        $r.Ok | Should -BeTrue
        @($script:Calls | Where-Object { $_ -like 'wait:*' }) | Should -Be @('wait:300')
        @($script:Calls | Where-Object { $_ -like 'stop:*' }).Count | Should -Be 0
        @($script:Calls | Where-Object { $_ -like 'log:*BOOTTIME*' }).Count | Should -BeGreaterThan 0
    }
    It 'attempt 3 AfterReboot returns Ok = false when still busy' {
        $script:IdleQueue.Enqueue($false)
        (Invoke-GIFix -Context (Get-Ctx 3 'AfterReboot')).Ok | Should -BeFalse
    }
    It 'never throws' {
        function Stop-GIAllowedProcess { param([string] $Name, [switch] $InstallDirOnly) throw 'boom' }
        $r = Invoke-GIFix -Context (Get-Ctx 3)
        $r.Ok | Should -BeFalse
        function Wait-GIMsiIdle { param([int] $TimeoutSec = 300) throw 'boom' }
        (Invoke-GIFix -Context (Get-Ctx 1)).Ok | Should -BeFalse
    }
}
