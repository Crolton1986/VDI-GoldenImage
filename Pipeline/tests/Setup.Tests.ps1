BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'VDI-GIPipeline.psd1') -Force

    # Mock bodies run bound to the module, so test data is shared through one global hashtable
    $global:GISetupCtx = @{}

    # Stubs for commands that may not exist on this box (or are defined by a concurrent src file)
    InModuleScope VDI-GIPipeline {
        $stubs = @{
            'Invoke-GISetupModules'       = { [CmdletBinding()] param($Config, $State) }
            'Get-GIPipelineTaskDefinition' = { [CmdletBinding()] param($Root, $Config, $ConfigPath) }
            'Register-GIPipelineTask'     = { [CmdletBinding()] param($Definitions, $Credential) }
            'Test-GIWindowsCredential'    = { [CmdletBinding()] param($Credential) }
            'Get-NetFirewallRule'         = { [CmdletBinding()] param($DisplayName) }
            'New-NetFirewallRule'         = { [CmdletBinding()] param($DisplayName, $Direction, $Protocol, $LocalPort, $Action, $Profile) }
            'New-SelfSignedCertificate'   = { [CmdletBinding()] param($DnsName, $CertStoreLocation, $FriendlyName, $KeyExportPolicy, $NotAfter) }
            'Get-SecretVault'             = { [CmdletBinding()] param($Name) }
            'Register-SecretVault'        = { [CmdletBinding()] param($Name, $ModuleName, [switch]$DefaultVault) }
            'Set-SecretVaultDefault'      = { [CmdletBinding()] param($Name) }
            'Set-SecretStoreConfiguration' = { [CmdletBinding(SupportsShouldProcess)] param($Scope, $Authentication, $Interaction, $Password) }
            'Get-SecretStoreConfiguration' = { [CmdletBinding()] param() }
            'Test-SecretVault'            = { [CmdletBinding()] param($Name) }
        }
        foreach ($n in $stubs.Keys) {
            if (-not (Get-Command $n -ErrorAction SilentlyContinue)) {
                Set-Item -Path "function:script:$n" -Value $stubs[$n]
            }
        }
    }

    function script:New-TestConfig {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'config') -Force | Out-Null
        @{ Root = $root; Paths = @{ State = (Join-Path $root 'state'); Logs = (Join-Path $root 'logs') } }
    }
    # Reads setup.json without the dead-pid translation Get-GISetupState applies
    function script:Read-RawSetup { param($Config) Get-Content -LiteralPath (Join-Path (Join-Path $Config.Root 'config') 'setup.json') -Raw | ConvertFrom-Json }
    # Moves a fresh setup to the given mode with the listed steps done
    function script:Set-StepsDone {
        param($Config, [string[]] $Steps)
        foreach ($s in $Steps) { Set-GISetupStep -Config $Config -Step $s -Status done -Message 'ok' }
    }
    function script:New-MyCredential {
        param([string] $User = ([Environment]::UserName), [string] $Password = 'Pw-Unique-12345')
        [pscredential]::new($User, (ConvertTo-SecureString -String $Password -AsPlainText -Force))
    }
}

AfterAll { Remove-Variable -Name GISetupCtx -Scope Global -ErrorAction SilentlyContinue }

