#----------------[ Approval gate, production promotion, post-check, rollback ]----------------

function Enter-GIApprovalGate {
    <#
    .SYNOPSIS
      Called after Validate passes. Parks the run at AwaitingApproval, or approves it automatically
      when Promotion.AutoPromote is $true (start time = next maintenance window).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config, [Parameter(Mandatory)] $Run)

    Set-GIStage -Config $Config -Run $Run -Stage Approval -Status Running -Message 'Waiting for approval'
    $Run.status = 'AwaitingApproval'
    Save-GIRun -Config $Config -Run $Run
    Write-GILog -Config $Config -RunId $Run.runId -Message 'Validation passed; awaiting approval for production'

    if (Get-GIConfigValue $Config 'Promotion.AutoPromote' $false) {
        return Approve-GIRun -Config $Config -RunId $Run.runId -By 'AutoPromote' -Comment 'Automatic promotion (Promotion.AutoPromote = $true)'
    }
    return $Run
}

function Assert-GIAwaitingApproval {
    param([Parameter(Mandatory)] $Run)
    if ($Run.status -ne 'AwaitingApproval') {
        throw "Run $($Run.runId) is '$($Run.status)', not AwaitingApproval."
    }
    if (-not ($Run.validation -and $Run.validation.passed)) {
        throw "Run $($Run.runId) has no passing validation; it can't be promoted."
    }
}

function Approve-GIRun {
    <#
    .SYNOPSIS
      Records approval and schedules the production push. Used by Approve-GIPromotion.ps1 and the dashboard.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [string] $RunId,
        [Parameter(Mandatory)] [string] $By,
        [datetime] $StartTime,
        [string] $Comment = '',
        [switch] $NoConnect   # caller already connected to vCenter/Horizon
    )
    $run = Get-GIRun -Config $Config -RunId $RunId
    Assert-GIAwaitingApproval -Run $run
    if (-not $PSBoundParameters.ContainsKey('StartTime')) { $StartTime = Get-GINextMaintenanceWindow -Config $Config }
    if ($StartTime -lt (Get-Date).AddMinutes(-1)) { throw "Start time $StartTime is in the past." }
    if (-not $PSCmdlet.ShouldProcess("Run $RunId", "Approve and schedule production push at $StartTime")) { return $run }

    $run.approval = [pscustomobject]@{
        decision = 'Approved'; by = $By; at = (Get-Date).ToString('o'); startTime = $StartTime.ToString('o'); comment = $Comment
    }
    Set-GIStage -Config $Config -Run $run -Stage Approval -Status Succeeded -Message "Approved by $By for $($StartTime.ToString('yyyy-MM-dd HH:mm'))"
    Write-GILog -Config $Config -RunId $RunId -Message "Approved by $By; production push at $StartTime" -Level Success

    $connected = $false
    try {
        if (-not $NoConnect) { Connect-GIServices -Config $Config -SkipAppVolumes; $connected = $true }
        $run.status = 'Running'
        Invoke-GIStage -Config $Config -Run $run -Stage Promote -Action { Invoke-GIStagePromote -Config $Config -Run $run -StartTime $StartTime }
        $run.status = 'Scheduled'
        Save-GIRun -Config $Config -Run $run
    } finally {
        if ($connected) { Disconnect-GIServices }
        Save-GIReport -Config $Config -Run $run | Out-Null
        Send-GIReport -Config $Config -Run $run
    }
    return $run
}

function Deny-GIRun {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [string] $RunId,
        [Parameter(Mandatory)] [string] $By,
        [string] $Comment = ''
    )
    $run = Get-GIRun -Config $Config -RunId $RunId
    if ($run.status -ne 'AwaitingApproval') { throw "Run $RunId is '$($run.status)', not AwaitingApproval." }
    if (-not $PSCmdlet.ShouldProcess("Run $RunId", 'Reject')) { return $run }

    $run.approval = [pscustomobject]@{ decision = 'Rejected'; by = $By; at = (Get-Date).ToString('o'); startTime = $null; comment = $Comment }
    Set-GIStage -Config $Config -Run $run -Stage Approval -Status Skipped -Message "Rejected by $By"
    foreach ($s in 'Promote', 'PostCheck') { Set-GIStage -Config $Config -Run $run -Stage $s -Status Skipped }
    $run.status = 'Rejected'
    Save-GIRun -Config $Config -Run $run
    Write-GILog -Config $Config -RunId $RunId -Message "Rejected by $By. $Comment" -Level Warn
    Save-GIReport -Config $Config -Run $run | Out-Null
    Send-GIReport -Config $Config -Run $run
    return $run
}

