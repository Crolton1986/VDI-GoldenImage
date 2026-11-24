#Requires -Version 7.2
<#
.SYNOPSIS
  Registers (or removes) the Windows scheduled tasks that run the golden image pipeline.
.DESCRIPTION
  Creates four tasks on the management server. All run pwsh.exe under the account passed in
  -Credential (default: prompts for the CURRENT user), whether or not the user is logged on, with
  highest privileges. The task definitions live in src/Tasks.ps1 and are shared with the /setup page.

    VDI-GI-Pipeline   Invoke-GIPipeline.ps1 -Stage All, weekly (-PipelineDay / -PipelineTime)
    VDI-GI-PostCheck  Invoke-GIPipeline.ps1 -Stage PostCheck, every hour. Exit code 3 means
                      "not finished yet", which is expected until the push completes.
    VDI-GI-Dashboard  Web\Start-GIDashboard.ps1 at system startup, restarted on failure
                      (3 times, 1 minute apart), no execution time limit.
    VDI-GI-Runner     Invoke-GIPipeline.ps1 -FromRequest, no trigger. The dashboard queues a
                      request and starts this task (Go, retry, single stage, PostCheck, rollback).

  The dashboard runs as the same account, so it can start VDI-GI-Runner and update the weekly
  trigger of VDI-GI-Pipeline from the Schedule settings page.

  Re-running the script updates existing tasks. Needs Windows, PowerShell 7 and an elevated session.
.PARAMETER Credential
  Account that runs the tasks. Optional: when omitted you are prompted for the CURRENT user
  (Get-Credential -UserName "$env:USERDOMAIN\$env:USERNAME"). It needs the SecretStore vault set up
  for non-interactive use.
.PARAMETER ConfigPath
  Optional pipeline config file, passed to every task.
.PARAMETER PipelineDay
  Day of the week for the full pipeline run (default Tuesday).
.PARAMETER PipelineTime
  Time of day (HH:mm) for the full pipeline run (default 20:00).
.PARAMETER Unregister
  Removes the four tasks instead of registering them.
.EXAMPLE
  PS> .\Register-GIPipelineTasks.ps1 -Credential (Get-Credential DOMAIN\svc-vdi-gi) -WhatIf
.EXAMPLE
  PS> .\Register-GIPipelineTasks.ps1 -Credential $cred -PipelineDay Wednesday -PipelineTime 21:30
.EXAMPLE
  PS> .\Register-GIPipelineTasks.ps1 -Unregister
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Register')]
param(
    [Parameter(ParameterSetName = 'Register')]
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

Import-Module (Join-Path $PSScriptRoot 'VDI-GIPipeline.psd1') -Force

if ($Unregister) {
    foreach ($name in (Unregister-GIPipelineTask -WhatIf:$WhatIfPreference)) { Write-Host "Removed task $name." }
    return
}

if (-not $Credential) {
    $Credential = Get-Credential -UserName "$env:USERDOMAIN\$env:USERNAME" -Message 'Account that runs the pipeline tasks'
    if (-not $Credential) { throw 'A credential is required.' }
}

$defArgs = @{ Root = $PSScriptRoot; PipelineDay = $PipelineDay; PipelineTime = $PipelineTime }
if ($ConfigPath) { $defArgs.ConfigPath = $ConfigPath }
$definitions = Get-GIPipelineTaskDefinition @defArgs

foreach ($r in (Register-GIPipelineTask -Definitions $definitions -Credential $Credential -WhatIf:$WhatIfPreference)) {
    Write-Host "Registered task $($r.Name)."
}