Describe 'Setup' {
    BeforeEach {
        $script:cfg = New-TestConfig
        $global:GISetupCtx.Audit = [System.Collections.Generic.List[string]]::new()
        $global:GISetupCtx.Registered = 0
        $global:GISetupCtx.Set = $null
        $global:GISetupCtx.Sp = $null
        $global:GISetupCtx.Reg = $null
        $global:GISetupCtx.StoreCfg = $null
        Mock -ModuleName VDI-GIPipeline Write-GIAudit { $global:GISetupCtx.Audit.Add((@{ User = $User; Action = $Action; Target = $Target; Detail = $Detail } | ConvertTo-Json -Depth 8 -Compress)) }
        Mock -ModuleName VDI-GIPipeline Write-Information { }
    }

    Context 'State' {
        It 'returns a fresh state when setup.json is absent' {
            $s = Get-GISetupState -Config $cfg
            @($s.steps.PSObject.Properties.Name) | Should -Be @('Mode', 'Prerequisites', 'Modules', 'PowerCLI', 'Vault', 'DashboardAccess', 'Tasks', 'Finish')
            foreach ($n in $s.steps.PSObject.Properties.Name) { $s.steps.$n.status | Should -Be 'pending' }
            $s.mode | Should -BeNullOrEmpty
            $s.modeLocked | Should -BeFalse
            $s.completedAt | Should -BeNullOrEmpty
        }
        It 'sets modeLocked from -ModeLocked' {
            (Get-GISetupState -Config $cfg -ModeLocked).modeLocked | Should -BeTrue
        }
        It 'does not write a file just by reading' {
            Get-GISetupState -Config $cfg | Out-Null
            Test-Path (Join-Path $cfg.Root 'config' 'setup.json') | Should -BeFalse
        }
        It 'round-trips through Save and Get' {
            $s = Get-GISetupState -Config $cfg -ModeLocked
            $s.mode = 'Lab'
            Save-GISetupState -Config $cfg -State $s
            $r = Get-GISetupState -Config $cfg
            $r.mode | Should -Be 'Lab'
            $r.modeLocked | Should -BeTrue
            $r.steps.Vault.status | Should -Be 'pending'
        }
        It 'reports complete only once completedAt is set' {
            Test-GISetupComplete -Config $cfg | Should -BeFalse
            $s = Get-GISetupState -Config $cfg
            Save-GISetupState -Config $cfg -State $s
            Test-GISetupComplete -Config $cfg | Should -BeFalse
            $s.completedAt = (Get-Date).ToString('o')
            Save-GISetupState -Config $cfg -State $s
            Test-GISetupComplete -Config $cfg | Should -BeTrue
        }
        It 'turns a running step with a dead pid into failed (Interrupted)' {
            Set-GISetupStep -Config $cfg -Step Mode -Status running -Message 'x' -ProcessId 999999
            $s = Get-GISetupState -Config $cfg
            $s.steps.Mode.status | Should -Be 'failed'
            $s.steps.Mode.message | Should -Match 'Interrupted'
            $s.steps.Mode.endedAt | Should -Not -BeNullOrEmpty
        }
        It 'leaves a running step with a live pid running' {
            Set-GISetupStep -Config $cfg -Step Modules -Status running -Message 'x' -ProcessId $PID
            (Get-GISetupState -Config $cfg).steps.Modules.status | Should -Be 'running'
        }
        It 'leaves a running step with no pid running' {
            Set-GISetupStep -Config $cfg -Step Modules -Status running -Message 'x'
            $s = Get-GISetupState -Config $cfg
            $s.steps.Modules.status | Should -Be 'running'
            $s.steps.Modules.pid | Should -BeNullOrEmpty
        }
    }

    Context 'Next step and start rules' {
        It 'Get-GISetupNextStep skips done and skipped steps' {
            Set-GISetupStep -Config $cfg -Step Mode -Status done
            Set-GISetupStep -Config $cfg -Step Prerequisites -Status skipped
            Set-GISetupStep -Config $cfg -Step Modules -Status failed -Message 'x'
            Get-GISetupNextStep -State (Get-GISetupState -Config $cfg) | Should -Be 'Modules'
        }
        It 'Get-GISetupNextStep returns null when everything is done' {
            Set-StepsDone -Config $cfg -Steps 'Mode', 'Prerequisites', 'Modules', 'PowerCLI', 'Vault', 'DashboardAccess', 'Tasks', 'Finish'
            Get-GISetupNextStep -State (Get-GISetupState -Config $cfg) | Should -BeNullOrEmpty
        }
        It 'Assert-GISetupCanStart allows the next step' {
            { Assert-GISetupCanStart -State (Get-GISetupState -Config $cfg) -Step 'Mode' } | Should -Not -Throw
        }
        It 'Assert-GISetupCanStart refuses while another step is running' {
            Set-StepsDone -Config $cfg -Steps 'Mode'
            Set-GISetupStep -Config $cfg -Step Prerequisites -Status running -ProcessId $PID
            { Assert-GISetupCanStart -State (Get-GISetupState -Config $cfg) -Step 'Modules' } | Should -Throw '*still running*'
        }
        It 'Assert-GISetupCanStart refuses a step that is not next' {
            Set-StepsDone -Config $cfg -Steps 'Mode'
            { Assert-GISetupCanStart -State (Get-GISetupState -Config $cfg) -Step 'Vault' } | Should -Throw "*next step is 'Prerequisites'*"
        }
        It 'Assert-GISetupCanStart refuses once setup is completed' {
            $s = Get-GISetupState -Config $cfg
            $s.completedAt = (Get-Date).ToString('o')
            { Assert-GISetupCanStart -State $s -Step 'Mode' } | Should -Throw '*already complete*'
        }
        It 'Assert-GISetupCanStart allows retrying a failed next step' {
            Set-StepsDone -Config $cfg -Steps 'Mode'
            Set-GISetupStep -Config $cfg -Step Prerequisites -Status failed -Message 'nope'
            { Assert-GISetupCanStart -State (Get-GISetupState -Config $cfg) -Step 'Prerequisites' } | Should -Not -Throw
        }
    }

    Context 'Set-GISetupMode' {
        It 'Lab marks DashboardAccess and Tasks skipped' {
            Set-GISetupMode -Config $cfg -Mode Lab -By tester
            $s = Get-GISetupState -Config $cfg
            $s.mode | Should -Be 'Lab'
            $s.steps.Mode.status | Should -Be 'done'
            $s.steps.DashboardAccess.status | Should -Be 'skipped'
            $s.steps.Tasks.status | Should -Be 'skipped'
            $s.steps.Vault.status | Should -Be 'pending'
        }
        It 'Production leaves them pending' {
            Set-GISetupMode -Config $cfg -Mode Production -By tester
            $s = Get-GISetupState -Config $cfg
            $s.mode | Should -Be 'Production'
            $s.steps.DashboardAccess.status | Should -Be 'pending'
            $s.steps.Tasks.status | Should -Be 'pending'
        }
        It 'refuses Production when the mode is locked' {
            Save-GISetupState -Config $cfg -State (Get-GISetupState -Config $cfg -ModeLocked)
            { Set-GISetupMode -Config $cfg -Mode Production -By tester } | Should -Throw '*Lab mode*'
            (Get-GISetupState -Config $cfg).steps.Mode.status | Should -Be 'pending'
            { Set-GISetupMode -Config $cfg -Mode Lab -By tester } | Should -Not -Throw
        }
        It 'Initialize-GISetupState writes modeLocked true when no mode is chosen yet' {
            $r = Initialize-GISetupState -Config $cfg -ModeLocked
            $r.modeLocked | Should -BeTrue
            (Read-RawSetup $cfg).modeLocked | Should -BeTrue
            (Get-GISetupState -Config $cfg).modeLocked | Should -BeTrue
        }
        It 'Initialize-GISetupState without -ModeLocked writes an unlocked state' {
            Initialize-GISetupState -Config $cfg | Out-Null
            (Read-RawSetup $cfg).modeLocked | Should -BeFalse
        }
        It 'Set-GISetupMode -ModeLocked refuses Production even when the file says unlocked' {
            Initialize-GISetupState -Config $cfg | Out-Null
            (Read-RawSetup $cfg).modeLocked | Should -BeFalse
            { Set-GISetupMode -Config $cfg -Mode Production -ModeLocked -By tester } | Should -Throw '*Lab mode*'
            (Get-GISetupState -Config $cfg).steps.Mode.status | Should -Be 'pending'
        }
        It 'Set-GISetupMode -ModeLocked refuses Production on a first run with no setup.json' {
            { Set-GISetupMode -Config $cfg -Mode Production -ModeLocked -By tester } | Should -Throw '*Lab mode*'
        }
        It 'after Initialize-GISetupState -ModeLocked, Production is refused without the switch' {
            Initialize-GISetupState -Config $cfg -ModeLocked | Out-Null
            { Set-GISetupMode -Config $cfg -Mode Production -By tester } | Should -Throw '*Lab mode*'
            { Set-GISetupMode -Config $cfg -Mode Lab -By tester } | Should -Not -Throw
            (Get-GISetupState -Config $cfg).mode | Should -Be 'Lab'
        }
        It 'stores invalidCertAction' {
            Set-GISetupMode -Config $cfg -Mode Production -InvalidCertAction Fail -By tester
            (Get-GISetupState -Config $cfg).options.invalidCertAction | Should -Be 'Fail'
        }
        It 'refuses when Mode is already done' {
            Set-GISetupMode -Config $cfg -Mode Lab -By tester
            { Set-GISetupMode -Config $cfg -Mode Lab -By tester } | Should -Throw '*can''t run now*'
        }
        It 'audits the choice' {
            Set-GISetupMode -Config $cfg -Mode Lab -By tester
            Should -Invoke Write-GIAudit -ModuleName VDI-GIPipeline -Times 1 -ParameterFilter { $Action -eq 'setup.step' -and $Target -eq 'Mode' -and $User -eq 'tester' }
        }
    }

    Context 'Progress and data' {
        It 'appends timestamped lines' {
            Write-GISetupProgress -Config $cfg -Step Modules -Line 'hello'
            $d = @((Get-GISetupState -Config $cfg).steps.Modules.detail)
            $d.Count | Should -Be 1
            $d[0] | Should -Match '^\d\d:\d\d:\d\d hello$'
        }
        It 'keeps only the last 50 lines' {
            1..60 | ForEach-Object { Write-GISetupProgress -Config $cfg -Step Modules -Line "line $_" }
            $d = @((Get-GISetupState -Config $cfg).steps.Modules.detail)
            $d.Count | Should -Be 50
            $d[0] | Should -Match 'line 11$'
            $d[-1] | Should -Match 'line 60$'
        }
        It 'Set-GISetupStepData merges without changing status' {
            Set-GISetupStep -Config $cfg -Step Modules -Status running -Message 'busy' -ProcessId $PID
            Set-GISetupStepData -Config $cfg -Step Modules -Data @{ items = @(@{ name = 'Pode'; status = 'ok' }) }
            Set-GISetupStepData -Config $cfg -Step Modules -Data @{ other = 5 }
            $st = (Get-GISetupState -Config $cfg).steps.Modules
            $st.status | Should -Be 'running'
            $st.message | Should -Be 'busy'
            $st.data.items[0].name | Should -Be 'Pode'
            $st.data.other | Should -Be 5
        }
    }

    Context 'Invoke-GISetupStepCore' {
        It 'records success with message and data and audits' {
            Mock -ModuleName VDI-GIPipeline Invoke-GISetupModules { @{ Message = 'All good'; Data = @{ count = 3 } } }
            Invoke-GISetupStepCore -Config $cfg -Step Modules | Should -BeTrue
            $st = (Get-GISetupState -Config $cfg).steps.Modules
            $st.status | Should -Be 'done'
            $st.message | Should -Be 'All good'
            $st.data.count | Should -Be 3
            Should -Invoke Write-GIAudit -ModuleName VDI-GIPipeline -Times 1 -ParameterFilter { $Action -eq 'setup.step' -and $Target -eq 'Modules' }
        }
        It 'uses a default message when the step returns nothing' {
            Mock -ModuleName VDI-GIPipeline Invoke-GISetupModules { }
            Invoke-GISetupStepCore -Config $cfg -Step Modules | Should -BeTrue
            (Get-GISetupState -Config $cfg).steps.Modules.message | Should -Be 'Done.'
        }
        It 'marks a Skipped result as skipped' {
            Mock -ModuleName VDI-GIPipeline Invoke-GISetupModules { @{ Message = 'Not needed'; Skipped = $true } }
            Invoke-GISetupStepCore -Config $cfg -Step Modules | Should -BeTrue
            (Get-GISetupState -Config $cfg).steps.Modules.status | Should -Be 'skipped'
        }
        It 'marks an exception as failed with an Error detail line and returns false' {
            Mock -ModuleName VDI-GIPipeline Invoke-GISetupModules { throw 'boom' }
            Invoke-GISetupStepCore -Config $cfg -Step Modules | Should -BeFalse
            $st = (Get-GISetupState -Config $cfg).steps.Modules
            $st.status | Should -Be 'failed'
            $st.message | Should -Be 'boom'
            @($st.detail)[-1] | Should -Match 'Error: boom$'
            Should -Invoke Write-GIAudit -ModuleName VDI-GIPipeline -Times 1 -ParameterFilter { $Action -eq 'setup.step' -and $Detail.status -eq 'failed' }
        }
    }

    Context 'Start-GISetupStep' {
        BeforeEach {
            Mock -ModuleName VDI-GIPipeline Start-Process {
                $global:GISetupCtx.Sp = @{ FilePath = $FilePath; ArgumentList = $ArgumentList }
                [pscustomobject]@{ Id = 4321; ExitCode = 0 } | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $false } -PassThru
            }
        }
        It 'refuses steps that do not run in the background' {
            { Start-GISetupStep -Config $cfg -Step Tasks } | Should -Throw '*doesn''t run in the background*'
            Should -Invoke Start-Process -ModuleName VDI-GIPipeline -Times 0
        }
        It 'refuses when the step is not next' {
            { Start-GISetupStep -Config $cfg -Step Modules } | Should -Throw "*next step is 'Mode'*"
            Should -Invoke Start-Process -ModuleName VDI-GIPipeline -Times 0
        }
        It 'marks the step running and records the started pid' {
            Set-StepsDone -Config $cfg -Steps 'Mode', 'Prerequisites'
            $r = Start-GISetupStep -Config $cfg -Step Modules -ConfigPath 'C:\x\pipeline.config.psd1'
            $r | Should -Be 4321
            $st = (Read-RawSetup $cfg).steps.Modules
            $st.status | Should -Be 'running'
            $st.pid | Should -Be 4321
            $args2 = @($global:GISetupCtx.Sp.ArgumentList)
            $args2 | Should -Contain '-Step'
            $args2 | Should -Contain 'Modules'
            $args2 | Should -Contain '-ConfigPath'
            $args2 | Should -Contain 'C:\x\pipeline.config.psd1'
            ($args2 -join ' ') | Should -Match 'Invoke-GISetupStep\.ps1'
        }
        It 'omits -ConfigPath when not given' {
            Set-StepsDone -Config $cfg -Steps 'Mode', 'Prerequisites'
            Start-GISetupStep -Config $cfg -Step Modules | Out-Null
            @($global:GISetupCtx.Sp.ArgumentList) | Should -Not -Contain '-ConfigPath'
        }
        It 'refuses to start a second step while one is running' {
            Set-StepsDone -Config $cfg -Steps 'Mode', 'Prerequisites'
            Mock -ModuleName VDI-GIPipeline Test-GIProcessAlive { $true }
            Start-GISetupStep -Config $cfg -Step Modules | Out-Null
            { Start-GISetupStep -Config $cfg -Step Modules } | Should -Throw '*still running*'
        }
        It 'passes a quoted -File path when the runner path contains spaces' {
            $spaced = Join-Path $TestDrive 'dir with spaces'
            New-Item -ItemType Directory -Path (Join-Path $spaced 'config') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $spaced 'Invoke-GISetupStep.ps1') -Value ''
            $c2 = @{ Root = $spaced; Paths = $cfg.Paths }
            Set-StepsDone -Config $c2 -Steps 'Mode', 'Prerequisites'
            Start-GISetupStep -Config $c2 -Step Modules -ConfigPath (Join-Path $spaced 'pipeline.config.psd1') | Out-Null
            $a = @($global:GISetupCtx.Sp.ArgumentList)
            $a[$a.IndexOf('-File') + 1] | Should -Be ('"' + (Join-Path $spaced 'Invoke-GISetupStep.ps1') + '"')
            $a[$a.IndexOf('-ConfigPath') + 1] | Should -Match '^".* with spaces.*"$'
        }
        It 'marks the step failed with the error output when the process exits right away' {
            Set-StepsDone -Config $cfg -Steps 'Mode', 'Prerequisites'
            Mock -ModuleName VDI-GIPipeline Start-Process {
                Set-Content -LiteralPath $RedirectStandardError -Value 'boom: cannot load module'
                [pscustomobject]@{ Id = 4321; ExitCode = 1 } | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $true } -PassThru
            }
            Start-GISetupStep -Config $cfg -Step Modules | Out-Null
            $st = (Get-GISetupState -Config $cfg).steps.Modules
            $st.status | Should -Be 'failed'
            $st.message | Should -Match 'stopped right away'
            $st.message | Should -Match 'boom: cannot load module'
        }
        It 'marks the step failed and rethrows when the process cannot start' {
            Set-StepsDone -Config $cfg -Steps 'Mode', 'Prerequisites'
            Mock -ModuleName VDI-GIPipeline Start-Process { throw 'no pwsh' }
            { Start-GISetupStep -Config $cfg -Step Modules } | Should -Throw '*no pwsh*'
            $st = (Get-GISetupState -Config $cfg).steps.Modules
            $st.status | Should -Be 'failed'
            $st.message | Should -Match 'Could not start the setup process: no pwsh'
        }
    }

    Context 'Get-GISetupLog' {
        BeforeEach { $script:cdir = Join-Path $cfg.Root 'config' }
        It 'says there is no log yet when no file exists' {
            Get-GISetupLog -Config $cfg -Step Modules | Should -Be '(no log yet)'
        }
        It 'returns the sections for existing files and skips missing ones' {
            Set-Content -LiteralPath (Join-Path $cdir 'setup-Modules.transcript.log') -Value @('t1', 't2')
            Set-Content -LiteralPath (Join-Path $cdir 'setup-Modules.log.err') -Value 'bad thing'
            $log = Get-GISetupLog -Config $cfg -Step Modules
            $log | Should -Match '== transcript ==\r?\nt1\r?\nt2'
            $log | Should -Match '== errors ==\r?\nbad thing'
            $log | Should -Not -Match '== output =='
        }
        It 'keeps only the last Tail lines' {
            Set-Content -LiteralPath (Join-Path $cdir 'setup-Vault.log') -Value (1..20 | ForEach-Object { "row$_" })
            $log = Get-GISetupLog -Config $cfg -Step Vault -Tail 3
            $log | Should -Match 'row20'
            $log | Should -Match 'row18'
            $log | Should -Not -Match 'row17'
        }
        It 'throws for unknown steps and path traversal' {
            { Get-GISetupLog -Config $cfg -Step 'Nope' } | Should -Throw '*Unknown setup step*'
            { Get-GISetupLog -Config $cfg -Step '../x' } | Should -Throw '*Unknown setup step*'
        }
    }

    Context 'Get-GISetupLastProgressAge' {
        It 'uses the newest detail line time' {
            $state = Get-GISetupState -Config $cfg
            $t = (Get-Date).AddMinutes(-5)
            if ($t.Date -ne (Get-Date).Date) { Set-ItResult -Skipped -Because 'too close to midnight'; return }
            $state.steps.Modules.detail = @("00:00:01 old", "$($t.ToString('HH:mm:ss')) newest")
            $age = Get-GISetupLastProgressAge -State $state -Step Modules
            $age.TotalMinutes | Should -BeGreaterThan 4.5
            $age.TotalMinutes | Should -BeLessThan 6
        }
        It 'falls back to startedAt' {
            $state = Get-GISetupState -Config $cfg
            $state.steps.Modules.startedAt = (Get-Date).AddMinutes(-3).ToString('o')
            $age = Get-GISetupLastProgressAge -State $state -Step Modules
            $age.TotalMinutes | Should -BeGreaterThan 2.9
            $age.TotalMinutes | Should -BeLessThan 4
        }
        It 'returns null with no progress and no start time' {
            Get-GISetupLastProgressAge -State (Get-GISetupState -Config $cfg) -Step Modules | Should -BeNullOrEmpty
        }
    }

    Context 'Write-GIJsonAtomic retry' {
        It 'retries a failing Move-Item and leaves no temp file' {
            $global:GISetupCtx.Moves = 0
            Mock -ModuleName VDI-GIPipeline Start-Sleep { }
            Mock -ModuleName VDI-GIPipeline Move-Item {
                $global:GISetupCtx.Moves++
                if ($global:GISetupCtx.Moves -le 2) { throw 'file in use' }
                Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -Force
            }
            $target = Join-Path $TestDrive 'atomic.json'
            $global:GISetupCtx.Target = $target
            InModuleScope VDI-GIPipeline { Write-GIJsonAtomic -Path $global:GISetupCtx.Target -InputObject @{ a = 1 } }
            $global:GISetupCtx.Moves | Should -Be 3
            (Get-Content -LiteralPath $target -Raw | ConvertFrom-Json).a | Should -Be 1
            @(Get-ChildItem -Path $TestDrive -Filter 'atomic.json*.tmp').Count | Should -Be 0
        }
    }

    Context 'ConvertTo-GIProcessArgument' {
        It 'leaves a plain value alone' { InModuleScope VDI-GIPipeline { ConvertTo-GIProcessArgument 'C:\plain\x.ps1' } | Should -Be 'C:\plain\x.ps1' }
        It 'quotes a value with spaces' { InModuleScope VDI-GIPipeline { ConvertTo-GIProcessArgument 'C:\my dir\x.ps1' } | Should -Be '"C:\my dir\x.ps1"' }
        It 'escapes an embedded quote' { InModuleScope VDI-GIPipeline { ConvertTo-GIProcessArgument 'say "hi"' } | Should -Be '"say \"hi\""' }
        It 'doubles a trailing backslash inside quotes' { InModuleScope VDI-GIPipeline { ConvertTo-GIProcessArgument 'C:\my dir\' } | Should -Be '"C:\my dir\\"' }
    }

    Context 'Runner started through a path with spaces' {
        It 'reaches the runner and writes a transcript and a Runner started line' {
            $pipe = Join-Path $TestDrive 'dir with spaces/Pipeline'
            New-Item -ItemType Directory -Path (Join-Path $pipe 'config') -Force | Out-Null
            $src = Join-Path $PSScriptRoot '..'
            Copy-Item -Path (Join-Path $src 'src') -Destination $pipe -Recurse
            foreach ($f in 'VDI-GIPipeline.psd1', 'VDI-GIPipeline.psm1', 'Invoke-GISetupStep.ps1', 'pipeline.config.psd1') { Copy-Item -LiteralPath (Join-Path $src $f) -Destination $pipe }
            $cfgPath = Join-Path $pipe 'pipeline.config.psd1'
            $c2 = @{ Root = $pipe; Paths = @{ State = (Join-Path $pipe 'state'); Logs = (Join-Path $pipe 'logs') } }
            Set-GISetupStep -Config $c2 -Step Vault -Status running -Message 'Starting...'
            $argList = @('-NoProfile', '-File', (ConvertTo-GIProcessArgument (Join-Path $pipe 'Invoke-GISetupStep.ps1')), '-Step', 'Vault', '-ConfigPath', (ConvertTo-GIProcessArgument $cfgPath))
            $p = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argList -PassThru -Wait -RedirectStandardOutput (Join-Path $pipe 'config/out.log') -RedirectStandardError (Join-Path $pipe 'config/err.log')
            $p | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath (Join-Path $pipe 'config/setup-Vault.transcript.log') | Should -BeTrue
            $detail = @((Read-RawSetup $c2).steps.Vault.detail)
            ($detail -join "`n") | Should -Match 'Runner started \(pid '
        }
    }

    Context 'Invoke-GISetupTasks' {
        BeforeEach {
            Set-GISetupMode -Config $cfg -Mode Production -By tester
            Mock -ModuleName VDI-GIPipeline Get-GIPipelineTaskDefinition { @(@{ Name = 'VDI-GI-Run' }, @{ Name = 'VDI-GI-Dashboard' }) }
            Mock -ModuleName VDI-GIPipeline Register-GIPipelineTask {
                $global:GISetupCtx.Registered++
                @([pscustomobject]@{ Name = 'VDI-GI-Run' }, [pscustomobject]@{ Name = 'VDI-GI-Dashboard' })
            }
            Mock -ModuleName VDI-GIPipeline Test-GIWindowsCredential { $true }
        }
        It 'is skipped in Lab mode' {
            $lab = Get-GISetupState -Config $cfg
            $lab.mode = 'Lab'
            $r = Invoke-GISetupTasks -Config $cfg -State $lab -Credential (New-MyCredential)
            $r.Skipped | Should -BeTrue
            Should -Invoke Register-GIPipelineTask -ModuleName VDI-GIPipeline -Times 0
        }
        It 'is skipped with -Skip and never registers' {
            $r = Invoke-GISetupTasks -Config $cfg -State (Get-GISetupState -Config $cfg) -Skip
            $r.Skipped | Should -BeTrue
            Should -Invoke Register-GIPipelineTask -ModuleName VDI-GIPipeline -Times 0
            Should -Invoke Get-GIPipelineTaskDefinition -ModuleName VDI-GIPipeline -Times 0
        }
        It 'throws without a credential' {
            { Invoke-GISetupTasks -Config $cfg -State (Get-GISetupState -Config $cfg) } | Should -Throw '*Enter your Windows password*'
        }
        It 'throws for a credential of another user' {
            { Invoke-GISetupTasks -Config $cfg -State (Get-GISetupState -Config $cfg) -Credential (New-MyCredential -User 'someone-else') } | Should -Throw '*Tasks run as the user who runs setup*'
            Should -Invoke Register-GIPipelineTask -ModuleName VDI-GIPipeline -Times 0
        }
        It 'throws when Windows rejects the password' {
            Mock -ModuleName VDI-GIPipeline Test-GIWindowsCredential { $false }
            { Invoke-GISetupTasks -Config $cfg -State (Get-GISetupState -Config $cfg) -Credential (New-MyCredential) } | Should -Throw '*not accepted by Windows*'
            Should -Invoke Register-GIPipelineTask -ModuleName VDI-GIPipeline -Times 0
        }
        It 'registers once and returns data without the password' {
            $r = Invoke-GISetupTasks -Config $cfg -State (Get-GISetupState -Config $cfg) -Credential (New-MyCredential)
            Should -Invoke Register-GIPipelineTask -ModuleName VDI-GIPipeline -Times 1
            $r.Message | Should -Match 'Registered 2 scheduled tasks'
            @($r.Data.tasks) | Should -Be @('VDI-GI-Run', 'VDI-GI-Dashboard')
            ($r | ConvertTo-Json -Depth 6) | Should -Not -Match 'Pw-Unique-12345'
        }
        It 'never lets the password reach setup.json or the audit log' {
            Set-StepsDone -Config $cfg -Steps 'Prerequisites', 'Modules', 'PowerCLI', 'Vault', 'DashboardAccess'
            Invoke-GISetupStepCore -Config $cfg -Step Tasks -Arguments @{ Credential = (New-MyCredential) } | Should -BeTrue
            (Get-GISetupState -Config $cfg).steps.Tasks.status | Should -Be 'done'
            (Get-Content -LiteralPath (Join-Path $cfg.Root 'config' 'setup.json') -Raw) | Should -Not -Match 'Pw-Unique-12345'
            $global:GISetupCtx.Audit.Count | Should -BeGreaterThan 0
            ($global:GISetupCtx.Audit | ConvertTo-Json -Depth 8) | Should -Not -Match 'Pw-Unique-12345'
        }
        It 'does not leak the password into the failure record either' {
            Mock -ModuleName VDI-GIPipeline Test-GIWindowsCredential { $false }
            Invoke-GISetupStepCore -Config $cfg -Step Tasks -Arguments @{ Credential = (New-MyCredential) } | Should -BeFalse
            (Get-Content -LiteralPath (Join-Path $cfg.Root 'config' 'setup.json') -Raw) | Should -Not -Match 'Pw-Unique-12345'
            ($global:GISetupCtx.Audit | ConvertTo-Json -Depth 8) | Should -Not -Match 'Pw-Unique-12345'
        }
    }

    Context 'Invoke-GISetupDashboardAccess' {
        BeforeEach {
            $script:thumb = 'AB' * 20
            $script:prod = Get-GISetupState -Config $cfg
            $script:prod.mode = 'Production'
            $script:opts = @{ Port = '8443'; CertThumbprint = $script:thumb; ViewerGroup = 'CORP\GI-Viewers'; ApproverGroup = 'CORP\GI-Approvers'; AdminGroup = 'CORP\GI-Admins' }
            Mock -ModuleName VDI-GIPipeline Test-GIAdGroup { $true }
            Mock -ModuleName VDI-GIPipeline Get-GIServerCertificate { @([pscustomobject]@{ Thumbprint = ('AB' * 20); Subject = 'CN=x'; NotAfter = (Get-Date).AddYears(1) }) }
            Mock -ModuleName VDI-GIPipeline Get-NetFirewallRule { $null }
            Mock -ModuleName VDI-GIPipeline New-NetFirewallRule { }
            Mock -ModuleName VDI-GIPipeline Update-GISettingsOverlay { $global:GISetupCtx.Set = $Set; 'settings.json' }
            Mock -ModuleName VDI-GIPipeline New-SelfSignedCertificate { [pscustomobject]@{ Thumbprint = ('cd' * 20) } }
        }
        It 'is skipped in Lab mode' {
            $lab = Get-GISetupState -Config $cfg
            $lab.mode = 'Lab'
            (Invoke-GISetupDashboardAccess -Config $cfg -State $lab -Options $opts).Skipped | Should -BeTrue
            Should -Invoke Update-GISettingsOverlay -ModuleName VDI-GIPipeline -Times 0
        }
        It 'lists every validation error at once' {
            $bad = @{ Port = '70000'; CertThumbprint = 'zzz'; ViewerGroup = ''; ApproverGroup = 'CORP\GI-Approvers'; AdminGroup = 'CORP\GI-Admins' }
            $msg = try { Invoke-GISetupDashboardAccess -Config $cfg -State $prod -Options $bad; '' } catch { $_.Exception.Message }
            $msg | Should -Match 'Port must be 1-65535'
            $msg | Should -Match 'ViewerGroup is required'
            $msg | Should -Match 'Pick a certificate'
            Should -Invoke Update-GISettingsOverlay -ModuleName VDI-GIPipeline -Times 0
        }
        It 'rejects a non-numeric port' {
            $o = $opts.Clone(); $o.Port = 'abc'
            { Invoke-GISetupDashboardAccess -Config $cfg -State $prod -Options $o } | Should -Throw '*Port must be 1-65535*'
        }
        It 'names a group that is not found in AD' {
            Mock -ModuleName VDI-GIPipeline Test-GIAdGroup { $Group -ne 'CORP\GI-Approvers' }
            $msg = try { Invoke-GISetupDashboardAccess -Config $cfg -State $prod -Options $opts; '' } catch { $_.Exception.Message }
            $msg | Should -Match "ApproverGroup 'CORP\\GI-Approvers' wasn't found"
            $msg | Should -Not -Match 'ViewerGroup'
        }
        It 'reports an AD lookup failure' {
            Mock -ModuleName VDI-GIPipeline Test-GIAdGroup { throw 'no domain' }
            { Invoke-GISetupDashboardAccess -Config $cfg -State $prod -Options $opts } | Should -Throw "*Couldn't check ViewerGroup*no domain*"
        }
        It 'rejects a thumbprint that is not a valid server certificate' {
            Mock -ModuleName VDI-GIPipeline Get-GIServerCertificate { @() }
            { Invoke-GISetupDashboardAccess -Config $cfg -State $prod -Options $opts } | Should -Throw '*not a valid server certificate*'
        }
        It 'writes the Dashboard.* settings and opens the firewall on success' {
            $r = Invoke-GISetupDashboardAccess -Config $cfg -State $prod -Options $opts
            $paths = @($global:GISetupCtx.Set | ForEach-Object { $_.Path })
            $paths | Should -Be @('Dashboard.Port', 'Dashboard.CertificateThumbprint', 'Dashboard.ViewerGroup', 'Dashboard.ApproverGroup', 'Dashboard.AdminGroup')
            ($global:GISetupCtx.Set | Where-Object Path -eq 'Dashboard.Port').Value | Should -Be 8443
            ($global:GISetupCtx.Set | Where-Object Path -eq 'Dashboard.CertificateThumbprint').Value | Should -Be ('AB' * 20)
            ($global:GISetupCtx.Set | Where-Object Path -eq 'Dashboard.AdminGroup').Value | Should -Be 'CORP\GI-Admins'
            $r.Data.port | Should -Be 8443
            $r.Data.selfSigned | Should -BeFalse
            Should -Invoke New-NetFirewallRule -ModuleName VDI-GIPipeline -Times 1 -ParameterFilter { $LocalPort -eq 8443 }
            Should -Invoke New-SelfSignedCertificate -ModuleName VDI-GIPipeline -Times 0
        }
        It 'upper-cases a lower-case thumbprint' {
            $o = $opts.Clone(); $o.CertThumbprint = ('ab' * 20)
            Invoke-GISetupDashboardAccess -Config $cfg -State $prod -Options $o | Out-Null
            ($global:GISetupCtx.Set | Where-Object Path -eq 'Dashboard.CertificateThumbprint').Value | Should -Be ('AB' * 20)
        }
        It 'does not add a firewall rule that already exists' {
            Mock -ModuleName VDI-GIPipeline Get-NetFirewallRule { [pscustomobject]@{ DisplayName = 'x' } }
            Invoke-GISetupDashboardAccess -Config $cfg -State $prod -Options $opts | Out-Null
            Should -Invoke New-NetFirewallRule -ModuleName VDI-GIPipeline -Times 0
        }
        It 'creates a self-signed certificate when asked' {
            $o = $opts.Clone(); $o.CertThumbprint = '__selfsigned__'
            $r = Invoke-GISetupDashboardAccess -Config $cfg -State $prod -Options $o
            Should -Invoke New-SelfSignedCertificate -ModuleName VDI-GIPipeline -Times 1
            ($global:GISetupCtx.Set | Where-Object Path -eq 'Dashboard.CertificateThumbprint').Value | Should -Be ('CD' * 20)
            $r.Data.selfSigned | Should -BeTrue
            $r.Data.thumbprint | Should -Be ('CD' * 20)
        }
    }

    Context 'Complete-GISetup' {
        It 'refuses until all earlier steps are done or skipped' {
            Set-GISetupMode -Config $cfg -Mode Lab -By tester
            { Complete-GISetup -Config $cfg -By tester } | Should -Throw "*next step is 'Prerequisites'*"
            Test-GISetupComplete -Config $cfg | Should -BeFalse
        }
        It 'Lab: sets completedAt and does not start the dashboard task' {
            Set-GISetupMode -Config $cfg -Mode Lab -By tester
            Set-StepsDone -Config $cfg -Steps 'Prerequisites', 'Modules', 'PowerCLI', 'Vault'
            $r = Complete-GISetup -Config $cfg -By tester
            $r.Mode | Should -Be 'Lab'
            $r.StartDashboardTask | Should -BeFalse
            Test-GISetupComplete -Config $cfg | Should -BeTrue
            (Get-GISetupState -Config $cfg).steps.Finish.status | Should -Be 'done'
            Should -Invoke Write-GIAudit -ModuleName VDI-GIPipeline -ParameterFilter { $Target -eq 'Finish' }
        }
        It 'Production with Tasks done: starts the dashboard task' {
            Set-GISetupMode -Config $cfg -Mode Production -By tester
            Set-StepsDone -Config $cfg -Steps 'Prerequisites', 'Modules', 'PowerCLI', 'Vault', 'DashboardAccess', 'Tasks'
            $r = Complete-GISetup -Config $cfg -By tester
            $r.StartDashboardTask | Should -BeTrue
            (Get-GISetupState -Config $cfg).steps.Finish.message | Should -Match 'VDI-GI-Dashboard'
        }
        It 'Production with Tasks skipped: does not start the dashboard task' {
            Set-GISetupMode -Config $cfg -Mode Production -By tester
            Set-StepsDone -Config $cfg -Steps 'Prerequisites', 'Modules', 'PowerCLI', 'Vault', 'DashboardAccess'
            Set-GISetupStep -Config $cfg -Step Tasks -Status skipped -Message 'later'
            (Complete-GISetup -Config $cfg -By tester).StartDashboardTask | Should -BeFalse
        }
        It 'refuses to complete twice' {
            Set-GISetupMode -Config $cfg -Mode Lab -By tester
            Set-StepsDone -Config $cfg -Steps 'Prerequisites', 'Modules', 'PowerCLI', 'Vault'
            Complete-GISetup -Config $cfg -By tester | Out-Null
            { Complete-GISetup -Config $cfg -By tester } | Should -Throw '*already complete*'
        }
    }

    Context 'Reset-GISetup' {
        It 'returns null when there is no setup.json' {
            Reset-GISetup -Config $cfg | Should -BeNullOrEmpty
        }
        It 'moves setup.json aside and returns the new path' {
            Set-GISetupMode -Config $cfg -Mode Lab -By tester
            $orig = Join-Path $cfg.Root 'config' 'setup.json'
            $dest = Reset-GISetup -Config $cfg
            $dest | Should -Match 'setup\.\d{8}-\d{6}\.json$'
            Test-Path -LiteralPath $dest | Should -BeTrue
            Test-Path -LiteralPath $orig | Should -BeFalse
            (Get-GISetupState -Config $cfg).steps.Mode.status | Should -Be 'pending'
        }
    }

    Context 'Invoke-GISetupVault' {
        BeforeEach {
            $script:st = Get-GISetupState -Config $cfg
            Mock -ModuleName VDI-GIPipeline Import-Module { } -ParameterFilter { $Name -like 'Microsoft.PowerShell.Secret*' }
            Mock -ModuleName VDI-GIPipeline Get-SecretVault { }
            Mock -ModuleName VDI-GIPipeline Register-SecretVault { $global:GISetupCtx.Reg = @{ Name = $Name; ModuleName = $ModuleName; DefaultVault = $DefaultVault } }
            Mock -ModuleName VDI-GIPipeline Set-SecretVaultDefault { }
            Mock -ModuleName VDI-GIPipeline Set-SecretStoreConfiguration { $global:GISetupCtx.StoreCfg = @{ Authentication = $Authentication; Interaction = $Interaction; Scope = $Scope } }
            Mock -ModuleName VDI-GIPipeline Get-SecretStoreConfiguration { [pscustomobject]@{ Authentication = 'None'; Interaction = 'None' } }
            Mock -ModuleName VDI-GIPipeline Test-SecretVault { $true }
        }
        It 'refuses an existing SecretStore default that asks for a password' {
            Mock -ModuleName VDI-GIPipeline Get-SecretVault { [pscustomobject]@{ Name = 'Mine'; ModuleName = 'Microsoft.PowerShell.SecretStore'; IsDefault = $true } }
            Mock -ModuleName VDI-GIPipeline Get-SecretStoreConfiguration { [pscustomobject]@{ Authentication = 'Password'; Interaction = 'Prompt' } }
            { Invoke-GISetupVault -Config $cfg -State $st } | Should -Throw '*Set-SecretStoreConfiguration*'
            Should -Invoke Register-SecretVault -ModuleName VDI-GIPipeline -Times 0
            Should -Invoke Set-SecretStoreConfiguration -ModuleName VDI-GIPipeline -Times 0
        }
        It 'uses an existing usable default vault without registering' {
            Mock -ModuleName VDI-GIPipeline Get-SecretVault { [pscustomobject]@{ Name = 'Mine'; ModuleName = 'Microsoft.PowerShell.SecretStore'; IsDefault = $true } }
            $r = Invoke-GISetupVault -Config $cfg -State $st
            $r.Data.created | Should -BeFalse
            $r.Data.vault | Should -Be 'Mine'
            Should -Invoke Register-SecretVault -ModuleName VDI-GIPipeline -Times 0
            Should -Invoke Set-SecretStoreConfiguration -ModuleName VDI-GIPipeline -Times 0
        }
        It 'accepts a non-SecretStore default vault that tests fine' {
            Mock -ModuleName VDI-GIPipeline Get-SecretVault { [pscustomobject]@{ Name = 'KV'; ModuleName = 'Az.KeyVault'; IsDefault = $true } }
            (Invoke-GISetupVault -Config $cfg -State $st).Data.created | Should -BeFalse
            Should -Invoke Get-SecretStoreConfiguration -ModuleName VDI-GIPipeline -Times 0
        }
        It 'throws when the existing default vault is not usable' {
            Mock -ModuleName VDI-GIPipeline Get-SecretVault { [pscustomobject]@{ Name = 'Mine'; ModuleName = 'Microsoft.PowerShell.SecretStore'; IsDefault = $true } }
            Mock -ModuleName VDI-GIPipeline Test-SecretVault { $false }
            { Invoke-GISetupVault -Config $cfg -State $st } | Should -Throw '*not usable*'
        }
        It 'registers VDIPipeline as default with Authentication None when none exists' {
            $r = Invoke-GISetupVault -Config $cfg -State $st
            $r.Data.created | Should -BeTrue
            $r.Data.vault | Should -Be 'VDIPipeline'
            Should -Invoke Register-SecretVault -ModuleName VDI-GIPipeline -Times 1
            $global:GISetupCtx.Reg.Name | Should -Be 'VDIPipeline'
            $global:GISetupCtx.Reg.ModuleName | Should -Be 'Microsoft.PowerShell.SecretStore'
            $global:GISetupCtx.Reg.DefaultVault.IsPresent | Should -BeTrue
            $global:GISetupCtx.StoreCfg.Authentication | Should -Be 'None'
            $global:GISetupCtx.StoreCfg.Interaction | Should -Be 'None'
        }
        It 'makes an already registered but non-default VDIPipeline vault the default instead of re-registering' {
            Mock -ModuleName VDI-GIPipeline Get-SecretVault { if ($Name -eq 'VDIPipeline') { [pscustomobject]@{ Name = 'VDIPipeline'; ModuleName = 'Microsoft.PowerShell.SecretStore'; IsDefault = $false } } }
            Invoke-GISetupVault -Config $cfg -State $st | Out-Null
            Should -Invoke Set-SecretVaultDefault -ModuleName VDI-GIPipeline -Times 1
            Should -Invoke Register-SecretVault -ModuleName VDI-GIPipeline -Times 0
        }
    }
}
