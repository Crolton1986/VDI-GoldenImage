#----------------[ Golden image snapshot creation + retention ]----------------
# New snapshots are named '<Snapshots.NamePrefix> yy.MM.dd.HHmm' (default 'Baseline 26.11.24.0131').
# Retention only ever touches snapshots the pipeline manages: '<prefix> *', 'GI-*' (older runs)
# and 'pre-maint-*' safety snapshots. Anything else, including the root (Master) snapshot, is kept.
#
# Chain mode (Snapshots.Mode = 'Chain', the default) keeps the chain short:
#   Master > <previous Baseline> > <production Baseline>
# After a production push passes PostCheck, older Baselines and finished pre-maint snapshots are
# removed even though they sit under the production snapshot. vSphere merges a removed snapshot's
# changes into its child, so nothing is lost; disks are consolidated after each removal.
#
# A snapshot is never removed when it is:
#   - the root snapshot, or not managed by the pipeline
#   - referenced by any Horizon pool (current image or pending/scheduled push)
#   - the last-known-good snapshot, or created by the current run (unless the run is finished)
#   - an ancestor of a pending push (Chain mode) or of any protected snapshot (Tree mode),
#     while Snapshots.ProtectAncestors is on
#   - one of the newest <Snapshots.Keep> Baselines

$script:GIManagedSnapshotPatterns = @('GI-*', 'pre-maint-*')
$script:GISafetySnapshotPatterns  = @('pre-maint-*')

function Get-GISnapshotNamePrefix {
    param([Parameter(Mandatory)] [hashtable] $Config)
    $p = [string](Get-GIConfigValue $Config 'Snapshots.NamePrefix' 'Baseline')
    if (-not $p.Trim()) { $p = 'Baseline' }
    return $p.Trim()
}

function Get-GIBaselineSnapshotPatterns {
    # Name patterns that count as Baselines for retention (newest <Keep> of these are kept)
    param([Parameter(Mandatory)] [hashtable] $Config)
    return @("$(Get-GISnapshotNamePrefix -Config $Config) *", 'GI-*') | Select-Object -Unique
}

function New-GISnapshotName {
    param([Parameter(Mandatory)] [string] $Prefix, [datetime] $At = (Get-Date))
    return "$Prefix $($At.ToString('yy.MM.dd.HHmm'))"
}