function Invoke-GIStagePromote {
    <#
    .SYNOPSIS
      Schedules push-image on every production pool. If any pool fails, pushes already scheduled
      by this call are cancelled so production pools don't end up on different images.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] $Run,
        [Parameter(Mandatory)] [datetime] $StartTime
    )
    if (-not $Run.snapshot) { throw 'Run has no snapshot.' }
    $img = Get-GIHorizonBaseImage -Config $Config -SnapshotName $Run.snapshot.name

    $scheduled = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($p in @($Config.Pools.Production)) {
            $pool = Get-GIHorizonPool -Name $p.Name
            $policy = if ($p['LogoffPolicy']) { $p['LogoffPolicy'] } else { 'WAIT_FOR_LOGOFF' }
            Invoke-GIHorizonPushImage -PoolId $pool.id -ParentVmId $img.BaseVm.id -SnapshotId $img.Snapshot.id `
                -StartTime $StartTime -LogoffPolicy $policy -StopOnFirstError $true
            $scheduled.Add([pscustomobject]@{
                poolName = $p.Name; poolId = [string]$pool.id; scheduledStart = $StartTime.ToString('o'); status = 'Scheduled'; message = "logoff policy $policy"
            })
        }
    } catch {
        $err = $_
        foreach ($s in $scheduled) {
            try { Stop-GIHorizonPushImage -PoolId $s.poolId; $s.status = 'Cancelled'; $s.message = 'Cancelled: another pool failed to schedule' }
            catch { $s.message = "Cancel failed: $($_.Exception.Message)" }
        }
        $Run.promotion = [pscustomobject]@{ pools = $scheduled.ToArray() }
        Save-GIRun -Config $Config -Run $Run
        throw $err
    }
    $Run.promotion = [pscustomobject]@{ pools = $scheduled.ToArray() }
    Save-GIRun -Config $Config -Run $Run
    @{ Message = "Scheduled $($scheduled.Count) production pool(s) for $($StartTime.ToString('yyyy-MM-dd HH:mm'))"; Data = @{ horizonSnapshotId = [string]$img.Snapshot.id } }
}

function Invoke-GIStagePostCheck {
    <#
    .SYNOPSIS
      Run after the maintenance window. Returns $true when finished (Completed or Failed),
      $false when pushes are still in progress (the scheduled task should try again later).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config, [Parameter(Mandatory)] $Run)

    if ($Run.status -ne 'Scheduled') { throw "Run $($Run.runId) is '$($Run.status)', not Scheduled." }
    $start = [datetime]$Run.approval.startTime
    if ((Get-Date) -lt $start) {
        Write-GILog -Config $Config -RunId $Run.runId -Message "Maintenance window starts $start; nothing to check yet"
        return $false
    }
    $expected = [string]$Run.stages.Promote.data.horizonSnapshotId
    $timeout  = [int](Get-GIConfigValue $Config 'Pools.PushTimeoutMin' 120)

    # Still pushing and inside the allowed time: come back later
    $pending = $false
    foreach ($p in $Run.promotion.pools | Where-Object status -in 'Scheduled', 'InProgress') {
        $info = Get-GIPoolImageInfo -Pool (Get-GIHorizonPool -Name $p.poolName)
        if ([string]$info.PendingImageState -match 'FAIL|ERROR') { $p.status = 'Failed'; $p.message = "Pending image state $($info.PendingImageState)"; continue }
        if ($info.PendingSnapshotId) { $p.status = 'InProgress'; $pending = $true }
        elseif ([string]$info.SnapshotId -eq $expected) { $p.status = 'Succeeded' }
        else { $p.status = 'Failed'; $p.message = "Pool is on snapshot id '$($info.SnapshotId)', expected '$expected'" }
    }
    Save-GIRun -Config $Config -Run $Run
    if ($pending -and (Get-Date) -lt $start.AddMinutes($timeout)) {
        Set-GIProgress -Config $Config -Run $Run -Message 'Production push in progress'
        return $false
    }

    $Run.status = 'Running'
    try {
        Invoke-GIStage -Config $Config -Run $Run -Stage PostCheck -Action {
            $bad = @($Run.promotion.pools | Where-Object status -ne 'Succeeded')
            if ($bad) { throw "Pool(s) not on the new image: $(($bad | ForEach-Object { "$($_.poolName) ($($_.status))" }) -join ', ')" }
            $checks = foreach ($p in $Run.promotion.pools) {
                Test-GIPoolHealth -Config $Config -Run $Run -PoolName $p.poolName -ExpectedSnapshotId $expected
            }
            $failed = @($checks | Where-Object { -not $_.passed })
            $Run.validation = [pscustomobject]@{
                passed = $Run.validation.passed
                checks = @($Run.validation.checks) + @($checks | ForEach-Object { $_.category = "Prod-$($_.category)"; $_ })
            }
            if ($failed) { throw "$($failed.Count) production check(s) failed, e.g. $($failed[0].target): $($failed[0].detail)" }
            @{ Message = "All production pools on $($Run.snapshot.name) and healthy" }
        }
        $Run.status = 'Completed'
        Save-GIRun -Config $Config -Run $Run
        Set-GILastKnownGood -Config $Config -Run $Run
        Invoke-GIPostProductionRetention -Config $Config -Run $Run
    } finally {
        Save-GIReport -Config $Config -Run $Run | Out-Null
        Send-GIReport -Config $Config -Run $Run
    }
    return $true
}

function Invoke-GIPostProductionRetention {
    <#
    .SYNOPSIS
      Runs snapshot retention once production is on the new Baseline. Results go in $Run.retention and
      the report. Never throws: a completed run stays completed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config, [Parameter(Mandatory)] $Run)
    try {
        $life = Invoke-GISnapshotLifecycle -Config $Config -Run $Run -RunFinished
        $rec = ConvertTo-GIRetentionRecord -Result $life
        $msg = "Snapshot retention $($life.Mode): removed $(@($life.Removed).Count)$(if (@($life.Removed).Count) { " ($($life.Removed -join ', '))" }). Chain: $($life.Chain)"
        if ($null -ne $rec.freedGb) { $msg += ". Freed $($rec.freedGb) GB" }
        Write-GILog -Config $Config -RunId $Run.runId -Message $msg -Level $(if (@($life.Errors).Count) { 'Warn' } else { 'Info' })
        foreach ($w in $life.Warnings) { Write-GILog -Config $Config -RunId $Run.runId -Message $w -Level Warn }
        foreach ($e in $life.Errors) { Write-GILog -Config $Config -RunId $Run.runId -Message $e -Level Error }
    } catch {
        $rec = [pscustomobject]@{ at = (Get-Date).ToString('o'); mode = 'Failed'; errors = @("Snapshot retention failed: $($_.Exception.Message)") }
        Write-GILog -Config $Config -RunId $Run.runId -Message $rec.errors[0] -Level Error
    }
    if ($Run -is [System.Collections.IDictionary] -or $Run.PSObject.Properties['retention']) { $Run.retention = $rec }
    else { $Run | Add-Member -NotePropertyName retention -NotePropertyValue $rec }
    Save-GIRun -Config $Config -Run $Run
}

function Invoke-GIRollback {
    <#
    .SYNOPSIS
      Pushes the last-known-good snapshot (or -SnapshotName) to a pool. Starts now unless -StartTime given.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [string] $PoolName,
        [string] $SnapshotName,
        [datetime] $StartTime = (Get-Date),
        [switch] $ForceLogoff,
        [string] $RunId
    )
    if (-not $SnapshotName) {
        $lkg = Get-GILastKnownGood -Config $Config
        if (-not $lkg) { throw 'No last-known-good snapshot recorded; pass -SnapshotName.' }
        $SnapshotName = $lkg.snapshotName
    }
    $img  = Get-GIHorizonBaseImage -Config $Config -SnapshotName $SnapshotName
    $pool = Get-GIHorizonPool -Name $PoolName
    $info = Get-GIPoolImageInfo -Pool $pool
    if ($info.PendingSnapshotId) { Stop-GIHorizonPushImage -PoolId $pool.id }
    $policy = if ($ForceLogoff) { 'FORCE_LOGOFF' } else { 'WAIT_FOR_LOGOFF' }
    if (-not $PSCmdlet.ShouldProcess($PoolName, "Roll back to $SnapshotName ($policy) at $StartTime")) { return }

    Invoke-GIHorizonPushImage -PoolId $pool.id -ParentVmId $img.BaseVm.id -SnapshotId $img.Snapshot.id -StartTime $StartTime -LogoffPolicy $policy

    if ($RunId) {
        $run = Get-GIRun -Config $Config -RunId $RunId
        $run.status = 'RolledBack'
        $run.progress = "Pool $PoolName rolled back to $SnapshotName"
        Save-GIRun -Config $Config -Run $run
        Write-GILog -Config $Config -RunId $RunId -Message "Rolled back $PoolName to $SnapshotName" -Level Warn
    }
    [pscustomobject]@{ PoolName = $PoolName; SnapshotName = $SnapshotName; StartTime = $StartTime; LogoffPolicy = $policy }
}
