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

    It 'fails before touching Horizon when a ticked installer is missing on the host' {
        Mock -ModuleName VDI-GIPipeline Get-VM { [pscustomobject]@{ Name = 'GI-VM'; PowerState = 'PoweredOff' } }
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'VMware-tools-12.5.0-x86_64.exe') -Value 'x'
        $cfg.GoldenImage.InstallerSourceDir = $dir
        $cfg.GoldenImage.Actions = @('VmTools', 'Horizon', 'MsTeams')
        { Invoke-GIStagePreflight -Config $cfg -Run $run } | Should -Throw '*Horizon Agent (`*Horizon-Agent-x86_64-`*.exe)*'
        Should -Invoke -ModuleName VDI-GIPipeline Get-GIHorizonBaseImage -Times 0 -Exactly
    }

    It 'passes when every ticked installer is present or auto-downloads' {
        Mock -ModuleName VDI-GIPipeline Get-VM { [pscustomobject]@{ Name = 'GI-VM'; PowerState = 'PoweredOff' } }
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'VMware-tools-12.5.0-x86_64.exe') -Value 'x'
        $cfg.GoldenImage.InstallerSourceDir = $dir
        $cfg.GoldenImage.Actions = @('VmTools', 'MsTeams')
        { Invoke-GIStagePreflight -Config $cfg -Run $run } | Should -Not -Throw
    }

    It 'skips the installer check when no host folder is set' {
        Mock -ModuleName VDI-GIPipeline Get-VM { [pscustomobject]@{ Name = 'GI-VM'; PowerState = 'PoweredOff' } }
        $cfg.GoldenImage.Actions = @('Horizon')
        { Invoke-GIStagePreflight -Config $cfg -Run $run } | Should -Not -Throw
    }
}