function Get-GISnapshotPruneCandidates {
    <#
    .SYNOPSIS
      Pure decision logic. Input snapshots need Id, Name, Created, ParentId ($null for root).
      Returns objects: Id, Name, Created, Action (Keep|Remove), Reason.
    .PARAMETER Mode
      Tree: keep the newest <Keep> of each kind; ProtectAncestors keeps every parent of a protected snapshot.
      Chain: Baselines keep the newest <Keep>; safety snapshots go once unprotected; the root is always kept;
      ProtectAncestors only keeps parents of a pending push (PendingIds/PendingNames).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Snapshots,
        [AllowEmptyCollection()] [string[]] $ProtectedIds = @(),
        [AllowEmptyCollection()] [string[]] $ProtectedNames = @(),
        [AllowEmptyCollection()] [string[]] $PendingIds = @(),
        [AllowEmptyCollection()] [string[]] $PendingNames = @(),
        [ValidateRange(1, 100)] [int] $Keep = 3,
        [bool] $ProtectAncestors = $true,
        [ValidateSet('Tree', 'Chain')] [string] $Mode = 'Tree',
        [string[]] $BaselinePatterns = @('GI-*')
    )

    $safetyPatterns = $script:GISafetySnapshotPatterns
    $isLike = { param($name, $patterns) foreach ($pt in $patterns) { if ($name -like $pt) { return $true } }; return $false }

    $byId = @{}
    foreach ($s in $Snapshots) { $byId[[string]$s.Id] = $s }

    # Seed protection: explicit ids + names (pending pushes are in use too)
    $protectedReason = @{}
    $pendingSeed = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $Snapshots) {
        $id = [string]$s.Id
        if ($ProtectedIds -contains $id -or $ProtectedNames -contains $s.Name) { $protectedReason[$id] = 'Protected (in use / last-known-good / current run)' }
        if ($PendingIds -contains $id -or $PendingNames -contains $s.Name) {
            $protectedReason[$id] = 'Protected (pending push)'
            $pendingSeed.Add($id)
        }
    }

    if ($ProtectAncestors) {
        $seeds = if ($Mode -eq 'Chain') { @($pendingSeed) } else { @($protectedReason.Keys) }
        $label = if ($Mode -eq 'Chain') { 'Ancestor of a pending push' } else { 'Ancestor of a protected snapshot' }
        foreach ($id in $seeds) {
            $seen = @{}
            $cur = $byId[$id]
            while ($cur -and $cur.ParentId -and -not $seen.ContainsKey([string]$cur.ParentId)) {
                $pid_ = [string]$cur.ParentId
                $seen[$pid_] = $true
                if (-not $protectedReason.ContainsKey($pid_)) { $protectedReason[$pid_] = $label }
                $cur = $byId[$pid_]
            }
        }
    }

    # Newest N kept: Baselines as one group; in Tree mode each safety pattern is its own group too
    $keepNewest = @{}
    $groups = @(, $BaselinePatterns)
    if ($Mode -eq 'Tree') { foreach ($pt in $safetyPatterns) { $groups += , @($pt) } }
    foreach ($g in $groups) {
        $Snapshots | Where-Object { & $isLike $_.Name $g } |
            Sort-Object { [datetime]$_.Created } -Descending |
            Select-Object -First $Keep |
            ForEach-Object { $keepNewest[[string]$_.Id] = $true }
    }

    foreach ($s in ($Snapshots | Sort-Object { [datetime]$_.Created })) {
        $id = [string]$s.Id
        $baseline = & $isLike $s.Name $BaselinePatterns
        $safety   = & $isLike $s.Name $safetyPatterns

        $action = 'Keep'
        $reason = if ($Mode -eq 'Chain' -and -not $s.ParentId) { 'Root snapshot' }
                  elseif (-not ($baseline -or $safety)) { 'Not created by pipeline' }
                  elseif ($protectedReason.ContainsKey($id)) { $protectedReason[$id] }
                  elseif ($keepNewest.ContainsKey($id)) { "Within newest $Keep" }
                  elseif ($Mode -eq 'Chain' -and $safety) { $action = 'Remove'; 'Safety snapshot of a finished run' }
                  else { $action = 'Remove'; 'Older than retention' }

        [pscustomobject]@{ Id = $id; Name = $s.Name; Created = $s.Created; Action = $action; Reason = $reason }
    }
}

function Get-GISnapshotChainDepth {
    # Depth of the deepest snapshot (root = 1)
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Snapshots)
    $byId = @{}; foreach ($s in $Snapshots) { $byId[[string]$s.Id] = $s }
    $max = 0
    foreach ($s in $Snapshots) {
        $d = 1; $cur = $s; $guard = 0
        while ($cur.ParentId -and $byId.ContainsKey([string]$cur.ParentId) -and $guard -lt 1000) {
            $d++; $cur = $byId[[string]$cur.ParentId]; $guard++
        }
        if ($d -gt $max) { $max = $d }
    }
    return $max
}

function ConvertTo-GISnapshotInfo {
    # Maps PowerCLI VirtualMachineSnapshot objects to the shape the pure functions need
    param([Parameter(Mandatory, ValueFromPipeline)] $Snapshot)
    process {
        [pscustomobject]@{
            Id       = [string]$Snapshot.Id
            Name     = $Snapshot.Name
            Created  = $Snapshot.Created
            ParentId = if ($Snapshot.ParentSnapshotId) { [string]$Snapshot.ParentSnapshotId } else { $null }
            Raw      = $Snapshot
        }
    }
}

