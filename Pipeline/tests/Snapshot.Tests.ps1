BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'VDI-GIPipeline.psd1') -Force
    # Linear chain: base (manual) -> GI-1 -> GI-2 -> ... -> GI-6, plus a pre-maint branch off GI-6
    function New-Snap($Id, $Name, $DaysAgo, $ParentId) {
        [pscustomobject]@{ Id = $Id; Name = $Name; Created = (Get-Date).AddDays(-$DaysAgo); ParentId = $ParentId }
    }
}

Describe 'Get-GISnapshotPruneCandidates' {
    BeforeEach {
        $chain = @(
            (New-Snap 's0' 'Base install'        70 $null)
            (New-Snap 's1' 'GI-20260901-010000'  60 's0')
            (New-Snap 's2' 'GI-20261001-010000'  50 's1')
            (New-Snap 's3' 'GI-20261015-010000'  40 's2')
            (New-Snap 's4' 'GI-20261101-010000'  30 's3')
            (New-Snap 's5' 'GI-20261115-010000'  20 's4')
            (New-Snap 's6' 'GI-20261120-010000'  10 's5')
        )
        # Branches (not ancestors of anything in use)
        $branches = @(
            (New-Snap 'b1' 'GI-20260915-010000' 55 's1')
            (New-Snap 'b2' 'GI-20260920-010000' 54 's1')
        )
    }

    It 'never removes snapshots the pipeline did not create' {
        $r = Get-GISnapshotPruneCandidates -Snapshots $chain -Keep 1 -ProtectAncestors $false
        ($r | Where-Object Id -eq 's0').Action | Should -Be 'Keep'
        ($r | Where-Object Id -eq 's0').Reason | Should -Be 'Not created by pipeline'
    }

    It 'keeps the newest N managed snapshots' {
        $r = Get-GISnapshotPruneCandidates -Snapshots $chain -Keep 2 -ProtectAncestors $false
        ($r | Where-Object Action -eq 'Keep' | Where-Object Name -like 'GI-*').Id | Sort-Object | Should -Be @('s5','s6')
    }

    It 'never removes a snapshot protected by id or by name' {
        $r = Get-GISnapshotPruneCandidates -Snapshots $chain -Keep 1 -ProtectedIds @('s2') -ProtectedNames @('GI-20261015-010000') -ProtectAncestors $false
        ($r | Where-Object Id -eq 's2').Action | Should -Be 'Keep'
        ($r | Where-Object Id -eq 's3').Action | Should -Be 'Keep'
        ($r | Where-Object Id -eq 's1').Action | Should -Be 'Remove'
    }

    It 'protects every ancestor of an in-use snapshot by default' {
        $r = Get-GISnapshotPruneCandidates -Snapshots $chain -Keep 1 -ProtectedIds @('s4')
        foreach ($id in 's1','s2','s3') {
            ($r | Where-Object Id -eq $id).Action | Should -Be 'Keep'
            ($r | Where-Object Id -eq $id).Reason | Should -Be 'Ancestor of a protected snapshot'
        }
        ($r | Where-Object Id -eq 's5').Action | Should -Be 'Remove'
    }

    It 'removes old branches that are not ancestors of anything protected' {
        $r = Get-GISnapshotPruneCandidates -Snapshots ($chain + $branches) -Keep 1 -ProtectedIds @('s6')
        ($r | Where-Object Id -eq 'b1').Action | Should -Be 'Remove'
        ($r | Where-Object Id -eq 'b2').Action | Should -Be 'Remove'
        ($r | Where-Object Action -eq 'Remove').Id | Sort-Object | Should -Be @('b1','b2')
    }

    It 'applies Keep separately to pre-maint safety snapshots' {
        $snaps = $chain + @(
            (New-Snap 'p1' 'pre-maint-20261101-010000' 31 's3')
            (New-Snap 'p2' 'pre-maint-20261120-010000' 11 's5')
        )
        $r = Get-GISnapshotPruneCandidates -Snapshots $snaps -Keep 1 -ProtectAncestors $false
        ($r | Where-Object Id -eq 'p2').Action | Should -Be 'Keep'
        ($r | Where-Object Id -eq 'p1').Action | Should -Be 'Remove'
        ($r | Where-Object Id -eq 's6').Action | Should -Be 'Keep'
    }

    It 'handles an empty snapshot list' {
        @(Get-GISnapshotPruneCandidates -Snapshots @() -Keep 3).Count | Should -Be 0
    }

    It 'survives a parent cycle without hanging' {
        $cyc = @((New-Snap 'x1' 'GI-a' 5 'x2'), (New-Snap 'x2' 'GI-b' 4 'x1'))
        { Get-GISnapshotPruneCandidates -Snapshots $cyc -Keep 1 -ProtectedIds @('x1') } | Should -Not -Throw
    }
}

