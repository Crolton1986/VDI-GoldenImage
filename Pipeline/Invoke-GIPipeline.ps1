<#
.SYNOPSIS
  Golden image pipeline entry point (run on the management server, PowerShell 7 + VMware PowerCLI).
.DESCRIPTION
  -Stage All        new run: Preflight, Maintain, Snapshot, TestPush, Validate, then the approval gate
  -Stage <name>     re-run one stage of an existing run (-RunId, default: newest run)
  -Stage PostCheck  check production after the maintenance window (schedule this; safe to run repeatedly)
  -Stage Rollback   push the last-known-good snapshot (or -SnapshotName) to -PoolName
  -Stage Status     print the newest runs
  -FromStage <name> continue an existing run (-RunId) from that stage through Validate
  -FromStep <id>    with -FromStage Maintain or -Stage Maintain: resume Maintain at that sub-step (e.g. Pkg:Horizon;
                    SafetySnapshot restarts it). Without it, a failed Maintain resumes at its first unfinished step.
  -FromRequest      run the request queued by the dashboard (state/run-request.json); used by the VDI-GI-Runner task
  Every invocation except Status holds state/pipeline.lock, so scheduled, CLI and dashboard runs never overlap.
.EXAMPLE
  PS> .\Invoke-GIPipeline.ps1 -FromStage TestPush -RunId 20261124-213005
.EXAMPLE
  PS> .\Invoke-GIPipeline.ps1 -FromStage Maintain -FromStep Pkg:Horizon -RunId 20261124-213005
.EXAMPLE
  PS> .\Invoke-GIPipeline.ps1 -Stage All
.EXAMPLE
  PS> .\Invoke-GIPipeline.ps1 -Stage Validate -RunId 20261124-213005
.EXAMPLE
  PS> .\Invoke-GIPipeline.ps1 -Stage Rollback -PoolName PRD-W11 -RunId 20261124-213005
.NOTES
  Exit codes: 0 ok, 1 failed, 3 PostCheck not finished yet or pipeline busy (try again later).
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Preflight', 'Maintain', 'Snapshot', 'TestPush', 'Validate', 'PostCheck', 'Rollback', 'Status')]
    [string] $Stage = 'All',
    [ValidatePattern('^\d{8}-\d{6}$')] [string] $RunId,
    [string] $ConfigPath,
    [string] $PoolName,
    [string] $SnapshotName,
    [switch] $ForceLogoff,
    [ValidateSet('Preflight', 'Maintain', 'Snapshot', 'TestPush', 'Validate')] [string] $FromStage,
    [ValidatePattern('^[A-Za-z]+(:[A-Za-z]+)?$')] [string] $FromStep,
    [switch] $FromRequest
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'VDI-GIPipeline.psd1') -Force
$config = if ($ConfigPath) { Get-GIConfig -Path $ConfigPath } else { Get-GIConfig }

if ($Stage -eq 'Status') {
    Get-GIRunList -Config $config -Last 10 |
        Select-Object runId, goldenVm, status, currentStage, progress, updatedAt | Format-Table -AutoSize | Out-Host
    exit 0
}

$requestedBy = "$env:USERDOMAIN\$env:USERNAME"
if ($FromRequest -and -not (Get-GIPendingRunRequest -Config $config)) { Write-Host 'No queued request.'; exit 0 }

# Take the lock before consuming a queued request, so a busy pipeline leaves the request queued
$lockStage = if ($FromRequest) { 'Request' } elseif ($FromStage) { "From$FromStage" } else { $Stage }
try {
    Enter-GIPipelineLock -Config $config -Stage $lockStage -RunId $RunId -RequestedBy $requestedBy
} catch {
    Write-Warning $_.Exception.Message
    # Busy is normal for the hourly PostCheck while a long run is going; for anything else it's an error
    exit $(if ($Stage -eq 'PostCheck' -and -not $FromRequest) { 3 } else { 1 })
}