function New-GIGoldenSnapshot {
    <#
    .SYNOPSIS
      Snapshots the powered-off golden VM as '<NamePrefix> yy.MM.dd.HHmm', with the version manifest in the description.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] $Run,
        [hashtable] $Manifest = @{}
    )
    $vm = Get-VM -Name $Config.GoldenImage.VmName -ErrorAction Stop
    if ($vm.PowerState -ne 'PoweredOff') {
        throw "Golden VM '$($vm.Name)' is $($vm.PowerState); it must be powered off (finalized) before the snapshot."
    }
    $name = New-GISnapshotName -Prefix (Get-GISnapshotNamePrefix -Config $Config)
    $desc = "VDI pipeline run $($Run.runId). Manifest: " + ($Manifest | ConvertTo-Json -Compress)
    if ($desc.Length -gt 4000) { $desc = $desc.Substring(0, 4000) }

    if (-not $PSCmdlet.ShouldProcess($vm.Name, "Create snapshot $name")) { return }
    $snap = New-Snapshot -VM $vm -Name $name -Description $desc -Memory:$false -Quiesce:$false -Confirm:$false -ErrorAction Stop
    [pscustomobject]@{
        id        = [string]$snap.Id
        name      = $snap.Name
        createdAt = ([datetime]$snap.Created).ToString('o')
        manifest  = $Manifest
    }
}

function Get-GISnapshotUsage {
    <#
    .SYNOPSIS
      Which golden VM snapshots Horizon pools use. Horizon reports its own snapshot ids; they are mapped
      to names via /external/v1/base-snapshots. Returns @{ Current; Pending; Unresolved }, where
      Unresolved lists pools on the golden VM whose snapshot id no longer maps to a snapshot.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config)

    $img = Get-GIHorizonBaseImage -Config $Config
    $idToName = @{}
    foreach ($s in $img.AllSnapshots) { $idToName[[string]$s.id] = $s.name }

    $current    = [System.Collections.Generic.HashSet[string]]::new()
    $pending    = [System.Collections.Generic.HashSet[string]]::new()
    $unresolved = [System.Collections.Generic.List[string]]::new()
    foreach ($pool in (Get-GIHorizonPools)) {
        $info = Get-GIPoolImageInfo -Pool $pool
        if ($info.ParentVmId -and $info.ParentVmId -eq $img.BaseVm.id -and $info.SnapshotId) {
            if ($idToName.ContainsKey([string]$info.SnapshotId)) { [void]$current.Add($idToName[[string]$info.SnapshotId]) }
            else { $unresolved.Add([string]$info.Name) }
        }
        if ($info.PendingParentVmId -and $info.PendingParentVmId -eq $img.BaseVm.id -and $info.PendingSnapshotId) {
            if ($idToName.ContainsKey([string]$info.PendingSnapshotId)) { [void]$pending.Add($idToName[[string]$info.PendingSnapshotId]) }
            else { $unresolved.Add("$($info.Name) (pending)") }
        }
    }
    return @{ Current = @($current); Pending = @($pending); Unresolved = @($unresolved) }
}

function Get-GIProtectedSnapshotNames {
    # Snapshot names on the golden VM that Horizon pools use now or have a push pending for.
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config)
    $u = Get-GISnapshotUsage -Config $Config
    return @(@($u.Current) + @($u.Pending) | Select-Object -Unique)
}

function Get-GIGoldenSpace {
    # Used space of the golden VM and free space on its datastores. Informational: $null on failure.
    param([Parameter(Mandatory)] $VM)
    try {
        $v = Get-VM -Id $VM.Id -ErrorAction Stop
        $ds = @(Get-Datastore -RelatedObject $v -ErrorAction Stop | ForEach-Object {
            $cap = [double]$_.CapacityGB
            [pscustomobject]@{
                Name        = $_.Name
                FreeGB      = [math]::Round([double]$_.FreeSpaceGB, 1)
                CapacityGB  = [math]::Round($cap, 1)
                FreePercent = if ($cap -gt 0) { [math]::Round(100 * [double]$_.FreeSpaceGB / $cap, 1) } else { $null }
            }
        })
        return [pscustomobject]@{ UsedGB = [math]::Round([double]$v.UsedSpaceGB, 1); Datastores = $ds }
    } catch {
        Write-Verbose "Space lookup failed: $($_.Exception.Message)"
        return $null
    }
}