Describe 'Get-GISnapshotPruneCandidates -Mode Chain' {
    BeforeEach {
        # Master > Baseline 26.11.11.1340 > Baseline 26.11.20.1249 > pre-maint-X > Baseline 26.11.24.0131
        $chain = @(
            (New-Snap 'm'  'Master'                  90 $null)
            (New-Snap 'b1' 'Baseline 26.11.11.1340'  13 'm')
            (New-Snap 'b2' 'Baseline 26.11.20.1249'   4 'b1')
            (New-Snap 'p3' 'pre-maint-20261124-0100'  1 'b2')
            (New-Snap 'b3' 'Baseline 26.11.24.0131'   0 'p3')
        )
        $pat = @('Baseline *', 'GI-*')
    }

    It 'leaves Master > previous > production once production is on the newest Baseline' {
        $r = Get-GISnapshotPruneCandidates -Snapshots $chain -Mode Chain -Keep 2 -BaselinePatterns $pat -ProtectedNames @('Baseline 26.11.24.0131')
        ($r | Where-Object Action -eq 'Remove').Name | Sort-Object | Should -Be @('Baseline 26.11.11.1340', 'pre-maint-20261124-0100')
        ($r | Where-Object Id -eq 'm').Reason | Should -Be 'Root snapshot'
        ($r | Where-Object Id -eq 'b2').Action | Should -Be 'Keep'
    }

    It 'never removes the root, even when it matches a managed name' {
        $c = @((New-Snap 'r' 'Baseline 25.01.01.0000' 400 $null)) + @($chain | Select-Object -Skip 1 | ForEach-Object { $_.ParentId = if ($_.Id -eq 'b1') { 'r' } else { $_.ParentId }; $_ })
        $r = Get-GISnapshotPruneCandidates -Snapshots $c -Mode Chain -Keep 1 -BaselinePatterns $pat
        ($r | Where-Object Id -eq 'r').Action | Should -Be 'Keep'
    }

    It 'never removes a manual snapshot with another name' {
        $c = $chain + @((New-Snap 'x' 'Before driver test' 20 'b1'))
        $r = Get-GISnapshotPruneCandidates -Snapshots $c -Mode Chain -Keep 1 -BaselinePatterns $pat
        ($r | Where-Object Id -eq 'x').Reason | Should -Be 'Not created by pipeline'
    }

    It 'keeps a Baseline a pool still uses even when it is older than Keep' {
        $r = Get-GISnapshotPruneCandidates -Snapshots $chain -Mode Chain -Keep 2 -BaselinePatterns $pat -ProtectedNames @('Baseline 26.11.11.1340')
        ($r | Where-Object Id -eq 'b1').Action | Should -Be 'Keep'
    }

    It 'with ProtectAncestors, keeps every parent of a pending push' {
        $r = Get-GISnapshotPruneCandidates -Snapshots $chain -Mode Chain -Keep 1 -BaselinePatterns $pat -PendingNames @('Baseline 26.11.24.0131')
        foreach ($id in 'b1', 'b2', 'p3') { ($r | Where-Object Id -eq $id).Reason | Should -Be 'Ancestor of a pending push' }
    }

    It 'counts old GI-* runs as Baselines' {
        $c = @(
            (New-Snap 'm' 'Master' 90 $null)
            (New-Snap 'g' 'GI-20261001-010000' 50 'm')
            (New-Snap 'b2' 'Baseline 26.11.20.1249' 4 'g')
            (New-Snap 'b3' 'Baseline 26.11.24.0131' 0 'b2')
        )
        $r = Get-GISnapshotPruneCandidates -Snapshots $c -Mode Chain -Keep 2 -BaselinePatterns $pat
        ($r | Where-Object Action -eq 'Remove').Id | Should -Be @('g')
    }
}

