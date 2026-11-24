BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'VDI-GIPipeline.psd1') -Force

    # Mock bodies run bound to the module, so test data is shared through one global hashtable
    $global:GITestCtx = @{}
    function Set-ModVar { param([string] $Name, $Value) $global:GITestCtx[$Name] = $Value }
    function New-TestPool {
        param($Id = 'pool-1', $Name = 'TST-W11', $Snap = 'snap-1', $PendingSnap = $null, $PendingState = $null)
        [pscustomobject]@{
            id = $Id; name = $Name
            provisioning_settings = [pscustomobject]@{ parent_vm_id = 'vm-1'; base_snapshot_id = $Snap }
            provisioning_status_data = [pscustomobject]@{
                instant_clone_pending_image_snapshot_id = $PendingSnap
                instant_clone_pending_image_state       = $PendingState
            }
        }
    }
    function New-TestMachine { param($Name, $State = 'AVAILABLE') [pscustomobject]@{ name = $Name; state = $State } }
    function New-TestConfig {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $c = @{
            Root        = $root
            Paths       = @{ State = (Join-Path $root 'state'); Reports = (Join-Path $root 'reports'); Logs = (Join-Path $root 'logs') }
            GoldenImage = @{ VmName = 'GI-VM'; GuestCredentialSecret = 'GI-GuestAdmin' }
            Pools       = @{ Test = @{ Name = 'TST-W11' }; Production = @(@{ Name = 'PRD-A' }, @{ Name = 'PRD-B' }); PushTimeoutMin = 5 }
            Validation  = @{ GuestSampleCount = 2; RequiredServices = @('wsnm', 'svservice'); MachineReadyTimeoutMin = 0 }
            AppVolumes  = @{ Server = 'avm'; TestPackages = @('Notepad++') }
        }
        New-Item -ItemType Directory -Path $c.Paths.State -Force | Out-Null
        $c
    }
}

AfterAll { Remove-Variable -Name GITestCtx -Scope Global -ErrorAction SilentlyContinue }

