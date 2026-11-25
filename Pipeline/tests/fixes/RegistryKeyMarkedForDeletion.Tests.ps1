BeforeAll {
    $script:GuestDir = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'guest')).Path
    $script:FixesDir = Join-Path $script:GuestDir 'fixes'
    $script:FixFile = Join-Path $script:FixesDir 'RegistryKeyMarkedForDeletion.ps1'
    . (Join-Path $script:GuestDir 'GIWatcher.Core.ps1')
    $script:RegErr = 'ERROR: Installation failed: This command cannot be run due to the error: Illegal operation attempted on a registry key that has been marked for deletion.'
    $script:Cat = @(Read-GIFixCatalog -Path $script:FixesDir)
    function Get-Sel {
        param([string] $Errors = '', [string] $Output = '', [string] $Log = '', [int] $Exit = 1, [string] $Action = 'Horizon', [object[]] $Applied = @())
        Select-GIFix -Catalog $script:Cat -Action $Action -ExitCode $Exit -ErrorText @{ Errors = $Errors; Output = $Output; Log = $Log } -Applied $Applied
    }
}

Describe 'RegistryKeyMarkedForDeletion selection (real catalog)' {
    It 'is selected for the field error, attempt 1, no reboot' {
        $s = Get-Sel -Errors $script:RegErr
        $s.Fix.Id | Should -Be 'RegistryKeyMarkedForDeletion'
        $s.FixAttempt | Should -Be 1
        $s.RebootBeforeRetry | Should -BeFalse
    }
    It 'is selected when the text is only in Output or only in Log' {
        (Get-Sel -Output "x`n$($script:RegErr)").Fix.Id | Should -Be 'RegistryKeyMarkedForDeletion'
        (Get-Sel -Log "x $($script:RegErr)").Fix.Id | Should -Be 'RegistryKeyMarkedForDeletion'
        (Get-Sel -Errors 'registry  key   that has been marked  for deletion').Fix.Id | Should -Be 'RegistryKeyMarkedForDeletion'
    }
    It 'is not selected for other text or other exit codes' {
        Get-Sel -Errors 'installer exited with code 1603' | Should -BeNullOrEmpty
        Get-Sel -Errors $script:RegErr -Exit 0 | Should -BeNullOrEmpty
        Get-Sel -Errors $script:RegErr -Exit 3 | Should -BeNullOrEmpty
    }
    It 'reboots on the second use and stops at the cap' {
        $one = @(@{ id = 'RegistryKeyMarkedForDeletion'; fixAttempt = 1 })
        $s = Get-Sel -Errors $script:RegErr -Applied $one
        $s.FixAttempt | Should -Be 2
        $s.RebootBeforeRetry | Should -BeTrue
        Get-Sel -Errors $script:RegErr -Applied ($one + @{ id = 'RegistryKeyMarkedForDeletion'; fixAttempt = 2 }) | Should -BeNullOrEmpty
    }
}

Describe 'RegistryKeyMarkedForDeletion in the watcher main loop' {
    BeforeAll {
        . (Join-Path $script:GuestDir 'Invoke-GIWatcher.ps1') -WorkDir (Join-Path $TestDrive 'dotsource')
        function New-Work {
            $w = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $w | Out-Null
            Copy-Item -LiteralPath $script:FixesDir -Destination (Join-Path $w 'fixes') -Recurse
            @{ schemaVersion = 1; runId = 'R1'; attemptId = 'A1'; launchId = 'L1'; createdAt = (Get-Date).ToString('o')
               scriptPath = 'C:\x\VDI-GoldenImage.ps1'; workDir = $w; installDir = (Join-Path $w 'Install'); logDir = (Join-Path $w 'Logs')
               settings = @{ heartbeatSec = 1; maxStepAttempts = 4; fixTimeoutSec = 30 }
               steps = @(@{ id = 'Pkg:Horizon'; kind = 'Action'; action = 'Horizon' }) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $w 'plan.json')
            return $w
        }
        $script:Fail = @{ Exit = 1; Result = @{ action = 'Horizon'; success = $false; errors = @($script:RegErr) } }
        $script:Good = @{ Exit = 0; Result = @{ action = 'Horizon'; success = $true; errors = @(); rebootRequired = $false; versions = @{ Horizon = '1.0' } } }
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
        $s = Read-GIWatcherJson -Path (Join-Path $w 'steps\Pkg_Horizon.json')
        $s.status | Should -Be 'Succeeded'
        $s.attempt | Should -Be 2
        $s.fixApplied[0].id | Should -Be 'RegistryKeyMarkedForDeletion'
        $s.fixApplied[0].fixAttempt | Should -Be 1
        Should -Invoke Start-GIStepProcess -Times 2 -Exactly
    }

    It 'reboots after the second failure, then fails with the original error after the third' {
        $w = New-Work
        $script:Specs = @($script:Fail, $script:Fail, $script:Fail)
        @(Invoke-GIWatcherMain -WorkDir $w -ScriptDir $script:GuestDir)[-1] | Should -Be 0
        $s = Read-GIWatcherJson -Path (Join-Path $w 'steps\Pkg_Horizon.json')
        $s.status | Should -Be 'RebootRequired'
        $s.attempt | Should -Be 2
        $s.pendingFix.id | Should -Be 'RegistryKeyMarkedForDeletion'
        $s.pendingFix.fixAttempt | Should -Be 2
        (Read-GIWatcherJson -Path (Join-Path $w 'watcher.json')).state | Should -Be 'RebootRequested'

        $plan = Read-GIWatcherJson -Path (Join-Path $w 'plan.json'); $plan.launchId = 'L2'
        Write-GIWatcherJson -Path (Join-Path $w 'plan.json') -InputObject $plan
        @(Invoke-GIWatcherMain -WorkDir $w -ScriptDir $script:GuestDir)[-1] | Should -Be 1
        $s = Read-GIWatcherJson -Path (Join-Path $w 'steps\Pkg_Horizon.json')
        $s.status | Should -Be 'Failed'
        $s.message | Should -BeLike "*$($script:RegErr)*"
        @($s.fixApplied).Count | Should -Be 2
        Should -Invoke Start-GIStepProcess -Times 3 -Exactly
    }
}

