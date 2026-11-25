#----------------[ Golden image snapshot creation + retention ]----------------
# Retention only ever touches snapshots the pipeline created (names 'GI-*' and 'pre-maint-*').
# A snapshot is never removed when it is:
#   - referenced by any Horizon pool (current image or pending/scheduled push)
#   - the last-known-good snapshot
#   - created by the current run
#   - an ancestor of any of the above (Snapshots.ProtectAncestors, default $true).
#     Horizon tracks the base image by snapshot path; deleting a parent changes the path of
#     every child and can break provisioning/resync for pools on that child.
#   - one of the newest <Snapshots.Keep> snapshots of its kind

$script:GIManagedSnapshotPatterns = @('GI-*', 'pre-maint-*')

function Get-GISnapshotPruneCandidates {
    <#
    .SYNOPSIS
      Pure decision logic. Input snapshots need Id, Name, Created, ParentId ($null for root).
      Returns objects: Id, Name, Created, Action (Keep|Remove), Reason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Snapshots,
        [AllowEmptyCollection()] [string[]] $ProtectedIds = @(),
        [AllowEmptyCollection()] [string[]] $ProtectedNames = @(),
        [ValidateRange(1, 100)] [int] $Keep = 3,
        [bool] $ProtectAncestors = $true
    )

    $byId = @{}
    foreach ($s in $Snapshots) { $byId[[string]$s.Id] = $s }

    # Seed protection: explicit ids + names
    $protectedReason = @{}
    foreach ($s in $Snapshots) {
        if ($ProtectedIds -contains [string]$s.Id)  { $protectedReason[[string]$s.Id] = 'Protected (in use / last-known-good / current run)' }
        elseif ($ProtectedNames -contains $s.Name)  { $protectedReason[[string]$s.Id] = 'Protected (in use / last-known-good / current run)' }
    }

    if ($ProtectAncestors) {
        foreach ($id in @($protectedReason.Keys)) {
            $seen = @{}
            $cur = $byId[$id]
            while ($cur -and $cur.ParentId -and -not $seen.ContainsKey([string]$cur.ParentId)) {
                $pid_ = [string]$cur.ParentId
                $seen[$pid_] = $true
                if (-not $protectedReason.ContainsKey($pid_)) { $protectedReason[$pid_] = 'Ancestor of a protected snapshot' }
                $cur = $byId[$pid_]
            }
        }
    }

    # Newest N per managed pattern are kept
    $keepNewest = @{}
    foreach ($pattern in $script:GIManagedSnapshotPatterns) {
        $Snapshots | Where-Object { $_.Name -like $pattern } |
            Sort-Object { [datetime]$_.Created } -Descending |
            Select-Object -First $Keep |
            ForEach-Object { $keepNewest[[string]$_.Id] = $true }
    }

    foreach ($s in ($Snapshots | Sort-Object { [datetime]$_.Created })) {
        $id = [string]$s.Id
        $managed = $false
        foreach ($pattern in $script:GIManagedSnapshotPatterns) { if ($s.Name -like $pattern) { $managed = $true } }

        $action = 'Keep'
        $reason = if (-not $managed) { 'Not created by pipeline' }
                  elseif ($protectedReason.ContainsKey($id)) { $protectedReason[$id] }
                  elseif ($keepNewest.ContainsKey($id)) { "Within newest $Keep" }
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
      Snapshots the powered-off golden VM as GI-<RunId>, with the version manifest in the description.
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
    $name = "GI-$($Run.runId)"
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

function Remove-GISafetySnapshot {
    <#
    .SYNOPSIS
      Removes the run's pre-maint-<RunId> snapshot once the GI-<RunId> snapshot exists, so it is gone
      before Horizon first sees the image. Horizon identifies a base snapshot by its path
      (/pre-maint-X/GI-X); removing the parent after a push would change that path under the pool.
      The safety snapshot has done its job at this point: the GI snapshot is the known-good state.
      Only the safety snapshot is touched, never children. Skipped (with a reason) unless the VM is
      powered off, the GI snapshot is confirmed as a descendant of the safety snapshot, and nothing
      else is already waiting on disk consolidation.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [hashtable] $Config, [Parameter(Mandatory)] $Run)

    $result = [pscustomobject]@{ Removed = $false; Name = $null; Reason = ''; ConsolidationNeeded = $false }
    if (-not $Run.safetySnapshot -or -not $Run.safetySnapshot.id) { $result.Reason = 'Run has no safety snapshot.'; return $result }
    if (-not $Run.snapshot -or -not $Run.snapshot.id) { $result.Reason = 'GI snapshot not created yet.'; return $result }
    $result.Name = [string]$Run.safetySnapshot.name

    $vm = Get-VM -Name $Config.GoldenImage.VmName -ErrorAction Stop
    if ($vm.PowerState -ne 'PoweredOff') { $result.Reason = "VM is $($vm.PowerState); not removing snapshots."; return $result }
    if ($vm.ExtensionData -and $vm.ExtensionData.Runtime -and $vm.ExtensionData.Runtime.ConsolidationNeeded) {
        $result.ConsolidationNeeded = $true
        $result.Reason = 'VM already needs disk consolidation; fix that first (vSphere: Snapshots > Consolidate).'
        return $result
    }

    $snaps = @(Get-Snapshot -VM $vm -ErrorAction Stop | ConvertTo-GISnapshotInfo)
    $byId = @{}; foreach ($x in $snaps) { $byId[[string]$x.Id] = $x }
    $safety = $byId[[string]$Run.safetySnapshot.id]
    $gi     = $byId[[string]$Run.snapshot.id]
    if (-not $safety) { $result.Reason = 'Safety snapshot is already gone.'; return $result }
    if (-not $gi)     { $result.Reason = 'GI snapshot not found on the VM; keeping the safety snapshot.'; return $result }
    $isChild = $false; $cur = $gi; $hops = 0
    while ($cur -and $cur.ParentId -and $hops++ -lt 200) {
        if ([string]$cur.ParentId -eq [string]$safety.Id) { $isChild = $true; break }
        $cur = $byId[[string]$cur.ParentId]
    }
    if (-not $isChild) { $result.Reason = 'GI snapshot is not a descendant of the safety snapshot; keeping it.'; return $result }

    if (-not $PSCmdlet.ShouldProcess("$($vm.Name)/$($safety.Name)", 'Remove safety snapshot')) { return $result }
    Remove-Snapshot -Snapshot $safety.Raw -Confirm:$false -ErrorAction Stop   # no -RemoveChildren
    $result.Removed = $true
    $vm = Get-VM -Id $vm.Id
    if ($vm.ExtensionData -and $vm.ExtensionData.Runtime -and $vm.ExtensionData.Runtime.ConsolidationNeeded) { $result.ConsolidationNeeded = $true }
    return $result
}