Describe 'New-GISnapshotName' {
    It 'formats as <prefix> yy.MM.dd.HHmm' {
        New-GISnapshotName -Prefix 'Baseline' -At ([datetime]'2026-11-24 01:31') | Should -Be 'Baseline 26.11.24.0131'
    }
}

Describe 'Get-GISnapshotChainDepth' {
    It 'measures the deepest chain' {
        $s = @((New-Snap 'a' 'GI-a' 3 $null), (New-Snap 'b' 'GI-b' 2 'a'), (New-Snap 'c' 'GI-c' 1 'b'), (New-Snap 'd' 'GI-d' 1 'a'))
        Get-GISnapshotChainDepth -Snapshots $s | Should -Be 3
    }
}

Describe 'Invoke-GISnapshotLifecycle' {
    BeforeAll {
        $root = Join-Path $TestDrive 'p'
        New-Item -ItemType Directory -Path $root | Out-Null
        $script:cfg = @{
            Root = $root
            Paths = @{ State = (Join-Path $root 'state'); Reports = (Join-Path $root 'reports'); Logs = (Join-Path $root 'logs') }
            GoldenImage = @{ VmName = 'GI-VM' }
            Snapshots = @{ Keep = 1; MaxChainDepth = 3; Prune = $true; Mode = 'Tree' }
        }
        New-Item -ItemType Directory -Path $cfg.Paths.State -Force | Out-Null
    }

    BeforeEach {
        # PowerCLI isn't installed on the test box; define stubs so Mock can replace them
        InModuleScope VDI-GIPipeline {
            function script:Get-VM { param($Name, $Id) }
            function script:Get-View { param($Id, $Property) }
            function script:Get-Datastore { param($RelatedObject) }
            function script:Get-Snapshot { param($VM) }
            function script:Remove-Snapshot { param($Snapshot, [switch]$Confirm) }
        }
        Mock -ModuleName VDI-GIPipeline Get-VM { [pscustomobject]@{ Name = 'GI-VM'; Id = 'vm-1'; UsedSpaceGB = 100; ExtensionData = [pscustomobject]@{ Runtime = [pscustomobject]@{ ConsolidationNeeded = $false } } } }
        Mock -ModuleName VDI-GIPipeline Get-Datastore { [pscustomobject]@{ Name = 'ds1'; FreeSpaceGB = 500; CapacityGB = 1000 } }
        Mock -ModuleName VDI-GIPipeline Start-Sleep { }
        Mock -ModuleName VDI-GIPipeline Get-Snapshot {
            @(
                [pscustomobject]@{ Id = 's1'; Name = 'GI-1'; Created = (Get-Date).AddDays(-30); ParentSnapshotId = $null }
                [pscustomobject]@{ Id = 's2'; Name = 'GI-2'; Created = (Get-Date).AddDays(-20); ParentSnapshotId = 's1' }
                [pscustomobject]@{ Id = 'b1'; Name = 'GI-branch'; Created = (Get-Date).AddDays(-25); ParentSnapshotId = 's1' }
                [pscustomobject]@{ Id = 's3'; Name = 'GI-3'; Created = (Get-Date).AddDays(-10); ParentSnapshotId = 's2' }
                [pscustomobject]@{ Id = 's4'; Name = 'GI-4'; Created = (Get-Date).AddDays(-1);  ParentSnapshotId = 's3' }
            )
        }
        Mock -ModuleName VDI-GIPipeline Remove-Snapshot { }
    }

    It 'fails closed: removes nothing when Horizon usage cannot be read' {
        Mock -ModuleName VDI-GIPipeline Get-GISnapshotUsage { throw 'Horizon down' }
        $r = Invoke-GISnapshotLifecycle -Config $cfg
        $r.Mode | Should -Be 'ReportOnly'
        Should -Invoke -ModuleName VDI-GIPipeline Remove-Snapshot -Times 0
        $r.Warnings -join ' ' | Should -Match 'pruning disabled'
    }

    It 'removes only non-protected, non-ancestor snapshots when Prune is on' {
        Mock -ModuleName VDI-GIPipeline Get-GISnapshotUsage { @{ Current = @('GI-3'); Pending = @(); Unresolved = @() } }
        $r = Invoke-GISnapshotLifecycle -Config $cfg
        $r.Mode | Should -Be 'Prune'
        $r.Removed | Should -Be @('GI-branch')
        Should -Invoke -ModuleName VDI-GIPipeline Remove-Snapshot -Times 1
    }

    It 'is report-only when Prune is off' {
        Mock -ModuleName VDI-GIPipeline Get-GISnapshotUsage { @{ Current = @(); Pending = @(); Unresolved = @() } }
        $c = $cfg.Clone(); $c.Snapshots = @{ Keep = 1; MaxChainDepth = 3; Prune = $false; Mode = 'Tree' }
        $r = Invoke-GISnapshotLifecycle -Config $c
        $r.Mode | Should -Be 'ReportOnly'
        Should -Invoke -ModuleName VDI-GIPipeline Remove-Snapshot -Times 0
    }

    It 'warns when the chain is deeper than MaxChainDepth' {
        Mock -ModuleName VDI-GIPipeline Get-GISnapshotUsage { @{ Current = @(); Pending = @(); Unresolved = @() } }
        (Invoke-GISnapshotLifecycle -Config $cfg).Warnings -join ' ' | Should -Match 'chain depth 4 exceeds 3'
    }
}