Describe 'Pipeline stages' {
BeforeEach {
    InModuleScope VDI-GIPipeline {
        function script:Get-VM { param($Name, $Id, $ErrorAction) }
    }
    Mock -ModuleName VDI-GIPipeline Start-Sleep { }
    Mock -ModuleName VDI-GIPipeline Write-GILog { }
    $script:cfg = New-TestConfig
    $script:run = New-GIRun -Config $cfg -RunId '20261124-010101'
}

Describe 'Get-GIConfigValue' {
    It 'returns a nested value' {
        Get-GIConfigValue @{ A = @{ B = @{ C = 42 } } } 'A.B.C' 0 | Should -Be 42
    }
    It 'returns the default when a key is missing' {
        Get-GIConfigValue @{ A = @{ B = 1 } } 'A.X.Y' 'dflt' | Should -Be 'dflt'
        Get-GIConfigValue @{} 'A' 'dflt' | Should -Be 'dflt'
    }
    It 'returns the default for an empty string' {
        Get-GIConfigValue @{ A = '' } 'A' 'dflt' | Should -Be 'dflt'
    }
    It 'returns the default for $null' {
        Get-GIConfigValue @{ A = $null } 'A' 'dflt' | Should -Be 'dflt'
    }
}

Describe 'Invoke-GIStage' {
    # Regression: Set-GIProgress must accept '' (Invoke-GIStage clears progress on success)
    It 'marks the stage Succeeded, merges Message and Data, and clears progress' {
        $run.progress = 'old progress'
        Invoke-GIStage -Config $cfg -Run $run -Stage Snapshot -Action { @{ Message = 'all good'; Data = @{ foo = 'bar' } } }
        $r = Get-GIRun -Config $cfg -RunId $run.runId
        $r.stages.Snapshot.status | Should -Be 'Succeeded'
        $r.stages.Snapshot.message | Should -Be 'all good'
        $r.stages.Snapshot.data.foo | Should -Be 'bar'
        $r.stages.Snapshot.endedAt | Should -Not -BeNullOrEmpty
        $r.progress | Should -Be ''
        $r.status | Should -Be 'Running'
    }

    # Regression: StrictMode must not throw on a result hashtable without a Data key
    It 'accepts an action result that has only a Message (no Data)' {
        Invoke-GIStage -Config $cfg -Run $run -Stage Validate -Action { @{ Message = 'only message' } }
        (Get-GIRun -Config $cfg -RunId $run.runId).stages.Validate.status | Should -Be 'Succeeded'
    }

    It 'marks stage and run Failed, records the stage name in the error and rethrows' {
        { Invoke-GIStage -Config $cfg -Run $run -Stage Maintain -Action { throw 'kaboom' } } | Should -Throw '*kaboom*'
        $r = Get-GIRun -Config $cfg -RunId $run.runId
        $r.stages.Maintain.status | Should -Be 'Failed'
        $r.status | Should -Be 'Failed'
        $r.error | Should -Match 'Maintain'
        $r.error | Should -Match 'kaboom'
    }
}

Describe 'Invoke-GIStagePreflight' {
    BeforeEach {
        Mock -ModuleName VDI-GIPipeline Get-GIHorizonBaseImage { [pscustomobject]@{ BaseVm = [pscustomobject]@{ id = 'bvm-1' } } }
        Set-ModVar Pools @(
            (New-TestPool -Id 'p-t' -Name 'TST-W11')
            (New-TestPool -Id 'p-a' -Name 'PRD-A')
            (New-TestPool -Id 'p-b' -Name 'PRD-B')
        )
        Mock -ModuleName VDI-GIPipeline Get-GIHorizonPool { $global:GITestCtx.Pools | Where-Object name -eq $Name | Select-Object -First 1 }
    }

    It 'throws when the golden VM is powered on' {
        Mock -ModuleName VDI-GIPipeline Get-VM { [pscustomobject]@{ Name = 'GI-VM'; PowerState = 'PoweredOn' } }
        { Invoke-GIStagePreflight -Config $cfg -Run $run } | Should -Throw '*PoweredOn*'
    }

    It 'throws naming the pool when a pool has a pending snapshot' {
        Mock -ModuleName VDI-GIPipeline Get-VM { [pscustomobject]@{ Name = 'GI-VM'; PowerState = 'PoweredOff' } }
        Set-ModVar Pools @(
            (New-TestPool -Id 'p-t' -Name 'TST-W11')
            (New-TestPool -Id 'p-a' -Name 'PRD-A' -PendingSnap 'snap-9' -PendingState 'IN_PROGRESS')
            (New-TestPool -Id 'p-b' -Name 'PRD-B')
        )
        { Invoke-GIStagePreflight -Config $cfg -Run $run } | Should -Throw "*'PRD-A'*"
    }

    It 'returns poolIds for the test pool and all production pools' {
        Mock -ModuleName VDI-GIPipeline Get-VM { [pscustomobject]@{ Name = 'GI-VM'; PowerState = 'PoweredOff' } }
        $r = Invoke-GIStagePreflight -Config $cfg -Run $run
        $r.Data.poolIds.Keys | Sort-Object | Should -Be @('PRD-A', 'PRD-B', 'TST-W11')
        $r.Data.poolIds['PRD-B'] | Should -Be 'p-b'
        $r.Data.baseVmId | Should -Be 'bvm-1'
    }
}

Describe 'Wait-GIPoolPush' {
    BeforeEach {
        Set-ModVar Polls 0
    }

    It 'returns once the pending snapshot clears and the snapshot matches' {
        Mock -ModuleName VDI-GIPipeline Get-GIHorizonPool {
            $global:GITestCtx.Polls++
            if ($global:GITestCtx.Polls -eq 1) { [pscustomobject]@{ id = 'p'; name = $Name; provisioning_settings = [pscustomobject]@{ parent_vm_id = 'v'; base_snapshot_id = 'old' }
                    provisioning_status_data = [pscustomobject]@{ instant_clone_pending_image_snapshot_id = 'new'; instant_clone_pending_image_state = 'IN_PROGRESS' } } }
            else { [pscustomobject]@{ id = 'p'; name = $Name; provisioning_settings = [pscustomobject]@{ parent_vm_id = 'v'; base_snapshot_id = 'new' }
                    provisioning_status_data = [pscustomobject]@{ instant_clone_pending_image_snapshot_id = $null; instant_clone_pending_image_state = $null } } }
        }
        $info = Wait-GIPoolPush -Config $cfg -Run $run -PoolName 'TST-W11' -ExpectedSnapshotId 'new'
        $info.SnapshotId | Should -Be 'new'
        $global:GITestCtx.Polls | Should -Be 2
        Should -Invoke -ModuleName VDI-GIPipeline Start-Sleep -Times 1
    }

    It "throws when the pending state is 'FAILED'" {
        Set-ModVar Pools @(New-TestPool -Name 'TST-W11' -Snap 'old' -PendingSnap 'new' -PendingState 'FAILED')
        Mock -ModuleName VDI-GIPipeline Get-GIHorizonPool { $global:GITestCtx.Pools | Select-Object -First 1 }
        { Wait-GIPoolPush -Config $cfg -Run $run -PoolName 'TST-W11' -ExpectedSnapshotId 'new' } | Should -Throw '*failed*FAILED*'
    }

    It 'throws on timeout' {
        Set-ModVar Pools @(New-TestPool -Name 'TST-W11' -Snap 'old' -PendingSnap 'new' -PendingState 'IN_PROGRESS')
        Mock -ModuleName VDI-GIPipeline Get-GIHorizonPool { $global:GITestCtx.Pools | Select-Object -First 1 }
        { Wait-GIPoolPush -Config $cfg -Run $run -PoolName 'TST-W11' -ExpectedSnapshotId 'new' -TimeoutMinutes 0 } | Should -Throw '*not finished*'
    }
}

Describe 'Test-GIPoolHealth (Horizon)' {
    BeforeEach {
        Set-ModVar Pools @(New-TestPool -Id 'p-t' -Name 'TST-W11' -Snap 'snap-1')
        Mock -ModuleName VDI-GIPipeline Get-GIHorizonPool { $global:GITestCtx.Pools | Select-Object -First 1 }
        Set-ModVar Machines @(New-TestMachine 'TST-W11-1')
        Mock -ModuleName VDI-GIPipeline Get-GIHorizonPoolMachines { $global:GITestCtx.Machines }
    }

    It 'passes PoolImage when the snapshot matches and fails when it differs' {
        $ok = Test-GIPoolHealth -Config $cfg -Run $run -PoolName 'TST-W11' -ExpectedSnapshotId 'snap-1'
        ($ok | Where-Object name -eq 'PoolImage').passed | Should -BeTrue
        $bad = Test-GIPoolHealth -Config $cfg -Run $run -PoolName 'TST-W11' -ExpectedSnapshotId 'snap-OTHER'
        ($bad | Where-Object name -eq 'PoolImage').passed | Should -BeFalse
    }

    It 'skips PoolImage when no expected snapshot is given' {
        $r = Test-GIPoolHealth -Config $cfg -Run $run -PoolName 'TST-W11'
        $r | Where-Object name -eq 'PoolImage' | Should -BeNullOrEmpty
    }

    It 'MachineState: <state> -> passed=<expected>' -ForEach @(
        @{ state = 'ERROR'; expected = $false }
        @{ state = 'AGENT_UNREACHABLE'; expected = $false }
        @{ state = 'AVAILABLE'; expected = $true }
        @{ state = 'CONNECTED'; expected = $true }
        @{ state = 'DISCONNECTED'; expected = $true }
    ) {
        Set-ModVar Machines @(New-TestMachine 'TST-W11-1' $state)
        $c = Test-GIPoolHealth -Config $cfg -Run $run -PoolName 'TST-W11' | Where-Object name -eq 'MachineState'
        $c.passed | Should -Be $expected
        $c.detail | Should -Be $state
    }

    It 'MachineCount fails when the pool has zero machines' {
        Set-ModVar Machines @()
        $c = Test-GIPoolHealth -Config $cfg -Run $run -PoolName 'TST-W11' | Where-Object name -eq 'MachineCount'
        $c.passed | Should -BeFalse
    }
}

Describe 'Test-GIPoolHealth -IncludeGuest' {
    BeforeEach {
        Set-ModVar Pools @(New-TestPool -Id 'p-t' -Name 'TST-W11' -Snap 'snap-1')
        Mock -ModuleName VDI-GIPipeline Get-GIHorizonPool { $global:GITestCtx.Pools | Select-Object -First 1 }
        Set-ModVar Machines @(New-TestMachine 'TST-W11-1')
        Mock -ModuleName VDI-GIPipeline Get-GIHorizonPoolMachines { $global:GITestCtx.Machines }
        $cred = [pscredential]::new('admin', (ConvertTo-SecureString 'x' -AsPlainText -Force))
        Set-ModVar Cred $cred
        Mock -ModuleName VDI-GIPipeline Get-GISecretCredential { $global:GITestCtx.Cred }
        Mock -ModuleName VDI-GIPipeline Get-VM { [pscustomobject]@{ Name = $Name; Id = "id-$Name" } }
        Set-ModVar ProbeJson '{"services":{"wsnm":"Running","svservice":"Stopped"},"versions":{"Horizon":"2512.0.0"}}'
        Mock -ModuleName VDI-GIPipeline Invoke-GIGuestScript { [pscustomobject]@{ ScriptOutput = $global:GITestCtx.ProbeJson; ExitCode = 0 } }
    }

    It 'reports service state per required service' {
        $r = Test-GIPoolHealth -Config $cfg -Run $run -PoolName 'TST-W11' -IncludeGuest
        ($r | Where-Object name -eq 'Service:svservice').passed | Should -BeFalse
        ($r | Where-Object name -eq 'Service:svservice').detail | Should -Be 'Stopped'
        ($r | Where-Object name -eq 'Service:wsnm').passed | Should -BeTrue
    }

    It 'passes the Horizon version check when the manifest matches' {
        $r = Test-GIPoolHealth -Config $cfg -Run $run -PoolName 'TST-W11' -IncludeGuest -Manifest @{ Horizon = '2512.0.0' }
        ($r | Where-Object name -eq 'Version:Horizon').passed | Should -BeTrue
    }

    It 'fails the Horizon version check when the manifest differs' {
        $r = Test-GIPoolHealth -Config $cfg -Run $run -PoolName 'TST-W11' -IncludeGuest -Manifest @{ Horizon = '2603.0.0' }
        ($r | Where-Object name -eq 'Version:Horizon').passed | Should -BeFalse
    }

    It 'turns a probe exception into a failed Guest/Probe check' {
        Mock -ModuleName VDI-GIPipeline Invoke-GIGuestScript { throw 'tools not running' }
        $r = $null
        { $script:r = Test-GIPoolHealth -Config $cfg -Run $run -PoolName 'TST-W11' -IncludeGuest } | Should -Not -Throw
        $p = $script:r | Where-Object { $_.category -eq 'Guest' -and $_.name -eq 'Probe' }
        $p.passed | Should -BeFalse
        $p.detail | Should -Match 'tools not running'
    }

    It 'probes only AVAILABLE machines, at most GuestSampleCount' {
        Set-ModVar Machines @(
            (New-TestMachine 'TST-W11-1' 'ERROR')
            (New-TestMachine 'TST-W11-2' 'AVAILABLE')
            (New-TestMachine 'TST-W11-3' 'CONNECTED')
            (New-TestMachine 'TST-W11-4' 'AVAILABLE')
            (New-TestMachine 'TST-W11-5' 'AVAILABLE')
            (New-TestMachine 'TST-W11-6' 'AVAILABLE')
        )
        Test-GIPoolHealth -Config $cfg -Run $run -PoolName 'TST-W11' -IncludeGuest | Out-Null
        Should -Invoke -ModuleName VDI-GIPipeline Invoke-GIGuestScript -Times 2 -Exactly
        Should -Invoke -ModuleName VDI-GIPipeline Get-VM -Times 1 -Exactly -ParameterFilter { $Name -eq 'TST-W11-2' }
        Should -Invoke -ModuleName VDI-GIPipeline Get-VM -Times 1 -Exactly -ParameterFilter { $Name -eq 'TST-W11-4' }
        Should -Invoke -ModuleName VDI-GIPipeline Get-VM -Times 0 -Exactly -ParameterFilter { $Name -in 'TST-W11-1', 'TST-W11-3', 'TST-W11-5' }
    }

    It 'adds a failed Probe check when no machine is AVAILABLE' {
        Set-ModVar Machines @(New-TestMachine 'TST-W11-1' 'ERROR')
        $r = Test-GIPoolHealth -Config $cfg -Run $run -PoolName 'TST-W11' -IncludeGuest
        ($r | Where-Object { $_.category -eq 'Guest' -and $_.name -eq 'Probe' }).passed | Should -BeFalse
        Should -Invoke -ModuleName VDI-GIPipeline Invoke-GIGuestScript -Times 0 -Exactly
    }
}

Describe 'Test-GIPoolHealth -IncludeAppVolumes' {
    BeforeEach {
        InModuleScope VDI-GIPipeline { $script:GIAppVol = @{ BaseUri = 'x' } }
        Set-ModVar Pools @(New-TestPool -Id 'p-t' -Name 'TST-W11' -Snap 'snap-1')
        Mock -ModuleName VDI-GIPipeline Get-GIHorizonPool { $global:GITestCtx.Pools | Select-Object -First 1 }
        Set-ModVar Machines @(New-TestMachine 'TST-W11-1')
        Mock -ModuleName VDI-GIPipeline Get-GIHorizonPoolMachines { $global:GITestCtx.Machines }
        # Parse JSON so arrays come back as [object[]] like Invoke-RestMethod would
        Set-ModVar OnlineResp ('{"online":{"records":[{"computer_name":"TST-W11-1"}]}}' | ConvertFrom-Json)
        Set-ModVar AttachResp ('{"data":[{"computer":"TST-W11-1","package":"Notepad++ 8.6"}]}' | ConvertFrom-Json)
        Mock -ModuleName VDI-GIPipeline Invoke-GIAppVolApi {
            if ($global:GITestCtx.AvThrow) { throw 'AVM unreachable' }
            if ($Path -like '*online_entities*') { $global:GITestCtx.OnlineResp } else { $global:GITestCtx.AttachResp }
        }
        Mock -ModuleName VDI-GIPipeline Get-GIAppVolOnlineEntities {
            if ($global:GITestCtx.AvThrow) { throw 'AVM unreachable' }
            @{ Entities = @(Get-GIAppVolCollection $global:GITestCtx.OnlineResp); Path = '/cv_api/online_entities'; Trail = @() }
        }
        Set-ModVar AvThrow $false
    }
    AfterEach {
        InModuleScope VDI-GIPipeline { $script:GIAppVol = $null }
    }

    It 'passes AgentOnline and Attached when the machine and package are present' {
        $r = Test-GIPoolHealth -Config $cfg -Run $run -PoolName 'TST-W11' -IncludeAppVolumes
        ($r | Where-Object name -eq 'AgentOnline').passed | Should -BeTrue
        ($r | Where-Object name -eq 'Attached:Notepad++').passed | Should -BeTrue
    }

    It 'fails AgentOnline when the machine is not in online entities' {
        Set-ModVar OnlineResp ('{"online":{"records":[{"computer_name":"OTHER-PC"}]}}' | ConvertFrom-Json)
        $r = Test-GIPoolHealth -Config $cfg -Run $run -PoolName 'TST-W11' -IncludeAppVolumes
        ($r | Where-Object name -eq 'AgentOnline').passed | Should -BeFalse
    }

    It 'fails Attached when the package is missing from the machine record' {
        Set-ModVar AttachResp ('{"data":[{"computer":"TST-W11-1","package":"Chrome"}]}' | ConvertFrom-Json)
        $r = Test-GIPoolHealth -Config $cfg -Run $run -PoolName 'TST-W11' -IncludeAppVolumes
        ($r | Where-Object name -eq 'Attached:Notepad++').passed | Should -BeFalse
    }

    It 'yields a failed AppVolumes/Api check when the API throws' {
        Set-ModVar AvThrow $true
        $r = Test-GIPoolHealth -Config $cfg -Run $run -PoolName 'TST-W11' -IncludeAppVolumes
        $c = $r | Where-Object { $_.category -eq 'AppVolumes' -and $_.name -eq 'Api' }
        $c.passed | Should -BeFalse
        $c.detail | Should -Match 'unreachable'
    }

    It 'does not match TST-W11-1 against TST-W11-10' {
        Set-ModVar OnlineResp ('{"online":{"records":[{"computer_name":"TST-W11-10"}]}}' | ConvertFrom-Json)
        Set-ModVar AttachResp ('{"data":[{"computer":"TST-W11-10","package":"Notepad++"}]}' | ConvertFrom-Json)
        $r = Test-GIPoolHealth -Config $cfg -Run $run -PoolName 'TST-W11' -IncludeAppVolumes
        ($r | Where-Object name -eq 'AgentOnline').passed | Should -BeFalse
        ($r | Where-Object name -eq 'Attached:Notepad++').passed | Should -BeFalse
    }
}

Describe 'Invoke-GIStageValidate' {
    BeforeEach {
        $run.snapshot = [pscustomobject]@{ id = 's'; name = 'GI-1'; manifest = [pscustomobject]@{ Horizon = '2512.0.0' } }
        Set-GIStage -Config $cfg -Run $run -Stage TestPush -Status Succeeded -Data @{ horizonSnapshotId = 'snap-1' }
    }

    It 'sets validation.passed true when every check passes' {
        Mock -ModuleName VDI-GIPipeline Test-GIPoolHealth {
            [pscustomobject]@{ category = 'Horizon'; name = 'PoolImage'; target = 'TST-W11'; passed = $true; detail = 'ok' }
        }
        $r = Invoke-GIStageValidate -Config $cfg -Run $run
        $r.Message | Should -Match 'All 1 checks passed'
        $run.validation.passed | Should -BeTrue
        Should -Invoke -ModuleName VDI-GIPipeline Test-GIPoolHealth -ParameterFilter { $ExpectedSnapshotId -eq 'snap-1' -and $Manifest.Horizon -eq '2512.0.0' }
    }

    It 'throws and persists failed checks when any check fails' {
        Mock -ModuleName VDI-GIPipeline Test-GIPoolHealth {
            [pscustomobject]@{ category = 'Horizon'; name = 'PoolImage'; target = 'TST-W11'; passed = $true; detail = 'ok' }
            [pscustomobject]@{ category = 'Guest'; name = 'Service:svservice'; target = 'TST-W11-1'; passed = $false; detail = 'Stopped' }
        }
        { Invoke-GIStageValidate -Config $cfg -Run $run } | Should -Throw '*1 of 2 checks failed*'
        $saved = Get-GIRun -Config $cfg -RunId $run.runId
        $saved.validation.passed | Should -BeFalse
        @($saved.validation.checks).Count | Should -Be 2
        @($saved.validation.checks | Where-Object { -not $_.passed }).name | Should -Be 'Service:svservice'
    }
}

Describe 'Invoke-GIStageSnapshot' {
    BeforeEach {
        Mock -ModuleName VDI-GIPipeline Get-VM { [pscustomobject]@{ Name = 'GI-VM'; Id = 'vm-1' } }
        Mock -ModuleName VDI-GIPipeline Invoke-GIGoldenConsolidation { [pscustomobject]@{ Needed = $false; Ok = $true; Message = 'No consolidation needed' } }
        Mock -ModuleName VDI-GIPipeline Get-GIGoldenSpace { [pscustomobject]@{ UsedGB = 100; Datastores = @([pscustomobject]@{ Name = 'ds1'; FreeGB = 50; CapacityGB = 1000; FreePercent = 5 }) } }
        Mock -ModuleName VDI-GIPipeline New-GIGoldenSnapshot { [pscustomobject]@{ id = 'b3'; name = 'Baseline 26.11.24.0131'; createdAt = (Get-Date).ToString('o') } }
        Mock -ModuleName VDI-GIPipeline Invoke-GISnapshotLifecycle {
            [pscustomobject]@{ Mode = 'ReportOnly'; ChainDepth = 4; Chain = 'Master > a > b'; Warnings = @()
                Plan = @([pscustomobject]@{ Name = 'Baseline 26.11.11.1340'; Action = 'Remove' }) }
        }
    }

    It 'only previews retention; nothing is removed before production' {
        $r = Invoke-GIStageSnapshot -Config $cfg -Run $run
        Should -Invoke -ModuleName VDI-GIPipeline Invoke-GISnapshotLifecycle -Times 1 -Exactly -ParameterFilter { $ReportOnly }
        $r.Message | Should -Match 'After production: 1 snapshot\(s\) to remove \(Baseline 26.11.11.1340\)'
    }

    It 'warns when datastore free space is below MinFreeSpacePercent' {
        $r = Invoke-GIStageSnapshot -Config $cfg -Run $run
        $r.Data.warnings -join ' ' | Should -Match 'ds1 has 5% free'
    }

    It 'refuses to stack a new snapshot when consolidation fails' {
        Mock -ModuleName VDI-GIPipeline Invoke-GIGoldenConsolidation { [pscustomobject]@{ Needed = $true; Ok = $false; Message = 'Disk consolidation failed: locked' } }
        { Invoke-GIStageSnapshot -Config $cfg -Run $run } | Should -Throw '*consolidation failed*'
        Should -Invoke -ModuleName VDI-GIPipeline New-GIGoldenSnapshot -Times 0 -Exactly
    }
}

Describe 'Sync-GIGuestInstallers' {
    BeforeEach {
        InModuleScope VDI-GIPipeline {
            function script:Copy-VMGuestFile { param($Source, $Destination, $VM, [switch] $LocalToGuest, $GuestCredential, [switch] $Force, $ErrorAction) }
        }
        $script:src = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $src | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'VMware-tools-12.5.0-x86_64.exe') -Value 'abc' -NoNewline
        Set-Content -LiteralPath (Join-Path $src 'Omnissa-Horizon-Agent-x86_64-2512.exe') -Value 'abcdef' -NoNewline
        $script:cred = [pscredential]::new('admin', (ConvertTo-SecureString 'x' -AsPlainText -Force))
        Set-ModVar GuestList '[{"n":"VMware-tools-12.5.0-x86_64.exe","l":3}]'
        Set-ModVar Scripts ([System.Collections.Generic.List[string]]::new())
        Mock -ModuleName VDI-GIPipeline Invoke-GIGuestScript {
            $global:GITestCtx.Scripts.Add($ScriptText)
            [pscustomobject]@{ ScriptOutput = $global:GITestCtx.GuestList; ExitCode = 0 }
        }
        Mock -ModuleName VDI-GIPipeline Copy-VMGuestFile { }
    }

    It 'copies only files the guest lacks or that differ in size' {
        $r = Sync-GIGuestInstallers -VM ([pscustomobject]@{ Name = 'GI' }) -Credential $cred -SourceDir $src -GuestDir 'C:\ProgramData\VDI\Install'
        $r.Copied | Should -Be @('Omnissa-Horizon-Agent-x86_64-2512.exe')
        $r.Skipped | Should -Be @('VMware-tools-12.5.0-x86_64.exe')
        Should -Invoke -ModuleName VDI-GIPipeline Copy-VMGuestFile -Times 1 -Exactly -ParameterFilter { $Source -like '*Horizon-Agent*' -and $Destination -eq 'C:\ProgramData\VDI\Install\' }
        $global:GITestCtx.Scripts[-1] | Should -Match 'LastWriteTimeUtc'
    }

    It 'copies everything into an empty guest folder' {
        Set-ModVar GuestList ''
        $r = Sync-GIGuestInstallers -VM ([pscustomobject]@{ Name = 'GI' }) -Credential $cred -SourceDir $src -GuestDir 'C:\ProgramData\VDI\Install'
        @($r.Copied).Count | Should -Be 2
        Should -Invoke -ModuleName VDI-GIPipeline Copy-VMGuestFile -Times 2 -Exactly
    }

    It 'throws when the host folder is missing' {
        { Sync-GIGuestInstallers -VM ([pscustomobject]@{ Name = 'GI' }) -Credential $cred -SourceDir (Join-Path $TestDrive 'nope') -GuestDir 'C:\x' } | Should -Throw '*not found*'
    }
}
}