function Invoke-GIGoldenConsolidation {
    <#
    .SYNOPSIS
      Consolidates the golden VM's disks when vCenter flags it (Runtime.ConsolidationNeeded).
      Returns @{ Needed; Ok; Message }. Never throws.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [hashtable] $Config, [Parameter(Mandatory)] $VM)
    try {
        $v = Get-VM -Id $VM.Id -ErrorAction Stop
        if (-not $v.ExtensionData.Runtime.ConsolidationNeeded) {
            return [pscustomobject]@{ Needed = $false; Ok = $true; Message = 'No consolidation needed' }
        }
        if (-not $PSCmdlet.ShouldProcess($v.Name, 'Consolidate disks')) {
            return [pscustomobject]@{ Needed = $true; Ok = $false; Message = 'Consolidation needed (skipped: WhatIf)' }
        }
        $timeout = [int](Get-GIConfigValue $Config 'Snapshots.ConsolidateTimeoutMin' 60)
        $deadline = (Get-Date).AddMinutes($timeout)
        $taskRef = $v.ExtensionData.ConsolidateVMDisks_Task()
        while ($true) {
            $info = (Get-View -Id $taskRef -Property Info -ErrorAction Stop).Info
            $state = [string]$info.State
            if ($state -eq 'success') { break }
            if ($state -eq 'error') {
                $msg = if ($info.Error -and $info.Error.LocalizedMessage) { $info.Error.LocalizedMessage } else { 'unknown error' }
                return [pscustomobject]@{ Needed = $true; Ok = $false; Message = "Disk consolidation failed: $msg" }
            }
            if ((Get-Date) -gt $deadline) {
                return [pscustomobject]@{ Needed = $true; Ok = $false; Message = "Disk consolidation did not finish within $timeout minutes" }
            }
            Start-Sleep -Seconds 10
        }
        $after = Get-VM -Id $VM.Id -ErrorAction Stop
        if ($after.ExtensionData.Runtime.ConsolidationNeeded) {
            return [pscustomobject]@{ Needed = $true; Ok = $false; Message = 'Disk consolidation finished but vCenter still flags the VM as needing consolidation' }
        }
        return [pscustomobject]@{ Needed = $true; Ok = $true; Message = 'Disks consolidated' }
    } catch {
        return [pscustomobject]@{ Needed = $true; Ok = $false; Message = "Disk consolidation check failed: $($_.Exception.Message)" }
    }
}

function Get-GISnapshotChainText {
    # 'Master > Baseline 26.11.20.1249 > Baseline 26.11.24.0131' for the deepest branch
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Snapshots)
    if (-not $Snapshots.Count) { return '(no snapshots)' }
    $byId = @{}; foreach ($s in $Snapshots) { $byId[[string]$s.Id] = $s }
    $best = @()
    foreach ($s in $Snapshots) {
        $path = [System.Collections.Generic.List[string]]::new(); $cur = $s; $guard = 0
        while ($cur -and $guard -lt 1000) { $path.Insert(0, $cur.Name); $cur = if ($cur.ParentId) { $byId[[string]$cur.ParentId] }; $guard++ }
        if ($path.Count -gt $best.Count) { $best = $path.ToArray() }
    }
    return ($best -join ' > ')
}