Describe 'Get-GIInstallerStatus' {
    BeforeEach {
        $script:dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $old = Join-Path $dir 'VMware-tools-12.4.0-x86_64.exe'; Set-Content -LiteralPath $old -Value 'old'
        (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddDays(-30)
        Set-Content -LiteralPath (Join-Path $dir 'VMware-tools-12.5.0-x86_64.exe') -Value 'new'
        $cfg.GoldenImage.InstallerSourceDir = $dir
        $cfg.GoldenImage.Actions = @('VmTools', 'Horizon', 'FSLogix')
    }

    It 'lists every known package in run order' {
        (Get-GIInstallerStatus -Config $cfg).Packages.Action | Should -Be @('VmTools', 'Horizon', 'DEM', 'AppVolumes', 'HorizonRec', 'FSLogix', 'MsTeams', 'OneDrive', 'GoogleDrive')
    }

    It 'picks the newest matching file and marks Found, Missing and Download' {
        $p = (Get-GIInstallerStatus -Config $cfg).Packages
        $tools = $p | Where-Object Action -eq 'VmTools'
        $tools.State | Should -Be 'Found'
        $tools.File | Should -Be 'VMware-tools-12.5.0-x86_64.exe'
        $tools.Selected | Should -BeTrue
        ($p | Where-Object Action -eq 'Horizon').State | Should -Be 'Missing'
        ($p | Where-Object Action -eq 'FSLogix').State | Should -Be 'Download'
        ($p | Where-Object Action -eq 'DEM').Selected | Should -BeFalse
    }

    It 'reports NoFolder when no host folder is set' {
        $cfg.GoldenImage.InstallerSourceDir = ''
        $r = Get-GIInstallerStatus -Config $cfg
        $r.Folder | Should -Be ''
        @($r.Packages | Where-Object State -ne 'NoFolder') | Should -BeNullOrEmpty
    }

    It 'reports a missing folder without throwing' {
        $cfg.GoldenImage.InstallerSourceDir = Join-Path $TestDrive 'nope'
        (Get-GIInstallerStatus -Config $cfg).FolderError | Should -BeLike '*not found*'
    }

    It 'resolves a relative folder from the Pipeline root' {
        $cfg.GoldenImage.InstallerSourceDir = 'installers'
        (Get-GIInstallerStatus -Config $cfg).Folder | Should -Be (Join-Path $cfg.Root 'installers')
    }

    It 'uses the same file masks as VDI-GoldenImage.ps1' {
        $guest = Get-Content -Raw (Join-Path $PSScriptRoot '..' '..' 'VDI-GoldenImage.ps1')
        $masks = InModuleScope VDI-GIPipeline { $h = @{}; foreach ($k in $script:GIGuestPackages.Keys) { $h[$k] = $script:GIGuestPackages[$k].Mask }; $h }
        foreach ($k in $masks.Keys) {
            $m = [regex]::Match($guest, '(?m)^\s*' + $k + '\s*=\s*@\{.*?SrcFile\s*=\s*"([^"]+)"')
            $m.Success | Should -BeTrue -Because "SwSet.$k should exist in VDI-GoldenImage.ps1"
            $m.Groups[1].Value | Should -Be $masks[$k] -Because "mask for $k"
        }
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

Describe 'Invoke-GIStageMaintain' {
    BeforeEach {
        InModuleScope VDI-GIPipeline {
            function script:Get-Snapshot { param($VM, $Name, $ErrorAction) }
            function script:New-Snapshot { param($VM, $Name, $Description, [switch] $Memory, [switch] $Confirm, $ErrorAction) }
            function script:Start-VM { param($VM, [switch] $Confirm, $ErrorAction) }
            function script:Stop-VMGuest { param($VM, [switch] $Confirm, $ErrorAction) }
            function script:Get-VIEvent { param($Entity, $Start, $MaxSamples, $ErrorAction) }
            function script:Set-VM { param($VM, $Snapshot, [switch] $Confirm, $ErrorAction) }
            function script:Remove-Snapshot { param($Snapshot, [switch] $Confirm, $ErrorAction) }
        }
        function script:New-PSnap($Id, $Name, $Parent = $null, [switch] $Current, $MinutesAgo = 60) {
            [pscustomobject]@{ Id = $Id; Name = $Name; Created = (Get-Date).AddMinutes(-$MinutesAgo); ParentSnapshotId = $Parent; IsCurrent = [bool]$Current }
        }
        $cfg.GoldenImage = @{ VmName = 'GI-VM'; GuestCredentialSecret = 'GI-GuestAdmin'; ScriptPathInGuest = 'C:\ProgramData\VDI\VDI-GoldenImage.ps1'
            CopyScript = $false; Actions = @('VmTools', 'Horizon'); FinalizeAction = 'Finalize'; WindowsUpdate = @{ Enabled = $true } }
        Set-ModVar Calls ([System.Collections.Generic.List[string]]::new())
        Set-ModVar FailAction $null
        Set-ModVar Events @()
        Set-ModVar Snaps @()
        Set-ModVar Usage @{ Current = @(); Pending = @(); Unresolved = @() }
        Set-ModVar Reverted ([System.Collections.Generic.List[string]]::new())
        Set-ModVar Removed ([System.Collections.Generic.List[string]]::new())
        $cred = [pscredential]::new('admin', (ConvertTo-SecureString 'x' -AsPlainText -Force))
        Set-ModVar Cred $cred
        Mock -ModuleName VDI-GIPipeline Get-GISecretCredential { $global:GITestCtx.Cred }
        Mock -ModuleName VDI-GIPipeline Get-VM { [pscustomobject]@{ Name = 'GI-VM'; Id = 'vm-1'; PowerState = 'PoweredOff' } }
        Mock -ModuleName VDI-GIPipeline Start-VM { [pscustomobject]@{ Name = 'GI-VM'; Id = 'vm-1'; PowerState = 'PoweredOn' } }
        Mock -ModuleName VDI-GIPipeline Get-Snapshot { $global:GITestCtx.Snaps }
        Mock -ModuleName VDI-GIPipeline Set-VM { $global:GITestCtx.Reverted.Add([string]$Snapshot.Id) }
        Mock -ModuleName VDI-GIPipeline Remove-Snapshot { $global:GITestCtx.Removed.Add([string]$Snapshot.Id) }
        Mock -ModuleName VDI-GIPipeline Get-GISnapshotUsage { $global:GITestCtx.Usage }
        Mock -ModuleName VDI-GIPipeline Invoke-GIGoldenConsolidation { [pscustomobject]@{ Needed = $true; Ok = $true; Message = 'Disks consolidated' } }
        Mock -ModuleName VDI-GIPipeline New-Snapshot { [pscustomobject]@{ Id = 'snap-safe'; Name = $Name } }
        Mock -ModuleName VDI-GIPipeline Wait-GIGuestReady { }
        Mock -ModuleName VDI-GIPipeline Restart-GIGuest { $global:GITestCtx.Calls.Add('Reboot') }
        Mock -ModuleName VDI-GIPipeline Stop-VMGuest { }
        Mock -ModuleName VDI-GIPipeline Get-VIEvent { $global:GITestCtx.Events | Where-Object { $_.CreatedTime -ge $Start } }
        Mock -ModuleName VDI-GIPipeline Invoke-GIGuestWindowsUpdate { $global:GITestCtx.Calls.Add('WU'); @{ Passes = @([pscustomobject]@{ pass = 1; installed = 3 }); Warning = '' } }
        Mock -ModuleName VDI-GIPipeline Invoke-GIGuestAction {
            $global:GITestCtx.Calls.Add($Action)
            if ($Action -eq $global:GITestCtx.FailAction) { throw "In-guest action '$Action' exited 1: installer exited with code 1603" }
            if ($Action -eq 'Exit') { return [pscustomobject]@{ versions = [pscustomobject]@{ VmTools = '12.5.0'; Horizon = '2512.0.0' } } }
            [pscustomobject]@{ versions = [pscustomobject]@{ $Action = '1.0' } }
        }
        function script:Steps { @(Get-GIStepList -Run $run) }
        function script:StepStatus($Id) { (Steps | Where-Object id -eq $Id).status }
    }

    It 'runs every step in order on a fresh run and records them' {
        $r = Invoke-GIStageMaintain -Config $cfg -Run $run
        @($global:GITestCtx.Calls) | Should -Be @('Update', 'WU', 'VmTools', 'Horizon', 'Reboot', 'Exit', 'Finalize')
        (Steps).id | Should -Be @('RevertFailedRun', 'SafetySnapshot', 'RemoveFailedRunSnapshots', 'PowerOn', 'CopyScript', 'CopyInstallers', 'EnableUpdates', 'WindowsUpdate', 'Pkg:VmTools', 'Pkg:Horizon', 'Reboot', 'Manifest', 'Finalize', 'PowerOff')
        @(Steps | Where-Object { $_.status -notin 'Succeeded', 'Skipped' }) | Should -BeNullOrEmpty
        StepStatus 'CopyScript' | Should -Be 'Skipped'
        (Steps | Where-Object id -eq 'Pkg:Horizon').message | Should -Be 'Installed version 1.0'
        (Steps | Where-Object id -eq 'WindowsUpdate').message | Should -BeLike '1 pass(es), 3 update(s) installed*'
        $r.Data.actions | Should -Be @('VmTools', 'Horizon')
        $r.Data.manifest.Horizon | Should -Be '2512.0.0'
        $run.safetySnapshot.name | Should -Be "pre-maint-$($run.runId)"
    }

    It 'marks only the failing package step Failed and stops there' {
        Set-ModVar FailAction 'Horizon'
        { Invoke-GIStageMaintain -Config $cfg -Run $run } | Should -Throw '*1603*'
        StepStatus 'Pkg:VmTools' | Should -Be 'Succeeded'
        StepStatus 'Pkg:Horizon' | Should -Be 'Failed'
        (Steps | Where-Object id -eq 'Pkg:Horizon').message | Should -BeLike '*1603*'
        StepStatus 'Reboot' | Should -Be 'Pending'
        $global:GITestCtx.Calls | Should -Not -Contain 'Finalize'
    }

    It 'resumes at the failed package, skipping finished updates and packages' {
        Set-ModVar FailAction 'Horizon'
        { Invoke-GIStageMaintain -Config $cfg -Run $run } | Should -Throw
        Set-ModVar FailAction $null
        Set-ModVar Snaps @(New-PSnap 'snap-safe' "pre-maint-$($run.runId)")
        $global:GITestCtx.Calls.Clear()
        $null = Invoke-GIStageMaintain -Config $cfg -Run $run
        @($global:GITestCtx.Calls) | Should -Be @('Horizon', 'Reboot', 'Exit', 'Finalize')
        Should -Invoke -ModuleName VDI-GIPipeline New-Snapshot -Times 1 -Exactly
        Should -Invoke -ModuleName VDI-GIPipeline Start-VM -Times 2 -Exactly
        (Steps | Where-Object id -eq 'WindowsUpdate').message | Should -BeLike '*(earlier attempt)'
    }

    It 'resumes from a chosen step' {
        Set-ModVar FailAction 'Horizon'
        { Invoke-GIStageMaintain -Config $cfg -Run $run } | Should -Throw
        Set-ModVar FailAction $null
        Set-ModVar Snaps @(New-PSnap 'snap-safe' "pre-maint-$($run.runId)")
        $global:GITestCtx.Calls.Clear()
        $null = Invoke-GIStageMaintain -Config $cfg -Run $run -FromStep 'Pkg:VmTools'
        @($global:GITestCtx.Calls) | Should -Be @('VmTools', 'Horizon', 'Reboot', 'Exit', 'Finalize')
    }

    It 'restarts from the beginning after a snapshot revert and reuses the reverted-to safety snapshot' {
        Set-ModVar FailAction 'Horizon'
        { Invoke-GIStageMaintain -Config $cfg -Run $run } | Should -Throw
        Set-ModVar FailAction $null
        Set-ModVar Snaps @(New-PSnap 'snap-safe' "pre-maint-$($run.runId)" -Current)
        Set-ModVar Events @([pscustomobject]@{ CreatedTime = (Get-Date); UserName = 'DOM\admin'; Info = [pscustomobject]@{ DescriptionId = 'VirtualMachine.revertToSnapshot' } })
        $global:GITestCtx.Calls.Clear()
        $null = Invoke-GIStageMaintain -Config $cfg -Run $run
        @($global:GITestCtx.Calls) | Should -Be @('Update', 'WU', 'VmTools', 'Horizon', 'Reboot', 'Exit', 'Finalize')
        Should -Invoke -ModuleName VDI-GIPipeline New-Snapshot -Times 1 -Exactly
        Should -Invoke -ModuleName VDI-GIPipeline Write-GILog -ParameterFilter { $Message -like '*reverted*restarting Maintain*' }
    }

    It 'takes a new safety snapshot when the VM was reverted to a different snapshot' {
        Set-ModVar FailAction 'Horizon'
        { Invoke-GIStageMaintain -Config $cfg -Run $run } | Should -Throw
        Set-ModVar FailAction $null
        Set-ModVar Snaps @(New-PSnap 'snap-safe' "pre-maint-$($run.runId)")
        Set-ModVar Events @([pscustomobject]@{ CreatedTime = (Get-Date); UserName = 'DOM\admin'; Info = [pscustomobject]@{ DescriptionId = 'VirtualMachine.revertToSnapshot' } })
        $null = Invoke-GIStageMaintain -Config $cfg -Run $run
        Should -Invoke -ModuleName VDI-GIPipeline New-Snapshot -Times 2 -Exactly
        Should -Invoke -ModuleName VDI-GIPipeline New-Snapshot -Times 1 -Exactly -ParameterFilter { $Name -match "^pre-maint-$($run.runId)-\d{6}$" }
    }

    It 'restarts from the beginning when vCenter events cannot be read' {
        Set-ModVar FailAction 'Horizon'
        { Invoke-GIStageMaintain -Config $cfg -Run $run } | Should -Throw
        Set-ModVar FailAction $null
        Mock -ModuleName VDI-GIPipeline Get-VIEvent { throw 'no permission' }
        $global:GITestCtx.Calls.Clear()
        $null = Invoke-GIStageMaintain -Config $cfg -Run $run
        $global:GITestCtx.Calls | Should -Contain 'WU'
        $global:GITestCtx.Calls | Should -Contain 'VmTools'
    }

    It 'reverts to a failed run''s outer safety snapshot, then removes the leftovers after its own snapshot' {
        $failed = New-GIRun -Config $cfg -RunId '20261124-143957'; $failed.status = 'Failed'; Save-GIRun -Config $cfg -Run $failed
        Set-ModVar Snaps @(
            (New-PSnap 'b' 'Baseline 26.11.20.1249' -MinutesAgo 600)
            (New-PSnap 'p1' 'pre-maint-20261124-143957' 'b' -MinutesAgo 300)
            (New-PSnap 'p2' 'pre-maint-20261124-143957' 'p1' -Current -MinutesAgo 200)
        )
        $null = Invoke-GIStageMaintain -Config $cfg -Run $run
        @($global:GITestCtx.Reverted) | Should -Be @('p1')
        @($global:GITestCtx.Removed) | Should -Be @('p1', 'p2')
        (Steps | Where-Object id -eq 'RevertFailedRun').message | Should -Be 'Reverted to pre-maint-20261124-143957 (run 20261124-143957 is Failed)'
        (Steps | Where-Object id -eq 'RemoveFailedRunSnapshots').message | Should -Be 'Removed 2: pre-maint-20261124-143957, pre-maint-20261124-143957'
        Should -Invoke -ModuleName VDI-GIPipeline New-Snapshot -Times 1 -Exactly
    }

    It 'leaves snapshots of a run that is still awaiting approval' {
        $other = New-GIRun -Config $cfg -RunId '20261124-143957'; $other.status = 'AwaitingApproval'; Save-GIRun -Config $cfg -Run $other
        Set-ModVar Snaps @((New-PSnap 'p1' 'pre-maint-20261124-143957' -Current))
        $null = Invoke-GIStageMaintain -Config $cfg -Run $run
        @($global:GITestCtx.Reverted) | Should -BeNullOrEmpty
        @($global:GITestCtx.Removed) | Should -BeNullOrEmpty
        (Steps | Where-Object id -eq 'RemoveFailedRunSnapshots').message | Should -Be 'No failed-run safety snapshots'
    }

    It 'only reports when Snapshots.CleanupFailedRuns is off' {
        $cfg.Snapshots = @{ CleanupFailedRuns = $false }
        Set-ModVar Snaps @((New-PSnap 'p1' 'pre-maint-20261101-010101' -Current))
        $null = Invoke-GIStageMaintain -Config $cfg -Run $run
        @($global:GITestCtx.Reverted) | Should -BeNullOrEmpty
        @($global:GITestCtx.Removed) | Should -BeNullOrEmpty
        (Steps | Where-Object id -eq 'RevertFailedRun').message | Should -BeLike 'Would revert to pre-maint-20261101-010101*'
        (Steps | Where-Object id -eq 'RemoveFailedRunSnapshots').message | Should -BeLike 'Would remove 1:*'
    }

    It 'removes nothing while a push is pending' {
        Set-ModVar Usage @{ Current = @(); Pending = @('Baseline 26.11.25.0100'); Unresolved = @() }
        Set-ModVar Snaps @((New-PSnap 'b' 'Baseline 26.11.20.1249' -Current), (New-PSnap 'p1' 'pre-maint-20261101-010101' 'b'))
        $null = Invoke-GIStageMaintain -Config $cfg -Run $run
        @($global:GITestCtx.Removed) | Should -BeNullOrEmpty
        (Steps | Where-Object id -eq 'RemoveFailedRunSnapshots').message | Should -BeLike 'Nothing removed: a push is pending*'
    }

    It 'does not treat its own revert as a user revert when resuming' {
        Set-ModVar Snaps @((New-PSnap 'b' 'Baseline' -MinutesAgo 600), (New-PSnap 'p1' 'pre-maint-20261101-010101' 'b' -Current))
        # vCenter's clock: the event lands a few seconds after the step times recorded on this host
        Set-ModVar Events @([pscustomobject]@{ CreatedTime = (Get-Date).AddSeconds(5); UserName = 'svc'; Info = [pscustomobject]@{ DescriptionId = 'VirtualMachine.revertToSnapshot' } })
        Set-ModVar FailAction 'Horizon'
        { Invoke-GIStageMaintain -Config $cfg -Run $run } | Should -Throw
        Set-ModVar FailAction $null
        $global:GITestCtx.Calls.Clear()
        $null = Invoke-GIStageMaintain -Config $cfg -Run $run
        @($global:GITestCtx.Calls) | Should -Be @('Horizon', 'Reboot', 'Exit', 'Finalize')
        @($global:GITestCtx.Reverted).Count | Should -Be 1
    }

    It 'passes the package timeout to the guest action' {
        $cfg.GoldenImage.ActionTimeoutMin = 45
        $null = Invoke-GIStageMaintain -Config $cfg -Run $run
        Should -Invoke -ModuleName VDI-GIPipeline Invoke-GIGuestAction -ParameterFilter { $Action -eq 'Horizon' -and $TimeoutMin -eq 45 -and $OnWait }
        Should -Invoke -ModuleName VDI-GIPipeline Invoke-GIGuestAction -ParameterFilter { $Action -eq 'Finalize' -and -not $TimeoutMin }
    }
}

Describe 'Wait-GIGuestScriptAsync' {
    BeforeEach {
        InModuleScope VDI-GIPipeline {
            function script:Invoke-VMScript { param($VM, $GuestCredential, $ScriptType, $ScriptText, [switch] $RunAsync, $ErrorAction) }
            function script:Get-Task { param($Id, $ErrorAction) }
            function script:Wait-Task { param($Task, $ErrorAction) }
        }
        $cfg.GoldenImage = @{ ScriptPathInGuest = 'C:\ProgramData\VDI\VDI-GoldenImage.ps1' }
        $script:cred = [pscredential]::new('admin', (ConvertTo-SecureString 'x' -AsPlainText -Force))
        Set-ModVar TaskState 'Running'
        Set-ModVar Clock 0
        Set-ModVar Base (Get-Date '2026-11-25 10:00')
        Set-ModVar Kill $null
        Mock -ModuleName VDI-GIPipeline Invoke-VMScript { [pscustomobject]@{ Id = 'task-1' } }
        Mock -ModuleName VDI-GIPipeline Get-Task { [pscustomobject]@{ Id = 'task-1'; State = $global:GITestCtx.TaskState } }
        Mock -ModuleName VDI-GIPipeline Wait-Task { [pscustomobject]@{ ExitCode = 0; ScriptOutput = 'ok' } }
        Mock -ModuleName VDI-GIPipeline Invoke-GIGuestScript { $global:GITestCtx.Kill = $ScriptText; [pscustomobject]@{ ExitCode = 0; ScriptOutput = '' } }
        # Each Get-Date call moves the clock 90 minutes forward
        Mock -ModuleName VDI-GIPipeline Get-Date { $global:GITestCtx.Clock++; $global:GITestCtx.Base.AddMinutes(90 * ($global:GITestCtx.Clock - 1)) }
    }

    It 'returns the script result when the task succeeds' {
        Set-ModVar TaskState 'Success'
        $r = Wait-GIGuestScriptAsync -Config $cfg -VM ([pscustomobject]@{ Name = 'GI' }) -Credential $cred -ScriptText 'x' -Action 'Horizon' -TimeoutMin 60
        $r.ScriptOutput | Should -Be 'ok'
        $global:GITestCtx.Kill | Should -BeNullOrEmpty
    }

    It 'stops installers and throws after the timeout' {
        { Wait-GIGuestScriptAsync -Config $cfg -VM ([pscustomobject]@{ Name = 'GI' }) -Credential $cred -ScriptText 'x' -Action 'Horizon' -TimeoutMin 60 } |
            Should -Throw "*'Horizon' did not finish within 60 minutes*"
        $global:GITestCtx.Kill | Should -Match 'msiexec'
        $global:GITestCtx.Kill | Should -Match ([regex]::Escape('C:\ProgramData\VDI\Install\*'))
    }
}
}
