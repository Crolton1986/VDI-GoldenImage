BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'VDI-GIPipeline.psd1') -Force

    # Mock bodies run bound to the module, so test data is shared through one global hashtable
    $global:GIApprovalCtx = @{}
    function Set-Ctx { param([string] $Name, $Value) $global:GIApprovalCtx[$Name] = $Value }

    function New-TestPool {
        param($Id, $Name, $Snap = 'snap-old', $PendingSnap = $null, $PendingState = $null)
        [pscustomobject]@{
            id = $Id; name = $Name
            provisioning_settings = [pscustomobject]@{ parent_vm_id = 'vm-1'; base_snapshot_id = $Snap }
            provisioning_status_data = [pscustomobject]@{
                instant_clone_pending_image_snapshot_id = $PendingSnap
                instant_clone_pending_image_state       = $PendingState
            }
        }
    }
    function New-TestConfig {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $c = @{
            Root        = $root
            Paths       = @{ State = (Join-Path $root 'state'); Reports = (Join-Path $root 'reports'); Logs = (Join-Path $root 'logs') }
            vCenter     = @{ Server = 'vc'; CredentialSecret = 'GI-vCenter' }
            GoldenImage = @{ VmName = 'GI-VM' }
            Pools       = @{ Test = @{ Name = 'TST-W11' }; Production = @(@{ Name = 'PRD-A'; LogoffPolicy = 'WAIT_FOR_LOGOFF' }, @{ Name = 'PRD-B'; LogoffPolicy = 'FORCE_LOGOFF' }); PushTimeoutMin = 120 }
            Promotion   = @{ AutoPromote = $false; MaintenanceWindow = @{ Days = @('Saturday'); StartTime = '22:00' } }
        }
        New-Item -ItemType Directory -Path $c.Paths.State -Force | Out-Null
        $c
    }
    # A run that passed validation and is parked at the approval gate
    function New-AwaitingRun {
        param($Config)
        $r = New-GIRun -Config $Config -RunId '20261124-020202'
        $r.snapshot = [pscustomobject]@{ id = 'vsnap-1'; name = 'GI-20261124-020202'; manifest = [pscustomobject]@{} }
        $r.validation = [pscustomobject]@{ passed = $true; checks = @() }
        $r.status = 'AwaitingApproval'
        Save-GIRun -Config $Config -Run $r
        Get-GIRun -Config $Config -RunId $r.runId
    }
    # A run that was approved and promoted: status Scheduled, two prod pools scheduled
    function New-ScheduledRun {
        param($Config, [datetime] $Start)
        $r = New-AwaitingRun -Config $Config
        $r.approval = [pscustomobject]@{ decision = 'Approved'; by = 'tester'; at = (Get-Date).ToString('o'); startTime = $Start.ToString('o'); comment = '' }
        Set-GIStage -Config $Config -Run $r -Stage Promote -Status Succeeded -Data @{ horizonSnapshotId = 'snap-new' }
        $r.promotion = [pscustomobject]@{ pools = @(
                [pscustomobject]@{ poolName = 'PRD-A'; poolId = 'p-a'; scheduledStart = $Start.ToString('o'); status = 'Scheduled'; message = '' }
                [pscustomobject]@{ poolName = 'PRD-B'; poolId = 'p-b'; scheduledStart = $Start.ToString('o'); status = 'Scheduled'; message = '' }
            ) }
        $r.status = 'Scheduled'
        Save-GIRun -Config $Config -Run $r
        $r
    }
}

AfterAll { Remove-Variable -Name GIApprovalCtx -Scope Global -ErrorAction SilentlyContinue }