function Invoke-GISnapshotLifecycle {
    <#
    .SYNOPSIS
      Applies retention to the golden VM's snapshots. Report-only unless Config.Snapshots.Prune is $true
      and -ReportOnly is not set. Fails closed: if pool usage can't be read from Horizon, or a push is
      pending, nothing is removed. Removes one snapshot at a time (oldest first), consolidates disks
      after each, and stops on the first consolidation failure or pool whose snapshot no longer resolves.
    .PARAMETER RunFinished
      The run passed production PostCheck: its own pre-maint safety snapshot is no longer protected.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        $Run,
        [switch] $ReportOnly,
        [switch] $RunFinished
    )
    $cfg = $Config.Snapshots
    if (-not $cfg) { $cfg = @{} }
    $keep = if ($cfg['Keep']) { [int]$cfg['Keep'] } else { 2 }
    $protectAncestors = if ($cfg.ContainsKey('ProtectAncestors')) { [bool]$cfg['ProtectAncestors'] } else { $true }
    $mode = if ($cfg['Mode'] -in 'Tree', 'Chain') { [string]$cfg['Mode'] } else { 'Chain' }
    $prune = [bool]$cfg['Prune'] -and -not $ReportOnly
    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()

    $vm = Get-VM -Name $Config.GoldenImage.VmName -ErrorAction Stop
    $snaps = @(Get-Snapshot -VM $vm -ErrorAction Stop | ConvertTo-GISnapshotInfo)

    $protectedNames = [System.Collections.Generic.List[string]]::new()
    $pendingNames = @()
    $unresolvedBefore = @()
    $usageKnown = $true
    try {
        $usage = Get-GISnapshotUsage -Config $Config
        foreach ($n in $usage.Current) { $protectedNames.Add($n) }
        $pendingNames = @($usage.Pending)
        $unresolvedBefore = @($usage.Unresolved)
    } catch {
        $usageKnown = $false
        $warnings.Add("Could not read pool snapshot usage from Horizon ($($_.Exception.Message)); pruning disabled for this run.")
    }
    $lkg = Get-GILastKnownGood -Config $Config
    $protectedIds = @()
    if ($lkg) { $protectedIds += [string]$lkg.snapshotId; $protectedNames.Add([string]$lkg.snapshotName) }
    if ($Run -and $Run.snapshot -and $Run.snapshot.id) { $protectedIds += [string]$Run.snapshot.id }
    if (-not $RunFinished -and $Run -and $Run.safetySnapshot -and $Run.safetySnapshot.id) { $protectedIds += [string]$Run.safetySnapshot.id }

    $plan = @(Get-GISnapshotPruneCandidates -Snapshots $snaps -ProtectedIds $protectedIds `
        -ProtectedNames @($protectedNames) -PendingNames $pendingNames -Keep $keep -ProtectAncestors $protectAncestors `
        -Mode $mode -BaselinePatterns (Get-GIBaselineSnapshotPatterns -Config $Config))

    $depth = Get-GISnapshotChainDepth -Snapshots $snaps
    $maxDepth = if ($cfg['MaxChainDepth']) { [int]$cfg['MaxChainDepth'] } else { 10 }
    if ($depth -gt $maxDepth) {
        $warnings.Add("Snapshot chain depth $depth exceeds $maxDepth. Plan a new golden image generation (full clone of the VM without snapshots) and repoint pools to it.")
    }

    $canDelete = $prune -and $usageKnown
    if ($canDelete -and $pendingNames.Count) {
        $warnings.Add("A push is pending for $($pendingNames -join ', '); no snapshots removed this time.")
        $canDelete = $false
    }

    $removed = [System.Collections.Generic.List[string]]::new()
    $consolidation = [System.Collections.Generic.List[string]]::new()
    $toRemove = @($plan | Where-Object Action -eq 'Remove')
    $spaceBefore = $null
    $spaceAfter = $null
    if ($canDelete -and $toRemove.Count) {
        $spaceBefore = Get-GIGoldenSpace -VM $vm
        foreach ($p in $toRemove) {
            $raw = ($snaps | Where-Object Id -eq $p.Id).Raw
            if (-not $PSCmdlet.ShouldProcess("$($vm.Name)/$($p.Name)", 'Remove snapshot')) { continue }
            try {
                # No -RemoveChildren: only this snapshot goes; its changes merge into its child
                Remove-Snapshot -Snapshot $raw -Confirm:$false -ErrorAction Stop
                $removed.Add($p.Name)
            } catch {
                $errors.Add("Failed to remove snapshot '$($p.Name)': $($_.Exception.Message). Stopped removing snapshots.")
                break
            }
            $c = Invoke-GIGoldenConsolidation -Config $Config -VM $vm
            if ($c.Needed) { $consolidation.Add("$($p.Name): $($c.Message)") }
            if (-not $c.Ok) { $errors.Add("$($c.Message) after removing '$($p.Name)'. Stopped removing snapshots; consolidate the VM in vCenter."); break }
            try {
                $now = Get-GISnapshotUsage -Config $Config
                $broken = @($now.Unresolved | Where-Object { $_ -notin $unresolvedBefore })
                if ($broken.Count) {
                    $errors.Add("After removing '$($p.Name)', Horizon can no longer resolve the image snapshot for: $($broken -join ', '). Stopped removing snapshots.")
                    break
                }
            } catch {
                $errors.Add("Could not re-check Horizon after removing '$($p.Name)' ($($_.Exception.Message)). Stopped removing snapshots.")
                break
            }
        }
        $spaceAfter = Get-GIGoldenSpace -VM $vm
    }

    # Remaining chain: removed snapshots merge into their child, so re-parent past them
    $removedIds = @($plan | Where-Object { $_.Name -in $removed } | ForEach-Object Id)
    $byId = @{}; foreach ($s in $snaps) { $byId[[string]$s.Id] = $s }
    $remaining = @($snaps | Where-Object { [string]$_.Id -notin $removedIds } | ForEach-Object {
        $parent = $_.ParentId; $guard = 0
        while ($parent -and [string]$parent -in $removedIds -and $guard -lt 1000) { $parent = $byId[[string]$parent].ParentId; $guard++ }
        [pscustomobject]@{ Id = $_.Id; Name = $_.Name; Created = $_.Created; ParentId = $parent }
    })
    [pscustomobject]@{
        Mode          = if ($canDelete) { 'Prune' } else { 'ReportOnly' }
        RetentionMode = $mode
        ChainDepth    = $depth
        Plan          = $plan
        Removed       = @($removed)
        Consolidation = @($consolidation)
        SpaceBefore   = $spaceBefore
        SpaceAfter    = $spaceAfter
        Chain         = Get-GISnapshotChainText -Snapshots $remaining
        Warnings      = @($warnings)
        Errors        = @($errors)
    }
}