if ($FromRequest) {
    try {
        $req = Read-GIRunRequest -Config $config
    } catch {
        Exit-GIPipelineLock -Config $config
        Write-Error "Queued request rejected: $($_.Exception.Message)" -ErrorAction Continue
        exit 1
    }
    if (-not $req) { Exit-GIPipelineLock -Config $config; Write-Host 'No queued request.'; exit 0 }
    $requestedBy = [string]$req.requestedBy
    switch ($req.action) {
        'All'       { $Stage = 'All' }
        'FromStage' { $FromStage = $req.stage; $RunId = $req.runId; if ($req.PSObject.Properties['step'] -and $req.step) { $FromStep = [string]$req.step } }
        'Stage'     { $Stage = $req.stage; $RunId = $req.runId; if ($req.PSObject.Properties['step'] -and $req.step) { $FromStep = [string]$req.step } }
        'PostCheck' { $Stage = 'PostCheck' }
        'Rollback'  { $Stage = 'Rollback'; $PoolName = $req.pool; $SnapshotName = $req.snapshotName; $ForceLogoff = [bool]$req.forceLogoff }
    }
    $lockStage = if ($FromStage) { "From$FromStage" } else { $Stage }
    Set-GIPipelineLockInfo -Config $config -Stage $lockStage -RunId $RunId -RequestedBy $requestedBy
    Write-Host "Running queued request $($req.id): $($req.action) from $requestedBy"
}
if ($FromStage -and -not $RunId) { Exit-GIPipelineLock -Config $config; throw '-FromStage needs -RunId.' }
if ($FromStep -and -not ($FromStage -eq 'Maintain' -or (-not $FromStage -and $Stage -eq 'Maintain'))) {
    Exit-GIPipelineLock -Config $config; throw '-FromStep only works with -FromStage Maintain or -Stage Maintain.'
}

function Resolve-Run {
    if ($RunId) { return Get-GIRun -Config $config -RunId $RunId }
    $latest = Get-GIRunList -Config $config -Last 1
    if (-not $latest) { throw 'No runs found; start one with -Stage All.' }
    return $latest
}

$run = $null
$exit = 0
try {
    if ($Stage -eq 'Rollback') {
        if (-not $PoolName) { throw '-PoolName is required for Rollback.' }
        Connect-GIServices -Config $config -SkipAppVolumes
        $r = Invoke-GIRollback -Config $config -PoolName $PoolName -SnapshotName $SnapshotName -ForceLogoff:$ForceLogoff -RunId $RunId
        $r | Format-List | Out-Host
    }
    elseif ($Stage -eq 'PostCheck') {
        # Check every Scheduled run (normally one); PostCheck sends its own reports
        $scheduled = @(Get-GIRunList -Config $config | Where-Object status -eq 'Scheduled')
        if ($RunId) { $scheduled = @(Resolve-Run) }
        if (-not $scheduled) {
            Write-Host 'No scheduled runs to check.'
        } else {
            Connect-GIServices -Config $config -SkipAppVolumes
            foreach ($r in $scheduled) {
                if (-not (Invoke-GIStagePostCheck -Config $config -Run $r)) { $exit = 3 }
            }
        }
    }
    else {
        $all = @('Preflight', 'Maintain', 'Snapshot', 'TestPush', 'Validate')
        $stages = if ($FromStage) { $all[$all.IndexOf($FromStage)..($all.Count - 1)] }
                  elseif ($Stage -eq 'All') { $all }
                  else { @($Stage) }
        $run = if ($Stage -eq 'All' -and -not $FromStage) { New-GIRun -Config $config } else { Resolve-Run }
        if ($run.status -in 'Scheduled', 'Completed', 'RolledBack') { throw "Run $($run.runId) is $($run.status); start a new run instead." }
        $run.goldenVm = $config.GoldenImage.VmName
        Update-GIPipelineLock -Config $config -RunId $run.runId
        Write-GILog -Config $config -RunId $run.runId -Message "Pipeline $lockStage started by $requestedBy (stages: $($stages -join ', '))"
        Connect-GIServices -Config $config -SkipAppVolumes:($stages -notcontains 'Validate')

        foreach ($s in $stages) {
            # Literal scriptblock stays bound to this script's scope ($config/$run); closure captures $s
            $stageArgs = @{ Config = $config; Run = $run }
            if ($s -eq 'Maintain' -and $FromStep) { $stageArgs.FromStep = $FromStep }
            $action = { & "Invoke-GIStage$s" @stageArgs }.GetNewClosure()
            Invoke-GIStage -Config $config -Run $run -Stage $s -Action $action
        }
        if ($stages -contains 'Validate') { $run = Enter-GIApprovalGate -Config $config -Run $run }
    }
} catch {
    $exit = 1
    # Failures outside a stage (e.g. connecting to vCenter) still mark the run failed
    if ($run -and $run.status -notin 'Failed', 'Rejected', 'Completed', 'RolledBack') {
        $run.status = 'Failed'
        $run.error = $_.Exception.Message
        Save-GIRun -Config $config -Run $run
    }
    Write-Error $_ -ErrorAction Continue
} finally {
    Exit-GIPipelineLock -Config $config
    Disconnect-GIServices
    if ($run) {
        Save-GIReport -Config $config -Run $run | Out-Null
        # Approve-GIRun sends its own report for auto-promotion
        if ($run.status -ne 'Scheduled') { Send-GIReport -Config $config -Run $run }
    }
}
exit $exit
