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
            Snapshots = @{ Keep = 1; MaxChainDepth = 3; Prune = $true }
        }
        New-Item -ItemType Directory -Path $cfg.Paths.State -Force | Out-Null
    }

    BeforeEach {
        # PowerCLI isn't installed on the test box; define stubs so Mock can replace them
        InModuleScope VDI-GIPipeline {
            function script:Get-VM { param($Name) }
            function script:Get-Snapshot { param($VM) }
            function script:Remove-Snapshot { param($Snapshot, [switch]$Confirm) }
        }
        Mock -ModuleName VDI-GIPipeline Get-VM { [pscustomobject]@{ Name = 'GI-VM' } }
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
        Mock -ModuleName VDI-GIPipeline Get-GIProtectedSnapshotNames { throw 'Horizon down' }
        $r = Invoke-GISnapshotLifecycle -Config $cfg
        $r.Mode | Should -Be 'ReportOnly'
        Should -Invoke -ModuleName VDI-GIPipeline Remove-Snapshot -Times 0
        $r.Warnings -join ' ' | Should -Match 'pruning disabled'
    }

    It 'removes only non-protected, non-ancestor snapshots when Prune is on' {
        Mock -ModuleName VDI-GIPipeline Get-GIProtectedSnapshotNames { @('GI-3') }
        $r = Invoke-GISnapshotLifecycle -Config $cfg
        $r.Mode | Should -Be 'Prune'
        $r.Removed | Should -Be @('GI-branch')
        Should -Invoke -ModuleName VDI-GIPipeline Remove-Snapshot -Times 1
    }

    It 'is report-only when Prune is off' {
        Mock -ModuleName VDI-GIPipeline Get-GIProtectedSnapshotNames { @() }
        $c = $cfg.Clone(); $c.Snapshots = @{ Keep = 1; MaxChainDepth = 3; Prune = $false }
        $r = Invoke-GISnapshotLifecycle -Config $c
        $r.Mode | Should -Be 'ReportOnly'
        Should -Invoke -ModuleName VDI-GIPipeline Remove-Snapshot -Times 0
    }

    It 'warns when the chain is deeper than MaxChainDepth' {
        Mock -ModuleName VDI-GIPipeline Get-GIProtectedSnapshotNames { @() }
        (Invoke-GISnapshotLifecycle -Config $cfg).Warnings -join ' ' | Should -Match 'chain depth 4 exceeds 3'
    }
}

Describe 'Remove-GISafetySnapshot' {
    BeforeAll {
        $script:cfg = @{ GoldenImage = @{ VmName = 'GI-VM' } }
        $script:run = [pscustomobject]@{
            safetySnapshot = [pscustomobject]@{ id = 'pm'; name = 'pre-maint-1' }
            snapshot       = [pscustomobject]@{ id = 'gi'; name = 'GI-1' }
        }
    }
    BeforeEach {
        InModuleScope VDI-GIPipeline {
            function script:Get-VM { param($Name, $Id) }
            function script:Get-Snapshot { param($VM) }
            function script:Remove-Snapshot { param($Snapshot, [switch]$Confirm) }
        }
        Mock -ModuleName VDI-GIPipeline Get-VM { [pscustomobject]@{ Name = 'GI-VM'; Id = 'vm1'; PowerState = 'PoweredOff'; ExtensionData = [pscustomobject]@{ Runtime = [pscustomobject]@{ ConsolidationNeeded = $false } } } }
        Mock -ModuleName VDI-GIPipeline Get-Snapshot {
            @(
                [pscustomobject]@{ Id = 'old'; Name = 'GI-0';        Created = (Get-Date).AddDays(-7); ParentSnapshotId = $null }
                [pscustomobject]@{ Id = 'pm';  Name = 'pre-maint-1'; Created = (Get-Date).AddDays(-1); ParentSnapshotId = 'old' }
                [pscustomobject]@{ Id = 'gi';  Name = 'GI-1';        Created = (Get-Date);             ParentSnapshotId = 'pm' }
            )
        }
        Mock -ModuleName VDI-GIPipeline Remove-Snapshot { }
    }

    It 'removes only the safety snapshot when the GI snapshot is its descendant' {
        $r = Remove-GISafetySnapshot -Config $cfg -Run $run
        $r.Removed | Should -BeTrue
        Should -Invoke -ModuleName VDI-GIPipeline Remove-Snapshot -Times 1 -ParameterFilter { $Snapshot.Id -eq 'pm' }
    }

    It 'keeps it when the VM is powered on' {
        Mock -ModuleName VDI-GIPipeline Get-VM { [pscustomobject]@{ Name = 'GI-VM'; Id = 'vm1'; PowerState = 'PoweredOn' } }
        (Remove-GISafetySnapshot -Config $cfg -Run $run).Removed | Should -BeFalse
        Should -Invoke -ModuleName VDI-GIPipeline Remove-Snapshot -Times 0
    }

    It 'keeps it when the VM already needs consolidation' {
        Mock -ModuleName VDI-GIPipeline Get-VM { [pscustomobject]@{ Name = 'GI-VM'; Id = 'vm1'; PowerState = 'PoweredOff'; ExtensionData = [pscustomobject]@{ Runtime = [pscustomobject]@{ ConsolidationNeeded = $true } } } }
        $r = Remove-GISafetySnapshot -Config $cfg -Run $run
        $r.Removed | Should -BeFalse
        $r.ConsolidationNeeded | Should -BeTrue
        Should -Invoke -ModuleName VDI-GIPipeline Remove-Snapshot -Times 0
    }

    It 'keeps it when the GI snapshot is missing or not a descendant' {
        $other = [pscustomobject]@{ safetySnapshot = $run.safetySnapshot; snapshot = [pscustomobject]@{ id = 'old'; name = 'GI-0' } }
        (Remove-GISafetySnapshot -Config $cfg -Run $other).Removed | Should -BeFalse
        $gone = [pscustomobject]@{ safetySnapshot = $run.safetySnapshot; snapshot = [pscustomobject]@{ id = 'nope'; name = 'GI-x' } }
        (Remove-GISafetySnapshot -Config $cfg -Run $gone).Removed | Should -BeFalse
        Should -Invoke -ModuleName VDI-GIPipeline Remove-Snapshot -Times 0
    }
}