function ConvertTo-GIRetentionRecord {
    # Flattens a lifecycle result into what the run JSON and report store
    param([Parameter(Mandatory)] $Result)
    $freed = $null
    if ($Result.SpaceBefore -and $Result.SpaceAfter) { $freed = [math]::Round($Result.SpaceBefore.UsedGB - $Result.SpaceAfter.UsedGB, 1) }
    $ds = if ($Result.SpaceAfter) { $Result.SpaceAfter.Datastores } elseif ($Result.SpaceBefore) { $Result.SpaceBefore.Datastores }
    [pscustomobject]@{
        at            = (Get-Date).ToString('o')
        mode          = $Result.Mode
        chain         = $Result.Chain
        removed       = @($Result.Removed)
        candidates    = @($Result.Plan | Where-Object Action -eq 'Remove' | ForEach-Object Name)
        consolidation = @($Result.Consolidation)
        usedGbBefore  = if ($Result.SpaceBefore) { $Result.SpaceBefore.UsedGB }
        usedGbAfter   = if ($Result.SpaceAfter) { $Result.SpaceAfter.UsedGB }
        freedGb       = $freed
        datastores    = @($ds | ForEach-Object { "$($_.Name): $($_.FreeGB) GB free of $($_.CapacityGB) GB ($($_.FreePercent)%)" })
        warnings      = @($Result.Warnings)
        errors        = @($Result.Errors)
    }
}