Describe 'Invoke-GISnapshotLifecycle -Mode Chain' {
    BeforeAll {
        $root = Join-Path $TestDrive 'c'
        New-Item -ItemType Directory -Path $root | Out-Null
        $script:ccfg = @{
            Root = $root
            Paths = @{ State = (Join-Path $root 'state'); Reports = (Join-Path $root 'reports'); Logs = (Join-Path $root 'logs') }
            GoldenImage = @{ VmName = 'GI-VM' }
            Snapshots = @{ NamePrefix = 'Baseline'; Mode = 'Chain'; Keep = 2; MaxChainDepth = 10; Prune = $true; ProtectAncestors = $true }
        }
        New-Item -ItemType Directory -Path $ccfg.Paths.State -Force | Out-Null
    }

    BeforeEach {
        InModuleScope VDI-GIPipeline {
            function script:Get-VM { param($Name, $Id) }
            function script:Get-Snapshot { param($VM) }
            function script:Remove-Snapshot { param($Snapshot, [switch]$Confirm) }
            function script:Get-View { param($Id, $Property) }
            function script:Get-Datastore { param($RelatedObject) }
        }
        $global:GISnapCtx = @{ Removed = [System.Collections.Generic.List[string]]::new(); Consolidations = 0; NeedConsolidation = $false; ConsolidateState = 'success'; UsedGB = 300 }
        Mock -ModuleName VDI-GIPipeline Get-VM {
            $ed = [pscustomobject]@{ Runtime = [pscustomobject]@{ ConsolidationNeeded = $global:GISnapCtx.NeedConsolidation } }
            $ed | Add-Member -MemberType ScriptMethod -Name ConsolidateVMDisks_Task -Value {
                $global:GISnapCtx.Consolidations++
                if ($global:GISnapCtx.ConsolidateState -eq 'success') { $global:GISnapCtx.NeedConsolidation = $false }
                'task-1'
            }
            [pscustomobject]@{ Name = 'GI-VM'; Id = 'vm-1'; UsedSpaceGB = $global:GISnapCtx.UsedGB; ExtensionData = $ed }
        }
        Mock -ModuleName VDI-GIPipeline Get-View {
            [pscustomobject]@{ Info = [pscustomobject]@{ State = $global:GISnapCtx.ConsolidateState; Error = [pscustomobject]@{ LocalizedMessage = 'disk locked' } } }
        }
        Mock -ModuleName VDI-GIPipeline Get-Datastore { [pscustomobject]@{ Name = 'ds1'; FreeSpaceGB = 400; CapacityGB = 1000 } }
        Mock -ModuleName VDI-GIPipeline Start-Sleep { }
        Mock -ModuleName VDI-GIPipeline Get-Snapshot {
            @(
                [pscustomobject]@{ Id = 'm';  Name = 'Master';                  Created = (Get-Date).AddDays(-90); ParentSnapshotId = $null }
                [pscustomobject]@{ Id = 'b1'; Name = 'Baseline 26.11.11.1340';  Created = (Get-Date).AddDays(-13); ParentSnapshotId = 'm' }
                [pscustomobject]@{ Id = 'b2'; Name = 'Baseline 26.11.20.1249';  Created = (Get-Date).AddDays(-4);  ParentSnapshotId = 'b1' }
                [pscustomobject]@{ Id = 'p3'; Name = 'pre-maint-RUN3';          Created = (Get-Date).AddDays(-1);  ParentSnapshotId = 'b2' }
                [pscustomobject]@{ Id = 'b3'; Name = 'Baseline 26.11.24.0131';  Created = (Get-Date);              ParentSnapshotId = 'p3' }
            )
        }
        Mock -ModuleName VDI-GIPipeline Remove-Snapshot {
            $global:GISnapCtx.Removed.Add($Snapshot.Name)
            $global:GISnapCtx.UsedGB -= 50
            $global:GISnapCtx.NeedConsolidation = $true
        }
        Mock -ModuleName VDI-GIPipeline Get-GISnapshotUsage { @{ Current = @('Baseline 26.11.24.0131'); Pending = @(); Unresolved = @() } }
        $script:run3 = [pscustomobject]@{ runId = 'RUN3'; snapshot = [pscustomobject]@{ id = 'b3'; name = 'Baseline 26.11.24.0131' }; safetySnapshot = [pscustomobject]@{ id = 'p3'; name = 'pre-maint-RUN3' } }
    }
    AfterEach { Remove-Variable GISnapCtx -Scope Global -ErrorAction SilentlyContinue }

    It 'after production, removes the oldest Baseline and the finished pre-maint, consolidating after each' {
        $r = Invoke-GISnapshotLifecycle -Config $ccfg -Run $run3 -RunFinished
        $r.Mode | Should -Be 'Prune'
        $r.Removed | Should -Be @('Baseline 26.11.11.1340', 'pre-maint-RUN3')
        $global:GISnapCtx.Consolidations | Should -Be 2
        $r.Chain | Should -Be 'Master > Baseline 26.11.20.1249 > Baseline 26.11.24.0131'
        $r.SpaceBefore.UsedGB | Should -Be 300
        $r.SpaceAfter.UsedGB | Should -Be 200
        (ConvertTo-GIRetentionRecord -Result $r).freedGb | Should -Be 100
        $r.Errors.Count | Should -Be 0
    }

    It 'keeps the running pre-maint snapshot when the run is not finished' {
        $r = Invoke-GISnapshotLifecycle -Config $ccfg -Run $run3
        $r.Removed | Should -Be @('Baseline 26.11.11.1340')
    }

    It '-ReportOnly lists candidates and removes nothing' {
        $r = Invoke-GISnapshotLifecycle -Config $ccfg -Run $run3 -RunFinished -ReportOnly
        $r.Mode | Should -Be 'ReportOnly'
        @($r.Plan | Where-Object Action -eq 'Remove').Count | Should -Be 2
        Should -Invoke -ModuleName VDI-GIPipeline Remove-Snapshot -Times 0 -Exactly
    }

    It 'removes nothing while a push is pending' {
        Mock -ModuleName VDI-GIPipeline Get-GISnapshotUsage { @{ Current = @('Baseline 26.11.20.1249'); Pending = @('Baseline 26.11.24.0131'); Unresolved = @() } }
        $r = Invoke-GISnapshotLifecycle -Config $ccfg -Run $run3 -RunFinished
        $r.Mode | Should -Be 'ReportOnly'
        $r.Warnings -join ' ' | Should -Match 'push is pending'
        Should -Invoke -ModuleName VDI-GIPipeline Remove-Snapshot -Times 0 -Exactly
    }

    It 'stops after a failed consolidation' {
        $global:GISnapCtx.ConsolidateState = 'error'
        $r = Invoke-GISnapshotLifecycle -Config $ccfg -Run $run3 -RunFinished
        $r.Removed | Should -Be @('Baseline 26.11.11.1340')
        $r.Errors -join ' ' | Should -Match 'disk locked'
        Should -Invoke -ModuleName VDI-GIPipeline Remove-Snapshot -Times 1 -Exactly
    }

    It 'stops when a pool snapshot no longer resolves in Horizon after a removal' {
        $global:GISnapCtx.UsageCalls = 0
        Mock -ModuleName VDI-GIPipeline Get-GISnapshotUsage {
            $global:GISnapCtx.UsageCalls++
            if ($global:GISnapCtx.UsageCalls -eq 1) { @{ Current = @('Baseline 26.11.24.0131'); Pending = @(); Unresolved = @() } }
            else { @{ Current = @(); Pending = @(); Unresolved = @('PRD-W11') } }
        }
        $r = Invoke-GISnapshotLifecycle -Config $ccfg -Run $run3 -RunFinished
        $r.Removed | Should -Be @('Baseline 26.11.11.1340')
        $r.Errors -join ' ' | Should -Match 'PRD-W11'
    }
}

