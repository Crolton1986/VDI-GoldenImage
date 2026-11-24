<#
.SYNOPSIS
  Golden image pipeline entry point (run on the management server, PowerShell 7 + VMware PowerCLI).
.DESCRIPTION
  -Stage All        new run: Preflight, Maintain, Snapshot, TestPush, Validate, then the approval gate
  -Stage <name>     re-run one stage of an existing run (-RunId, default: newest run)
  -Stage PostCheck  check production after the maintenance window (schedule this; safe to run repeatedly)
  -Stage Rollback   push the last-known-good snapshot (or -SnapshotName) to -PoolName
  -Stage Status     print the newest runs
.EXAMPLE
  PS> .\Invoke-GIPipeline.ps1 -Stage All
.EXAMPLE
  PS> .\Invoke-GIPipeline.ps1 -Stage Validate -RunId 20261124-213005
.EXAMPLE
  PS> .\Invoke-GIPipeline.ps1 -Stage Rollback -PoolName PRD-W11 -RunId 20261124-213005
.NOTES
  Exit codes: 0 ok, 1 failed, 3 PostCheck not finished yet (try again later).
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Preflight', 'Maintain', 'Snapshot', 'TestPush', 'Validate', 'PostCheck', 'Rollback', 'Status')]
    [string] $Stage = 'All',
    [ValidatePattern('^\d{8}-\d{6}$')] [string] $RunId,
    [string] $ConfigPath,
    [string] $PoolName,
    [string] $SnapshotName,
    [switch] $ForceLogoff
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'VDI-GIPipeline.psd1') -Force
$config = if ($ConfigPath) { Get-GIConfig -Path $ConfigPath } else { Get-GIConfig }

if ($Stage -eq 'Status') {
    Get-GIRunList -Config $config -Last 10 |
        Select-Object runId, goldenVm, status, currentStage, progress, updatedAt | Format-Table -AutoSize | Out-Host
    exit 0
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
        exit 0
    }

    if ($Stage -eq 'PostCheck') {
        # Check every Scheduled run (normally one)
        $scheduled = @(Get-GIRunList -Config $config | Where-Object status -eq 'Scheduled')
        if ($RunId) { $scheduled = @(Resolve-Run) }
        if (-not $scheduled) { Write-Host 'No scheduled runs to check.'; exit 0 }
        Connect-GIServices -Config $config -SkipAppVolumes
        foreach ($run in $scheduled) {
            if (-not (Invoke-GIStagePostCheck -Config $config -Run $run)) { $exit = 3 }
        }
        exit $exit
    }

    $run = if ($Stage -eq 'All') { New-GIRun -Config $config } else { Resolve-Run }
    $run.goldenVm = $config.GoldenImage.VmName
    Write-GILog -Config $config -RunId $run.runId -Message "Pipeline $Stage started (run $($run.runId))"
    Connect-GIServices -Config $config -SkipAppVolumes:($Stage -notin 'All', 'Validate')

    $stages = if ($Stage -eq 'All') { @('Preflight', 'Maintain', 'Snapshot', 'TestPush', 'Validate') } else { @($Stage) }
    foreach ($s in $stages) {
        # Literal scriptblock stays bound to this script's scope ($config/$run); closure captures $s
        $action = { & "Invoke-GIStage$s" -Config $config -Run $run }.GetNewClosure()
        Invoke-GIStage -Config $config -Run $run -Stage $s -Action $action
    }
    if ($stages -contains 'Validate') { $run = Enter-GIApprovalGate -Config $config -Run $run }
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
    Disconnect-GIServices
    if ($run) {
        Save-GIReport -Config $config -Run $run | Out-Null
        # Approve-GIRun sends its own report for auto-promotion
        if ($run.status -ne 'Scheduled') { Send-GIReport -Config $config -Run $run }
    }
}
exit $exit
