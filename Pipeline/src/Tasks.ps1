# Scheduled task registration shared by Register-GIPipelineTasks.ps1 and the /setup page.
# Definitions are plain data (testable anywhere); only Register/Unregister/Test touch ScheduledTasks.

$script:GITaskNames = 'VDI-GI-Pipeline', 'VDI-GI-PostCheck', 'VDI-GI-Dashboard', 'VDI-GI-Runner'

function Test-GIIsWindows {
    # Tiny wrapper so tests can Mock the OS check ($IsWindows can't be mocked).
    [CmdletBinding()]
    param()
    return [bool]$IsWindows
}

function Get-GIPipelineTaskName {
    <# Name of the weekly pipeline task of one golden image (VDI-GI-Pipeline-<id>); without an id the old single task. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$ImageId = '')
    if ($ImageId) { return "VDI-GI-Pipeline-$ImageId" }
    return 'VDI-GI-Pipeline'
}

function Get-GIPipelineTaskDefinition {
    <#
    .SYNOPSIS
      Returns the pipeline scheduled task definitions as plain data. Pure: no ScheduledTasks cmdlets.
    .DESCRIPTION
      Each definition: Name, Description, Script (absolute path), Arguments (script arguments, incl.
      -ConfigPath "<path>" when given), Trigger = @{ Type = Weekly|Hourly|AtStartup|None; Day; Time },
      Settings = @{ ExecutionTimeLimitHours (0 = none); RestartCount; RestartIntervalMinutes }.
      With -Config that lists golden images there is one weekly task per image, VDI-GI-Pipeline-<id> running
      -Stage All -ImageId <id> at that image's Promotion.PipelineSchedule, plus the PostCheck, Dashboard and Runner tasks.
      Without images (no -Config) it is the old single VDI-GI-Pipeline task for every image, Tuesday 20:00 unless
      -PipelineDay / -PipelineTime say otherwise. -PipelineDay / -PipelineTime override the schedule of every image.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [hashtable] $Config,
        [string] $ConfigPath,
        [System.DayOfWeek] $PipelineDay,
        [ValidatePattern('^([01]?\d|2[0-3]):[0-5]\d$')]
        [string] $PipelineTime
    )
    $rootPath = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).ProviderPath
    $pipelineScript = Join-Path $rootPath 'Invoke-GIPipeline.ps1'
    $dashboardScript = Join-Path (Join-Path $rootPath 'Web') 'Start-GIDashboard.ps1'
    foreach ($f in $pipelineScript, $dashboardScript) {
        if (-not (Test-Path -LiteralPath $f)) { throw "Script not found: $f" }
    }

    $entries = @()
    if ($Config) { try { $entries = @(Get-GIImageEntries -Config $Config) } catch { $entries = @() } }
    $day = 'Tuesday'; $time = '20:00'
    if ($Config) {
        $day = [string](Get-GIConfigValue $Config 'Promotion.PipelineSchedule.Day' 'Tuesday')
        $time = [string](Get-GIConfigValue $Config 'Promotion.PipelineSchedule.Time' '20:00')
    }
    if ($PSBoundParameters.ContainsKey('PipelineDay')) { $day = [string]$PipelineDay }
    if ($PSBoundParameters.ContainsKey('PipelineTime')) { $time = $PipelineTime }
    $day = [string][System.DayOfWeek]$day   # validates and normalizes

    $configArg = ''
    if ($ConfigPath) {
        $resolved = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).ProviderPath
        $configArg = " -ConfigPath `"$resolved`""
    }
    $mk = {
        param($Name, $Description, $Script, $ScriptArgs, $Trigger, $Settings)
        @{
            Name        = $Name
            Description = $Description
            Script      = $Script
            Arguments   = ("$ScriptArgs$configArg").Trim()
            Trigger     = $Trigger
            Settings    = $Settings
        }
    }

    $pipelineLimits = @{ ExecutionTimeLimitHours = 12; RestartCount = 0; RestartIntervalMinutes = 0 }
    $pipelineTasks = @(
        if ($entries.Count) {
            foreach ($e in $entries) {
                $id = [string]$e.Id
                if (-not (Test-GIImageId $id)) { throw "Golden image id '$id' can't be used in a task name." }
                $eDay = [string](Get-GIConfigValue $e 'Promotion.PipelineSchedule.Day' 'Tuesday')
                $eTime = [string](Get-GIConfigValue $e 'Promotion.PipelineSchedule.Time' '20:00')
                if ($PSBoundParameters.ContainsKey('PipelineDay')) { $eDay = [string]$PipelineDay }
                if ($PSBoundParameters.ContainsKey('PipelineTime')) { $eTime = $PipelineTime }
                $eDay = [string][System.DayOfWeek]$eDay
                (& $mk (Get-GIPipelineTaskName -ImageId $id) "Golden image pipeline for '$($e.Name)': maintain, snapshot, test push, validate, approval gate." `
                    $pipelineScript "-Stage All -ImageId $id" @{ Type = 'Weekly'; Day = $eDay; Time = $eTime } $pipelineLimits)
            }
        } else {
            (& $mk 'VDI-GI-Pipeline' 'Golden image pipeline: maintain, snapshot, test push, validate, approval gate.' `
                $pipelineScript '-Stage All' @{ Type = 'Weekly'; Day = $day; Time = $time } $pipelineLimits)
        }
    )
    @(
        $pipelineTasks
        (& $mk 'VDI-GI-PostCheck' 'Golden image pipeline: hourly production post-check (exit code 3 = not finished yet).' `
            $pipelineScript '-Stage PostCheck' @{ Type = 'Hourly'; Day = $null; Time = '00:00' } `
            @{ ExecutionTimeLimitHours = 1; RestartCount = 0; RestartIntervalMinutes = 0 })
        (& $mk 'VDI-GI-Dashboard' 'Golden image pipeline: Pode web dashboard.' `
            $dashboardScript '' @{ Type = 'AtStartup'; Day = $null; Time = $null } `
            @{ ExecutionTimeLimitHours = 0; RestartCount = 3; RestartIntervalMinutes = 1 })
        (& $mk 'VDI-GI-Runner' 'Golden image pipeline: runs the request queued from the dashboard. Started on demand.' `
            $pipelineScript '-FromRequest' @{ Type = 'None'; Day = $null; Time = $null } `
            @{ ExecutionTimeLimitHours = 12; RestartCount = 0; RestartIntervalMinutes = 0 })
    )
}

function Register-GIPipelineTask {
    <#
    .SYNOPSIS
      Registers the given task definitions (Windows only). Returns @{ Name; Registered = $true } per task registered.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [hashtable[]] $Definitions,
        [Parameter(Mandatory)] [pscredential] $Credential
    )
    if (-not (Test-GIIsWindows)) { throw 'Scheduled tasks can only be registered on Windows.' }
    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    $userName = $Credential.UserName
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($d in $Definitions) {
        if (-not $PSCmdlet.ShouldProcess($d.Name, "Register scheduled task as $userName")) { continue }
        $argText = "-NoProfile -ExecutionPolicy Bypass -File `"$($d.Script)`""
        if ($d.Arguments) { $argText += " $($d.Arguments)" }
        $action = New-ScheduledTaskAction -Execute $pwsh -Argument $argText -WorkingDirectory (Split-Path -Parent $d.Script)

        $trigger = $null
        switch ($d.Trigger.Type) {
            'Weekly' {
                $at = [datetime]::ParseExact($d.Trigger.Time, 'H:mm', [cultureinfo]::InvariantCulture)
                $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $d.Trigger.Day -At $at
            }
            'Hourly' {
                $at = [datetime]::ParseExact($d.Trigger.Time, 'H:mm', [cultureinfo]::InvariantCulture)
                $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.Add($at.TimeOfDay) -RepetitionInterval (New-TimeSpan -Hours 1)
            }
            'AtStartup' { $trigger = New-ScheduledTaskTrigger -AtStartup }
            default { }
        }

        $s = $d.Settings
        $settingsArgs = @{
            AllowStartIfOnBatteries    = $true
            DontStopIfGoingOnBatteries = $true
            StartWhenAvailable         = $true
            MultipleInstances          = 'IgnoreNew'
            ExecutionTimeLimit         = (New-TimeSpan -Hours $s.ExecutionTimeLimitHours)
        }
        if ($s.RestartCount -gt 0) {
            $settingsArgs.RestartCount = $s.RestartCount
            $settingsArgs.RestartInterval = (New-TimeSpan -Minutes $s.RestartIntervalMinutes)
        }
        $settings = New-ScheduledTaskSettingsSet @settingsArgs
        $principal = New-ScheduledTaskPrincipal -UserId $userName -LogonType Password -RunLevel Highest

        $taskArgs = @{ Action = $action; Settings = $settings; Principal = $principal; Description = $d.Description }
        if ($trigger) { $taskArgs.Trigger = $trigger }
        $task = New-ScheduledTask @taskArgs
        # Password is read from the credential only for this call and never stored.
        Register-ScheduledTask -TaskName $d.Name -InputObject $task -User $userName `
            -Password $Credential.GetNetworkCredential().Password -Force | Out-Null
        $results.Add(@{ Name = $d.Name; Registered = $true })
    }
    # With one task per image, the old single VDI-GI-Pipeline task (it would start every image again) and the tasks of
    # images that are gone are removed. Only when per-image tasks are part of this registration.
    if (@($Definitions | Where-Object { $_.Name -like 'VDI-GI-Pipeline-*' }).Count) {
        $keep = @($Definitions | ForEach-Object { $_.Name })
        foreach ($t in @(Get-ScheduledTask -TaskName 'VDI-GI-Pipeline*' -ErrorAction SilentlyContinue)) {
            if ($t.TaskName -in $keep -or ($t.TaskName -ne 'VDI-GI-Pipeline' -and $t.TaskName -notlike 'VDI-GI-Pipeline-*')) { continue }
            if (-not $PSCmdlet.ShouldProcess($t.TaskName, 'Unregister scheduled task (replaced by per-image tasks, or its image is gone)')) { continue }
            Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false
            $results.Add(@{ Name = $t.TaskName; Registered = $false; Removed = $true })
        }
    }
    return $results.ToArray()
}

function Unregister-GIPipelineTask {
    <#
    .SYNOPSIS
      Removes the four pipeline tasks if present (Windows only). Returns the names removed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not (Test-GIIsWindows)) { throw 'Scheduled tasks can only be removed on Windows.' }
    $removed = [System.Collections.Generic.List[string]]::new()
    $names = @($script:GITaskNames) + @(Get-ScheduledTask -TaskName 'VDI-GI-Pipeline-*' -ErrorAction SilentlyContinue | ForEach-Object { $_.TaskName })
    foreach ($name in ($names | Select-Object -Unique)) {
        if (-not (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) { continue }
        if ($PSCmdlet.ShouldProcess($name, 'Unregister scheduled task')) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
            $removed.Add($name)
        }
    }
    return $removed.ToArray()
}

function Test-GIPipelineTaskRegistered {
    <#
    .SYNOPSIS
      Returns @{ <task name> = $true/$false }. All false off Windows. With -Config the per-image pipeline tasks are listed
      too (and the old single VDI-GI-Pipeline only when no image has its own task yet).
    #>
    [CmdletBinding()]
    param([hashtable]$Config)
    $r = @{}
    $win = Test-GIIsWindows
    $names = @($script:GITaskNames)
    if ($Config) {
        $ids = @(try { Get-GIImageEntries -Config $Config | ForEach-Object { [string]$_.Id } } catch { @() })
        if ($ids.Count) { $names = @($ids | ForEach-Object { Get-GIPipelineTaskName -ImageId $_ }) + @($script:GITaskNames | Where-Object { $_ -ne 'VDI-GI-Pipeline' }) }
    }
    foreach ($name in $names) {
        $r[$name] = $win -and [bool](Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)
    }
    return $r
}

function Test-GIWindowsCredential {
    <#
    .SYNOPSIS
      Validates a username/password against the local machine or domain without side effects. Windows only.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [pscredential] $Credential)
    if (-not (Test-GIIsWindows)) { throw 'Credential validation is only available on Windows.' }
    Add-Type -AssemblyName System.DirectoryServices.AccountManagement
    $full = $Credential.UserName
    $domain = $null; $user = $full
    if ($full -match '^(?<d>[^\\]+)\\(?<u>.+)$') { $domain = $Matches.d; $user = $Matches.u }
    elseif ($full -match '^(?<u>[^@]+)@(?<d>.+)$') { $domain = $Matches.d; $user = $Matches.u }
    $useDomain = $domain -and $domain -ne '.' -and ($domain -ne $env:COMPUTERNAME)
    $type = if ($useDomain) { [System.DirectoryServices.AccountManagement.ContextType]::Domain } else { [System.DirectoryServices.AccountManagement.ContextType]::Machine }
    $ctx = if ($useDomain) {
        [System.DirectoryServices.AccountManagement.PrincipalContext]::new($type, $domain)
    } else {
        [System.DirectoryServices.AccountManagement.PrincipalContext]::new($type, $env:COMPUTERNAME)
    }
    try {
        return [bool]$ctx.ValidateCredentials($user, $Credential.GetNetworkCredential().Password)
    } finally {
        $ctx.Dispose()
    }
}