Describe 'Invoke-GIFix' {
    BeforeAll {
        # Stubs recording calls; the fix is dot-sourced into this scope so it resolves them
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        $script:IdleQueue = [System.Collections.Generic.Queue[bool]]::new()
        function Write-GIFixLog { param([string] $Message) $script:Calls.Add("log:$Message") }
        function Stop-GIAllowedProcess {
            param([string] $Name, [switch] $InstallDirOnly)
            $script:Calls.Add($(if ($InstallDirOnly) { 'stop:installdir' } else { "stop:$Name" }))
            return @(1234)
        }
        function Wait-GIMsiIdle { param([int] $TimeoutSec = 300) $script:Calls.Add("wait:$TimeoutSec"); return $script:IdleQueue.Dequeue() }
        . $script:FixFile
    }
    BeforeEach { $script:Calls.Clear(); $script:IdleQueue.Clear() }

    It 'cleans InstallDir and returns Ok when MSI is idle' {
        $script:IdleQueue.Enqueue($true)
        $r = Invoke-GIFix -Context ([pscustomobject]@{ Phase = 'BeforeRetry'; StepId = 'Pkg:Horizon' })
        $r.Ok | Should -BeTrue
        $script:Calls | Should -Contain 'stop:installdir'
        $script:Calls | Should -Not -Contain 'stop:msiexec'
    }
    It 'stops msiexec when MSI stays busy first, then is idle' {
        $script:IdleQueue.Enqueue($false); $script:IdleQueue.Enqueue($true)
        $r = Invoke-GIFix -Context ([pscustomobject]@{ Phase = 'BeforeRetry'; StepId = 'Pkg:Horizon' })
        $r.Ok | Should -BeTrue
        $script:Calls | Should -Contain 'stop:msiexec'
        $r.Message | Should -Match 'idle'
    }
    It 'returns Ok = false when MSI stays busy' {
        $script:IdleQueue.Enqueue($false); $script:IdleQueue.Enqueue($false)
        $r = Invoke-GIFix -Context ([pscustomobject]@{ Phase = 'BeforeRetry'; StepId = 'Pkg:Horizon' })
        $r.Ok | Should -BeFalse
        $r.Message | Should -Match 'busy'
    }
    It 'only logs after a reboot' {
        $r = Invoke-GIFix -Context ([pscustomobject]@{ Phase = 'AfterReboot'; StepId = 'Pkg:Horizon' })
        $r.Ok | Should -BeTrue
        @($script:Calls | Where-Object { $_ -like 'stop:*' -or $_ -like 'wait:*' }).Count | Should -Be 0
        @($script:Calls | Where-Object { $_ -like 'log:*' }).Count | Should -BeGreaterThan 0
    }
    It 'never throws' {
        function Stop-GIAllowedProcess { param([string] $Name, [switch] $InstallDirOnly) throw 'boom' }
        $r = Invoke-GIFix -Context ([pscustomobject]@{ Phase = 'BeforeRetry'; StepId = 'X' })
        $r.Ok | Should -BeFalse
    }
}