Describe 'Approval, promotion, post-check and rollback' {
    BeforeEach {
        $script:cfg = New-TestConfig
        Set-Ctx Pools @(
            (New-TestPool -Id 'p-a' -Name 'PRD-A')
            (New-TestPool -Id 'p-b' -Name 'PRD-B')
        )
        Set-Ctx Pushes @()
        Set-Ctx Stops @()
        Set-Ctx Calls @()
        Set-Ctx FailPushOn $null
        Mock -ModuleName VDI-GIPipeline Start-Sleep { }
        Mock -ModuleName VDI-GIPipeline Write-GILog { }
        Mock -ModuleName VDI-GIPipeline Save-GIReport { }
        Mock -ModuleName VDI-GIPipeline Send-GIReport { }
        Mock -ModuleName VDI-GIPipeline Connect-GIServices { }
        Mock -ModuleName VDI-GIPipeline Disconnect-GIServices { }
        Mock -ModuleName VDI-GIPipeline Invoke-GISnapshotLifecycle {
            [pscustomobject]@{ Mode = 'Prune'; Chain = 'Master > Baseline 26.11.20.1249 > GI-20261124-020202'; Removed = @('Baseline 26.11.11.1340')
                Plan = @(); Consolidation = @('Baseline 26.11.11.1340: Disks consolidated'); Warnings = @(); Errors = @()
                SpaceBefore = [pscustomobject]@{ UsedGB = 300; Datastores = @() }; SpaceAfter = [pscustomobject]@{ UsedGB = 240; Datastores = @() } }
        }
        Mock -ModuleName VDI-GIPipeline Get-GIHorizonPool { $global:GIApprovalCtx.Pools | Where-Object name -eq $Name | Select-Object -First 1 }
        Mock -ModuleName VDI-GIPipeline Get-GIHorizonBaseImage {
            [pscustomobject]@{ BaseVm = [pscustomobject]@{ id = 'bvm-1' }; Snapshot = [pscustomobject]@{ id = 'snap-new'; name = $SnapshotName } }
        }
        Mock -ModuleName VDI-GIPipeline Invoke-GIHorizonPushImage {
            $global:GIApprovalCtx.Calls += "push:$PoolId"
            if ($global:GIApprovalCtx.FailPushOn -eq $PoolId) { throw "push failed on $PoolId" }
            $global:GIApprovalCtx.Pushes += $PoolId
        }
        Mock -ModuleName VDI-GIPipeline Stop-GIHorizonPushImage {
            $global:GIApprovalCtx.Calls += "stop:$PoolId"
            $global:GIApprovalCtx.Stops += $PoolId
        }
    }

    Describe 'Enter-GIApprovalGate' {
        It 'parks the run at AwaitingApproval with the Approval stage Running' {
            $run = New-GIRun -Config $cfg -RunId '20261124-030303'
            $r = Enter-GIApprovalGate -Config $cfg -Run $run
            $saved = Get-GIRun -Config $cfg -RunId $run.runId
            $saved.status | Should -Be 'AwaitingApproval'
            $saved.stages.Approval.status | Should -Be 'Running'
            $r.status | Should -Be 'AwaitingApproval'
        }

        It 'calls Approve-GIRun with By AutoPromote when Promotion.AutoPromote is true' {
            Mock -ModuleName VDI-GIPipeline Approve-GIRun { 'approved-result' }
            $cfg.Promotion.AutoPromote = $true
            $run = New-GIRun -Config $cfg -RunId '20261124-030304'
            $r = Enter-GIApprovalGate -Config $cfg -Run $run
            $r | Should -Be 'approved-result'
            Should -Invoke -ModuleName VDI-GIPipeline Approve-GIRun -Times 1 -Exactly -ParameterFilter { $By -eq 'AutoPromote' -and $RunId -eq '20261124-030304' }
        }

        It 'does not call Approve-GIRun when AutoPromote is false' {
            Mock -ModuleName VDI-GIPipeline Approve-GIRun { }
            $run = New-GIRun -Config $cfg -RunId '20261124-030305'
            Enter-GIApprovalGate -Config $cfg -Run $run | Out-Null
            Should -Invoke -ModuleName VDI-GIPipeline Approve-GIRun -Times 0 -Exactly
        }
    }

    Describe 'Approve-GIRun' {
        It 'refuses when the run is not AwaitingApproval' {
            $run = New-AwaitingRun -Config $cfg
            $run.status = 'Running'; Save-GIRun -Config $cfg -Run $run
            { Approve-GIRun -Config $cfg -RunId $run.runId -By 'me' -StartTime (Get-Date).AddDays(1) } | Should -Throw '*not AwaitingApproval*'
        }

        It 'refuses when validation did not pass' {
            $run = New-AwaitingRun -Config $cfg
            $run.validation.passed = $false; Save-GIRun -Config $cfg -Run $run
            { Approve-GIRun -Config $cfg -RunId $run.runId -By 'me' -StartTime (Get-Date).AddDays(1) } | Should -Throw "*passing validation*"
            Should -Invoke -ModuleName VDI-GIPipeline Invoke-GIHorizonPushImage -Times 0 -Exactly
        }

        It 'refuses a start time in the past' {
            $run = New-AwaitingRun -Config $cfg
            { Approve-GIRun -Config $cfg -RunId $run.runId -By 'me' -StartTime (Get-Date).AddHours(-2) } | Should -Throw '*in the past*'
            (Get-GIRun -Config $cfg -RunId $run.runId).status | Should -Be 'AwaitingApproval'
        }

        It 'defaults StartTime to the next maintenance window' {
            $window = (Get-Date).AddDays(3).Date.AddHours(22)
            Set-Ctx Window $window
            Mock -ModuleName VDI-GIPipeline Get-GINextMaintenanceWindow { $global:GIApprovalCtx.Window }
            $run = New-AwaitingRun -Config $cfg
            Approve-GIRun -Config $cfg -RunId $run.runId -By 'me' | Out-Null
            Should -Invoke -ModuleName VDI-GIPipeline Get-GINextMaintenanceWindow -Times 1 -Exactly
            $saved = Get-GIRun -Config $cfg -RunId $run.runId
            ([datetime]$saved.approval.startTime) | Should -Be $window
        }

        It 'records the approval, promotes every production pool and schedules the run' {
            $start = (Get-Date).AddDays(2)
            $run = New-AwaitingRun -Config $cfg
            $r = Approve-GIRun -Config $cfg -RunId $run.runId -By 'alice' -Comment 'ship it' -StartTime $start
            $r.status | Should -Be 'Scheduled'

            $saved = Get-GIRun -Config $cfg -RunId $run.runId
            $saved.status | Should -Be 'Scheduled'
            $saved.approval.decision | Should -Be 'Approved'
            $saved.approval.by | Should -Be 'alice'
            $saved.approval.comment | Should -Be 'ship it'
            ([datetime]$saved.approval.startTime) | Should -Be ([datetime]$start.ToString('o'))
            $saved.stages.Approval.status | Should -Be 'Succeeded'
            $saved.stages.Promote.status | Should -Be 'Succeeded'
            $saved.stages.Promote.data.horizonSnapshotId | Should -Be 'snap-new'
            @($saved.promotion.pools).Count | Should -Be 2
            @($saved.promotion.pools).poolName | Should -Be @('PRD-A', 'PRD-B')
            foreach ($p in @($saved.promotion.pools)) {
                $p.status | Should -Be 'Scheduled'
                $p.scheduledStart | Should -Not -BeNullOrEmpty
            }
            Should -Invoke -ModuleName VDI-GIPipeline Invoke-GIHorizonPushImage -Times 1 -Exactly -ParameterFilter { $PoolId -eq 'p-a' -and $LogoffPolicy -eq 'WAIT_FOR_LOGOFF' }
            Should -Invoke -ModuleName VDI-GIPipeline Invoke-GIHorizonPushImage -Times 1 -Exactly -ParameterFilter { $PoolId -eq 'p-b' -and $LogoffPolicy -eq 'FORCE_LOGOFF' }
            Should -Invoke -ModuleName VDI-GIPipeline Connect-GIServices -Times 1 -Exactly
            Should -Invoke -ModuleName VDI-GIPipeline Disconnect-GIServices -Times 1 -Exactly
            Should -Invoke -ModuleName VDI-GIPipeline Send-GIReport -Times 1 -Exactly
        }

        It 'skips connecting with -NoConnect' {
            $run = New-AwaitingRun -Config $cfg
            Approve-GIRun -Config $cfg -RunId $run.runId -By 'me' -StartTime (Get-Date).AddDays(1) -NoConnect | Out-Null
            Should -Invoke -ModuleName VDI-GIPipeline Connect-GIServices -Times 0 -Exactly
            Should -Invoke -ModuleName VDI-GIPipeline Disconnect-GIServices -Times 0 -Exactly
        }

        It '-WhatIf changes nothing' {
            $run = New-AwaitingRun -Config $cfg
            Approve-GIRun -Config $cfg -RunId $run.runId -By 'me' -StartTime (Get-Date).AddDays(1) -WhatIf | Out-Null
            $saved = Get-GIRun -Config $cfg -RunId $run.runId
            $saved.status | Should -Be 'AwaitingApproval'
            $saved.approval.decision | Should -BeNullOrEmpty
            $saved.stages.Promote.status | Should -Be 'Pending'
            Should -Invoke -ModuleName VDI-GIPipeline Invoke-GIHorizonPushImage -Times 0 -Exactly
        }
    }

    Describe 'Invoke-GIStagePromote' {
        It 'cancels already-scheduled pools and rethrows when a later pool fails' {
            Set-Ctx FailPushOn 'p-b'
            $run = New-AwaitingRun -Config $cfg
            { Invoke-GIStagePromote -Config $cfg -Run $run -StartTime (Get-Date).AddDays(1) } | Should -Throw '*push failed on p-b*'

            Should -Invoke -ModuleName VDI-GIPipeline Stop-GIHorizonPushImage -Times 1 -Exactly -ParameterFilter { $PoolId -eq 'p-a' }
            $global:GIApprovalCtx.Stops | Should -Be @('p-a')
            $saved = Get-GIRun -Config $cfg -RunId $run.runId
            $first = @($saved.promotion.pools)[0]
            $first.poolName | Should -Be 'PRD-A'
            $first.status | Should -Be 'Cancelled'
        }

        # Regression: optional LogoffPolicy must not throw under StrictMode
        It 'defaults to WAIT_FOR_LOGOFF when a production pool has no LogoffPolicy' {
            $cfg.Pools.Production = @(@{ Name = 'PRD-A' })
            $run = New-AwaitingRun -Config $cfg
            Invoke-GIStagePromote -Config $cfg -Run $run -StartTime (Get-Date).AddDays(1) | Out-Null
            Should -Invoke -ModuleName VDI-GIPipeline Invoke-GIHorizonPushImage -Times 1 -Exactly -ParameterFilter { $LogoffPolicy -eq 'WAIT_FOR_LOGOFF' }
        }

        It 'throws when the run has no snapshot' {
            $run = New-GIRun -Config $cfg -RunId '20261124-040404'
            { Invoke-GIStagePromote -Config $cfg -Run $run -StartTime (Get-Date).AddDays(1) } | Should -Throw '*no snapshot*'
        }
    }

    Describe 'Deny-GIRun' {
        It 'rejects the run and skips Promote and PostCheck without failing it' {
            $run = New-AwaitingRun -Config $cfg
            $r = Deny-GIRun -Config $cfg -RunId $run.runId -By 'bob' -Comment 'not now'
            $r.status | Should -Be 'Rejected'
            $saved = Get-GIRun -Config $cfg -RunId $run.runId
            $saved.status | Should -Be 'Rejected'
            $saved.status | Should -Not -Be 'Failed'
            $saved.approval.decision | Should -Be 'Rejected'
            $saved.approval.by | Should -Be 'bob'
            $saved.approval.comment | Should -Be 'not now'
            $saved.stages.Promote.status | Should -Be 'Skipped'
            $saved.stages.PostCheck.status | Should -Be 'Skipped'
            $saved.stages.Approval.status | Should -Be 'Skipped'
            Should -Invoke -ModuleName VDI-GIPipeline Invoke-GIHorizonPushImage -Times 0 -Exactly
        }

        It 'refuses when the run is not AwaitingApproval' {
            $run = New-GIRun -Config $cfg -RunId '20261124-050505'
            { Deny-GIRun -Config $cfg -RunId $run.runId -By 'bob' } | Should -Throw '*not AwaitingApproval*'
        }
    }

    Describe 'Invoke-GIStagePostCheck' {
        BeforeEach {
            Mock -ModuleName VDI-GIPipeline Test-GIPoolHealth {
                [pscustomobject]@{ category = 'Horizon'; name = 'MachineState'; target = "$PoolName-1"; passed = $true; detail = 'AVAILABLE' }
            }
        }

        It 'returns $false and changes nothing before the start time' {
            $run = New-ScheduledRun -Config $cfg -Start (Get-Date).AddHours(2)
            Invoke-GIStagePostCheck -Config $cfg -Run $run | Should -BeFalse
            $saved = Get-GIRun -Config $cfg -RunId $run.runId
            $saved.status | Should -Be 'Scheduled'
            $saved.stages.PostCheck.status | Should -Be 'Pending'
            @($saved.promotion.pools).status | Should -Be @('Scheduled', 'Scheduled')
            Should -Invoke -ModuleName VDI-GIPipeline Get-GIHorizonPool -Times 0 -Exactly
        }

        It 'returns $false with the pool InProgress while a push is pending inside the timeout' {
            Set-Ctx Pools @(
                (New-TestPool -Id 'p-a' -Name 'PRD-A' -Snap 'snap-old' -PendingSnap 'snap-new' -PendingState 'IN_PROGRESS')
                (New-TestPool -Id 'p-b' -Name 'PRD-B' -Snap 'snap-new')
            )
            $run = New-ScheduledRun -Config $cfg -Start (Get-Date).AddMinutes(-10)
            Invoke-GIStagePostCheck -Config $cfg -Run $run | Should -BeFalse
            $saved = Get-GIRun -Config $cfg -RunId $run.runId
            $saved.status | Should -Be 'Scheduled'
            (@($saved.promotion.pools) | Where-Object poolName -eq 'PRD-A').status | Should -Be 'InProgress'
            (@($saved.promotion.pools) | Where-Object poolName -eq 'PRD-B').status | Should -Be 'Succeeded'
            $saved.stages.PostCheck.status | Should -Be 'Pending'
        }

        It 'completes, and writes lastKnownGood, when all pools are on the expected snapshot and healthy (unmocked Invoke-GIStage)' {
            Set-Ctx Pools @(
                (New-TestPool -Id 'p-a' -Name 'PRD-A' -Snap 'snap-new')
                (New-TestPool -Id 'p-b' -Name 'PRD-B' -Snap 'snap-new')
            )
            $run = New-ScheduledRun -Config $cfg -Start (Get-Date).AddHours(-1)
            Invoke-GIStagePostCheck -Config $cfg -Run $run | Should -BeTrue
            $saved = Get-GIRun -Config $cfg -RunId $run.runId
            $saved.status | Should -Be 'Completed'
            $saved.stages.PostCheck.status | Should -Be 'Succeeded'
            @($saved.promotion.pools).status | Should -Be @('Succeeded', 'Succeeded')
            @($saved.validation.checks).category | Should -Be @('Prod-Horizon', 'Prod-Horizon')

            $lkgPath = Join-Path $cfg.Paths.State 'lastKnownGood.json'
            Test-Path $lkgPath | Should -BeTrue
            $lkg = Get-Content $lkgPath -Raw | ConvertFrom-Json
            $lkg.snapshotName | Should -Be 'GI-20261124-020202'
            $lkg.runId | Should -Be $run.runId

            # Retention runs once production passed, as a finished run, and is recorded on the run
            Should -Invoke -ModuleName VDI-GIPipeline Invoke-GISnapshotLifecycle -Times 1 -Exactly -ParameterFilter { $RunFinished -and -not $ReportOnly }
            $saved.retention.removed | Should -Be @('Baseline 26.11.11.1340')
            $saved.retention.freedGb | Should -Be 60
            $saved.retention.chain | Should -Be 'Master > Baseline 26.11.20.1249 > GI-20261124-020202'
        }

        It 'stays Completed when snapshot retention throws' {
            Mock -ModuleName VDI-GIPipeline Invoke-GISnapshotLifecycle { throw 'vCenter gone' }
            Set-Ctx Pools @(
                (New-TestPool -Id 'p-a' -Name 'PRD-A' -Snap 'snap-new')
                (New-TestPool -Id 'p-b' -Name 'PRD-B' -Snap 'snap-new')
            )
            $run = New-ScheduledRun -Config $cfg -Start (Get-Date).AddHours(-1)
            Invoke-GIStagePostCheck -Config $cfg -Run $run | Should -BeTrue
            $saved = Get-GIRun -Config $cfg -RunId $run.runId
            $saved.status | Should -Be 'Completed'
            $saved.retention.errors[0] | Should -Match 'vCenter gone'
        }

        It 'completes, and writes lastKnownGood, when all pools are on the expected snapshot and healthy' {
            # Stand-in for Invoke-GIStage that tolerates a Message-only result
            Mock -ModuleName VDI-GIPipeline Invoke-GIStage {
                Set-GIStage -Config $Config -Run $Run -Stage $Stage -Status Running -Message ''
                try { $out = & $Action } catch { Set-GIStage -Config $Config -Run $Run -Stage $Stage -Status Failed -Message "$Stage failed: $($_.Exception.Message)"; throw }
                Set-GIStage -Config $Config -Run $Run -Stage $Stage -Status Succeeded -Message ([string]$out.Message)
            }
            Set-Ctx Pools @(
                (New-TestPool -Id 'p-a' -Name 'PRD-A' -Snap 'snap-new')
                (New-TestPool -Id 'p-b' -Name 'PRD-B' -Snap 'snap-new')
            )
            $run = New-ScheduledRun -Config $cfg -Start (Get-Date).AddHours(-1)
            Invoke-GIStagePostCheck -Config $cfg -Run $run | Should -BeTrue
            $saved = Get-GIRun -Config $cfg -RunId $run.runId
            $saved.status | Should -Be 'Completed'
            $saved.stages.PostCheck.status | Should -Be 'Succeeded'
            @($saved.promotion.pools).status | Should -Be @('Succeeded', 'Succeeded')
            @($saved.validation.checks).category | Should -Be @('Prod-Horizon', 'Prod-Horizon')

            $lkgPath = Join-Path $cfg.Paths.State 'lastKnownGood.json'
            Test-Path $lkgPath | Should -BeTrue
            $lkg = Get-Content $lkgPath -Raw | ConvertFrom-Json
            $lkg.snapshotName | Should -Be 'GI-20261124-020202'
            $lkg.runId | Should -Be $run.runId
        }

        It 'fails PostCheck, fails the run and writes no lastKnownGood when a pool is on the wrong snapshot' {
            Set-Ctx Pools @(
                (New-TestPool -Id 'p-a' -Name 'PRD-A' -Snap 'snap-new')
                (New-TestPool -Id 'p-b' -Name 'PRD-B' -Snap 'snap-WRONG')
            )
            $run = New-ScheduledRun -Config $cfg -Start (Get-Date).AddHours(-1)
            { Invoke-GIStagePostCheck -Config $cfg -Run $run } | Should -Throw '*PRD-B*'
            $saved = Get-GIRun -Config $cfg -RunId $run.runId
            $saved.stages.PostCheck.status | Should -Be 'Failed'
            $saved.status | Should -Be 'Failed'
            $saved.error | Should -Match 'PostCheck'
            Test-Path (Join-Path $cfg.Paths.State 'lastKnownGood.json') | Should -BeFalse
            Should -Invoke -ModuleName VDI-GIPipeline Invoke-GISnapshotLifecycle -Times 0 -Exactly
            Should -Invoke -ModuleName VDI-GIPipeline Send-GIReport -Times 1 -Exactly
        }

        It 'fails when a push is still pending after the timeout' {
            Set-Ctx Pools @(
                (New-TestPool -Id 'p-a' -Name 'PRD-A' -Snap 'snap-old' -PendingSnap 'snap-new' -PendingState 'IN_PROGRESS')
                (New-TestPool -Id 'p-b' -Name 'PRD-B' -Snap 'snap-new')
            )
            $run = New-ScheduledRun -Config $cfg -Start (Get-Date).AddHours(-5)
            { Invoke-GIStagePostCheck -Config $cfg -Run $run } | Should -Throw '*PRD-A*'
            (Get-GIRun -Config $cfg -RunId $run.runId).status | Should -Be 'Failed'
        }

        It 'fails the stage when a production health check fails' {
            Set-Ctx Pools @(
                (New-TestPool -Id 'p-a' -Name 'PRD-A' -Snap 'snap-new')
                (New-TestPool -Id 'p-b' -Name 'PRD-B' -Snap 'snap-new')
            )
            Mock -ModuleName VDI-GIPipeline Test-GIPoolHealth {
                [pscustomobject]@{ category = 'Horizon'; name = 'MachineState'; target = "$PoolName-1"; passed = $false; detail = 'ERROR' }
            }
            $run = New-ScheduledRun -Config $cfg -Start (Get-Date).AddHours(-1)
            { Invoke-GIStagePostCheck -Config $cfg -Run $run } | Should -Throw '*production check(s) failed*'
            Test-Path (Join-Path $cfg.Paths.State 'lastKnownGood.json') | Should -BeFalse
        }
    }

    Describe 'Invoke-GIRollback' {
        It 'throws without lastKnownGood and without -SnapshotName' {
            { Invoke-GIRollback -Config $cfg -PoolName 'PRD-A' } | Should -Throw '*No last-known-good*'
            Should -Invoke -ModuleName VDI-GIPipeline Invoke-GIHorizonPushImage -Times 0 -Exactly
        }

        It 'uses the last-known-good snapshot name' {
            $good = New-AwaitingRun -Config $cfg
            Set-GILastKnownGood -Config $cfg -Run $good
            $r = Invoke-GIRollback -Config $cfg -PoolName 'PRD-A'
            $r.SnapshotName | Should -Be 'GI-20261124-020202'
            Should -Invoke -ModuleName VDI-GIPipeline Get-GIHorizonBaseImage -Times 1 -Exactly -ParameterFilter { $SnapshotName -eq 'GI-20261124-020202' }
            Should -Invoke -ModuleName VDI-GIPipeline Invoke-GIHorizonPushImage -Times 1 -Exactly -ParameterFilter { $PoolId -eq 'p-a' -and $SnapshotId -eq 'snap-new' -and $ParentVmId -eq 'bvm-1' }
        }

        It 'prefers an explicit -SnapshotName over lastKnownGood' {
            $good = New-AwaitingRun -Config $cfg
            Set-GILastKnownGood -Config $cfg -Run $good
            $r = Invoke-GIRollback -Config $cfg -PoolName 'PRD-A' -SnapshotName 'GI-explicit'
            $r.SnapshotName | Should -Be 'GI-explicit'
            Should -Invoke -ModuleName VDI-GIPipeline Get-GIHorizonBaseImage -Times 1 -Exactly -ParameterFilter { $SnapshotName -eq 'GI-explicit' }
        }

        It 'cancels a pending push before pushing the rollback image' {
            Set-Ctx Pools @((New-TestPool -Id 'p-a' -Name 'PRD-A' -Snap 'snap-bad' -PendingSnap 'snap-pending' -PendingState 'IN_PROGRESS'))
            Invoke-GIRollback -Config $cfg -PoolName 'PRD-A' -SnapshotName 'GI-x' | Out-Null
            $global:GIApprovalCtx.Calls | Should -Be @('stop:p-a', 'push:p-a')
        }

        It 'does not cancel anything when no push is pending' {
            Invoke-GIRollback -Config $cfg -PoolName 'PRD-A' -SnapshotName 'GI-x' | Out-Null
            Should -Invoke -ModuleName VDI-GIPipeline Stop-GIHorizonPushImage -Times 0 -Exactly
        }

        It 'uses WAIT_FOR_LOGOFF by default and FORCE_LOGOFF with -ForceLogoff' {
            $a = Invoke-GIRollback -Config $cfg -PoolName 'PRD-A' -SnapshotName 'GI-x'
            $a.LogoffPolicy | Should -Be 'WAIT_FOR_LOGOFF'
            Should -Invoke -ModuleName VDI-GIPipeline Invoke-GIHorizonPushImage -Times 1 -Exactly -ParameterFilter { $LogoffPolicy -eq 'WAIT_FOR_LOGOFF' }
            $b = Invoke-GIRollback -Config $cfg -PoolName 'PRD-A' -SnapshotName 'GI-x' -ForceLogoff
            $b.LogoffPolicy | Should -Be 'FORCE_LOGOFF'
            Should -Invoke -ModuleName VDI-GIPipeline Invoke-GIHorizonPushImage -Times 1 -Exactly -ParameterFilter { $LogoffPolicy -eq 'FORCE_LOGOFF' }
        }

        It 'marks the run RolledBack when -RunId is given' {
            $run = New-ScheduledRun -Config $cfg -Start (Get-Date).AddHours(-1)
            Invoke-GIRollback -Config $cfg -PoolName 'PRD-A' -SnapshotName 'GI-x' -RunId $run.runId | Out-Null
            $saved = Get-GIRun -Config $cfg -RunId $run.runId
            $saved.status | Should -Be 'RolledBack'
            $saved.progress | Should -Match 'PRD-A rolled back to GI-x'
        }

        It 'leaves run state untouched without -RunId' {
            $run = New-ScheduledRun -Config $cfg -Start (Get-Date).AddHours(-1)
            Invoke-GIRollback -Config $cfg -PoolName 'PRD-A' -SnapshotName 'GI-x' | Out-Null
            (Get-GIRun -Config $cfg -RunId $run.runId).status | Should -Be 'Scheduled'
        }

        It '-WhatIf pushes nothing' {
            Invoke-GIRollback -Config $cfg -PoolName 'PRD-A' -SnapshotName 'GI-x' -WhatIf | Out-Null
            Should -Invoke -ModuleName VDI-GIPipeline Invoke-GIHorizonPushImage -Times 0 -Exactly
        }
    }
}