Describe 'Invoke-GIGoldenConsolidation' {
    BeforeEach {
        InModuleScope VDI-GIPipeline {
            function script:Get-VM { param($Name, $Id) }
            function script:Get-View { param($Id, $Property) }
        }
        $global:GICons = @{ Need = $false; Calls = 0 }
        Mock -ModuleName VDI-GIPipeline Get-VM {
            $ed = [pscustomobject]@{ Runtime = [pscustomobject]@{ ConsolidationNeeded = $global:GICons.Need } }
            $ed | Add-Member -MemberType ScriptMethod -Name ConsolidateVMDisks_Task -Value { $global:GICons.Calls++; $global:GICons.Need = $false; 'task-1' }
            [pscustomobject]@{ Name = 'GI-VM'; Id = 'vm-1'; ExtensionData = $ed }
        }
        Mock -ModuleName VDI-GIPipeline Get-View { [pscustomobject]@{ Info = [pscustomobject]@{ State = 'success' } } }
        Mock -ModuleName VDI-GIPipeline Start-Sleep { }
    }
    AfterEach { Remove-Variable GICons -Scope Global -ErrorAction SilentlyContinue }

    It 'does nothing when vCenter does not flag the VM' {
        $r = Invoke-GIGoldenConsolidation -Config @{} -VM ([pscustomobject]@{ Id = 'vm-1' })
        $r.Needed | Should -BeFalse
        $global:GICons.Calls | Should -Be 0
    }

    It 'consolidates when ConsolidationNeeded is set' {
        $global:GICons.Need = $true
        $r = Invoke-GIGoldenConsolidation -Config @{} -VM ([pscustomobject]@{ Id = 'vm-1' })
        $r.Needed | Should -BeTrue
        $r.Ok | Should -BeTrue
        $global:GICons.Calls | Should -Be 1
    }
}