function Get-GIProtectedSnapshotNames {
    <#
    .SYNOPSIS
      Snapshot names on the golden VM that Horizon pools use now or have a push pending for.
      Horizon reports its own snapshot ids; they are mapped to names via /external/v1/base-snapshots.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config)

    $img = Get-GIHorizonBaseImage -Config $Config
    $idToName = @{}
    foreach ($s in $img.AllSnapshots) { $idToName[[string]$s.id] = $s.name }

    $names = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($pool in (Get-GIHorizonPools)) {
        $info = Get-GIPoolImageInfo -Pool $pool
        foreach ($pair in @(@($info.ParentVmId, $info.SnapshotId), @($info.PendingParentVmId, $info.PendingSnapshotId))) {
            if ($pair[0] -and $pair[0] -eq $img.BaseVm.id -and $pair[1] -and $idToName.ContainsKey([string]$pair[1])) {
                [void]$names.Add($idToName[[string]$pair[1]])
            }
        }
    }
    return @($names)
}

function Invoke-GISnapshotLifecycle {
    <#
    .SYNOPSIS
      Applies retention to the golden VM's snapshots. Report-only unless Config.Snapshots.Prune is $true.
      Fails closed: if pool usage can't be read from Horizon, nothing is removed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        $Run
    )
    $cfg = $Config.Snapshots
    $keep = if ($cfg['Keep']) { [int]$cfg['Keep'] } else { 3 }
    $protectAncestors = if ($cfg.ContainsKey('ProtectAncestors')) { [bool]$cfg['ProtectAncestors'] } else { $true }
    $prune = [bool]$cfg['Prune']
    $warnings = [System.Collections.Generic.List[string]]::new()

    $vm = Get-VM -Name $Config.GoldenImage.VmName -ErrorAction Stop
    $snaps = @(Get-Snapshot -VM $vm -ErrorAction Stop | ConvertTo-GISnapshotInfo)

    $protectedNames = [System.Collections.Generic.List[string]]::new()
    $usageKnown = $true
    try {
        foreach ($n in (Get-GIProtectedSnapshotNames -Config $Config)) { $protectedNames.Add($n) }
    } catch {
        $usageKnown = $false
        $warnings.Add("Could not read pool snapshot usage from Horizon ($($_.Exception.Message)); pruning disabled for this run.")
    }
    $lkg = Get-GILastKnownGood -Config $Config
    $protectedIds = @()
    if ($lkg) { $protectedIds += [string]$lkg.snapshotId; $protectedNames.Add([string]$lkg.snapshotName) }
    if ($Run -and $Run.snapshot -and $Run.snapshot.id) { $protectedIds += [string]$Run.snapshot.id }
    if ($Run -and $Run.safetySnapshot -and $Run.safetySnapshot.id) { $protectedIds += [string]$Run.safetySnapshot.id }

    $plan = @(Get-GISnapshotPruneCandidates -Snapshots $snaps -ProtectedIds $protectedIds `
        -ProtectedNames @($protectedNames) -Keep $keep -ProtectAncestors $protectAncestors)

    $depth = Get-GISnapshotChainDepth -Snapshots $snaps
    $maxDepth = if ($cfg['MaxChainDepth']) { [int]$cfg['MaxChainDepth'] } else { 10 }
    if ($depth -gt $maxDepth) {
        $warnings.Add("Snapshot chain depth $depth exceeds $maxDepth. Plan a new golden image generation (full clone of the VM without snapshots) and repoint pools to it.")
    }

    $removed = [System.Collections.Generic.List[string]]::new()
    $toRemove = @($plan | Where-Object Action -eq 'Remove')
    if ($prune -and $usageKnown) {
        foreach ($p in $toRemove) {
            $raw = ($snaps | Where-Object Id -eq $p.Id).Raw
            if ($PSCmdlet.ShouldProcess("$($vm.Name)/$($p.Name)", 'Remove snapshot')) {
                try {
                    # No -RemoveChildren: only this snapshot is consolidated away
                    Remove-Snapshot -Snapshot $raw -Confirm:$false -ErrorAction Stop
                    $removed.Add($p.Name)
                } catch {
                    $warnings.Add("Failed to remove snapshot '$($p.Name)': $($_.Exception.Message)")
                }
            }
        }
    }

    [pscustomobject]@{
        Mode       = if ($prune -and $usageKnown) { 'Prune' } else { 'ReportOnly' }
        ChainDepth = $depth
        Plan       = $plan
        Removed    = @($removed)
        Warnings   = @($warnings)
    }
}
