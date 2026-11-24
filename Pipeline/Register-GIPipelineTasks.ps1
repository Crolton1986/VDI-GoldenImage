#Requires -Version 7.2
<#
.SYNOPSIS
  Registers (or removes) the Windows scheduled tasks that run the golden image pipeline.
.DESCRIPTION
  Creates three tasks on the management server. All run pwsh.exe under the service account
  passed in -Credential, whether or not the user is logged on, with highest privileges.

    VDI-GI-Pipeline   Invoke-GIPipeline.ps1 -Stage All, weekly (-PipelineDay / -PipelineTime)
    VDI-GI-PostCheck  Invoke-GIPipeline.ps1 -Stage PostCheck, every hour. Exit code 3 means
                      "not finished yet", which is expected until the push completes.
    VDI-GI-Dashboard  Web\Start-GIDashboard.ps1 at system startup, restarted on failure
                      (3 times, 1 minute apart), no execution time limit.

  Re-running the script updates existing tasks. Needs Windows, PowerShell 7 and an elevated session.
.PARAMETER Credential
  Service account that runs the tasks. It needs the SecretStore vault set up for non-interactive use.
.PARAMETER ConfigPath
  Optional pipeline config file, passed to every task.
.PARAMETER PipelineDay
  Day of the week for the full pipeline run (default Tuesday).
.PARAMETER PipelineTime
  Time of day (HH:mm) for the full pipeline run (default 20:00).
.PARAMETER Unregister
  Removes the three tasks instead of registering them.
.EXAMPLE
  PS> .\Register-GIPipelineTasks.ps1 -Credential (Get-Credential DOMAIN\svc-vdi-gi) -WhatIf
.EXAMPLE
  PS> .\Register-GIPipelineTasks.ps1 -Credential $cred -PipelineDay Wednesday -PipelineTime 21:30
.EXAMPLE
  PS> .\Register-GIPipelineTasks.ps1 -Unregister
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Register')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Register')]
    [pscredential] $Credential,

    [string] $ConfigPath,

    [Parameter(ParameterSetName = 'Register')]
    [System.DayOfWeek] $PipelineDay = 'Tuesday',

    [Parameter(ParameterSetName = 'Register')]
    [ValidatePattern('^([01]?\d|2[0-3]):[0-5]\d$')]
    [string] $PipelineTime = '20:00',

    [Parameter(Mandatory, ParameterSetName = 'Unregister')]
    [switch] $Unregister
)

$ErrorActionPreference = 'Stop'

if (-not $IsWindows) { throw 'Scheduled tasks can only be registered on Windows.' }
$principalCheck = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principalCheck.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated (Run as administrator) PowerShell session.'
}

$taskNames = 'VDI-GI-Pipeline', 'VDI-GI-PostCheck', 'VDI-GI-Dashboard'

if ($Unregister) {
    foreach ($name in $taskNames) {
        if (-not (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) {
            Write-Host "Task $name not found, skipping."
            continue
        }
        if ($PSCmdlet.ShouldProcess($name, 'Unregister scheduled task')) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
            Write-Host "Removed task $name."
        }
    }
    return
}

$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
$pipelineScript = Join-Path $PSScriptRoot 'Invoke-GIPipeline.ps1'
$dashboardScript = Join-Path $PSScriptRoot 'Web\Start-GIDashboard.ps1'
foreach ($f in $pipelineScript, $dashboardScript) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Script not found: $f" }
}

$configArg = ''
if ($ConfigPath) {
    $resolved = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).ProviderPath
    $configArg = " -ConfigPath `"$resolved`""
}

function New-GITaskAction {
    param([string] $ScriptPath, [string] $ScriptArgs)
    $argText = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    if ($ScriptArgs) { $argText += " $ScriptArgs" }
    if ($configArg) { $argText += $configArg }
    New-ScheduledTaskAction -Execute $pwsh -Argument $argText -WorkingDirectory $PSScriptRoot
}

$userName = $Credential.UserName
$password = $Credential.GetNetworkCredential().Password
$principal = New-ScheduledTaskPrincipal -UserId $userName -LogonType Password -RunLevel Highest

$baseSettings = @{
    AllowStartIfOnBatteries    = $true
    DontStopIfGoingOnBatteries = $true
    StartWhenAvailable         = $true
}

$definitions = @(
    @{
        Name        = 'VDI-GI-Pipeline'
        Description = 'Golden image pipeline: maintain, snapshot, test push, validate, approval gate.'
        Action      = New-GITaskAction -ScriptPath $pipelineScript -ScriptArgs '-Stage All'
        Trigger     = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $PipelineDay -At $PipelineTime
        Settings    = New-ScheduledTaskSettingsSet @baseSettings -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 12)
    }
    @{
        Name        = 'VDI-GI-PostCheck'
        Description = 'Golden image pipeline: hourly production post-check (exit code 3 = not finished yet).'
        Action      = New-GITaskAction -ScriptPath $pipelineScript -ScriptArgs '-Stage PostCheck'
        Trigger     = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Hours 1)
        Settings    = New-ScheduledTaskSettingsSet @baseSettings -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    }
    @{
        Name        = 'VDI-GI-Dashboard'
        Description = 'Golden image pipeline: Pode web dashboard.'
        Action      = New-GITaskAction -ScriptPath $dashboardScript -ScriptArgs ''
        Trigger     = New-ScheduledTaskTrigger -AtStartup
        Settings    = New-ScheduledTaskSettingsSet @baseSettings -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    }
)

foreach ($d in $definitions) {
    if ($PSCmdlet.ShouldProcess($d.Name, "Register scheduled task as $userName")) {
        $task = New-ScheduledTask -Action $d.Action -Trigger $d.Trigger -Settings $d.Settings -Principal $principal -Description $d.Description
        Register-ScheduledTask -TaskName $d.Name -InputObject $task -User $userName -Password $password -Force | Out-Null
        Write-Host "Registered task $($d.Name)."
    }
}