Describe 'Get-GIFailedRunSnapshots' {
    BeforeAll {
        function script:S($Id, $Name, $Parent, [switch] $Current, $DaysAgo = 1) {
            [pscustomobject]@{ Id = $Id; Name = $Name; Created = (Get-Date).AddDays(-$DaysAgo); ParentId = $Parent; IsCurrent = [bool]$Current }
        }
        $script:status = @{ '20261124-143957' = 'Failed'; '20261120-100000' = 'Completed'; '20261125-090000' = 'AwaitingApproval'; '20261110-100000' = 'Rejected' }
    }

    It 'reverts to the outer of two nested leftovers when the VM sits on the inner one' {
        $snaps = @(
            (S 'm' 'Master' $null -DaysAgo 90)
            (S 'b' 'Baseline 26.11.20.1249' 'm' -DaysAgo 5)
            (S 'p1' 'pre-maint-20261124-143957' 'b' -DaysAgo 2)
            (S 'p2' 'pre-maint-20261124-143957' 'p1' -Current -DaysAgo 1)
        )
        $r = Get-GIFailedRunSnapshots -Snapshots $snaps -RunStatus $status -CurrentRunId '20261126-010101'
        $r.RevertTo.Id | Should -Be 'p1'
        $r.RevertTo.RunStatus | Should -Be 'Failed'
        @($r.Leftovers).Id | Should -Be @('p1', 'p2')
    }

    It 'does not revert when the VM sits on a Baseline, but still lists dead-branch leftovers' {
        $snaps = @(
            (S 'b' 'Baseline 26.11.20.1249' $null -Current -DaysAgo 5)
            (S 'p1' 'pre-maint-20261124-143957' 'b' -DaysAgo 2)
            (S 'p2' 'pre-maint-20261124-143957' 'p1' -DaysAgo 1)
        )
        $r = Get-GIFailedRunSnapshots -Snapshots $snaps -RunStatus $status -CurrentRunId '20261126-010101'
        $r.RevertTo | Should -BeNullOrEmpty
        @($r.Leftovers).Id | Should -Be @('p1', 'p2')
    }

    It 'leaves snapshots of active or completed runs and the current run alone' {
        $snaps = @(
            (S 'b' 'Baseline 26.11.20.1249' $null -DaysAgo 5)
            (S 'pc' 'pre-maint-20261120-100000' 'b' -DaysAgo 4)
            (S 'pa' 'pre-maint-20261125-090000' 'b' -DaysAgo 3)
            (S 'pn' 'pre-maint-20261126-010101' 'pa' -Current -DaysAgo 0)
        )
        $r = Get-GIFailedRunSnapshots -Snapshots $snaps -RunStatus $status -CurrentRunId '20261126-010101'
        @($r.Leftovers) | Should -BeNullOrEmpty
        $r.RevertTo | Should -BeNullOrEmpty
    }

    It 'treats a run with no run file as finished and accepts the -HHmmss suffix' {
        $snaps = @(
            (S 'b' 'Baseline' $null -DaysAgo 5)
            (S 'px' 'pre-maint-20261101-010101-093000' 'b' -Current -DaysAgo 2)
        )
        $r = Get-GIFailedRunSnapshots -Snapshots $snaps -RunStatus @{} -CurrentRunId '20261126-010101'
        $r.RevertTo.Id | Should -Be 'px'
        $r.RevertTo.RunStatus | Should -Be 'Missing'
    }

    It 'stops the revert walk at the first snapshot that is not a leftover' {
        $snaps = @(
            (S 'pr' 'pre-maint-20261110-100000' $null -DaysAgo 10)
            (S 'b' 'Baseline 26.11.20.1249' 'pr' -DaysAgo 5)
            (S 'p1' 'pre-maint-20261124-143957' 'b' -Current -DaysAgo 2)
        )
        $r = Get-GIFailedRunSnapshots -Snapshots $snaps -RunStatus $status -CurrentRunId '20261126-010101'
        $r.RevertTo.Id | Should -Be 'p1'
        @($r.Leftovers).Id | Should -Be @('pr', 'p1')
    }

    It 'skips protected names and ignores non-pipeline snapshots' {
        $snaps = @(
            (S 'x' 'pre-maint-manual-test' $null -DaysAgo 3)
            (S 'p1' 'pre-maint-20261124-143957' 'x' -Current -DaysAgo 2)
        )
        $r = Get-GIFailedRunSnapshots -Snapshots $snaps -RunStatus $status -ProtectedNames @('pre-maint-20261124-143957')
        @($r.Leftovers) | Should -BeNullOrEmpty
    }

    It 'gives ConvertTo-GISnapshotInfo an IsCurrent flag, false when the source has none' {
        $i = [pscustomobject]@{ Id = 's1'; Name = 'GI-1'; Created = (Get-Date); ParentSnapshotId = $null } | ConvertTo-GISnapshotInfo
        $i.IsCurrent | Should -BeFalse
        ([pscustomobject]@{ Id = 's2'; Name = 'GI-2'; Created = (Get-Date); ParentSnapshotId = 's1'; IsCurrent = $true } | ConvertTo-GISnapshotInfo).IsCurrent | Should -BeTrue
    }
}
