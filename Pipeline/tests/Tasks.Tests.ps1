BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'VDI-GIPipeline.psd1') -Force
    $script:root = Join-Path ([IO.Path]::GetTempPath()) "gi-tasks-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path (Join-Path $script:root 'Web') -Force | Out-Null
    Set-Content (Join-Path $script:root 'Invoke-GIPipeline.ps1') '# stub'
    Set-Content (Join-Path $script:root 'Web' 'Start-GIDashboard.ps1') '# stub'
    $script:cfgFile = Join-Path $script:root 'my config.psd1'
    Set-Content $script:cfgFile '@{}'
    $script:secret = 'Sup3r-Secret-PW!'
    $script:cred = [pscredential]::new('LAB\svc', (ConvertTo-SecureString $script:secret -AsPlainText -Force))
}

AfterAll {
    Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Get-GIPipelineTaskDefinition' {
    BeforeAll {
        $script:defs = Get-GIPipelineTaskDefinition -Root $script:root
        function script:By($n) { $script:defs | Where-Object { $_.Name -eq $n } }
    }

    It 'returns the four tasks in order' {
        $script:defs.Name | Should -Be @('VDI-GI-Pipeline', 'VDI-GI-PostCheck', 'VDI-GI-Dashboard', 'VDI-GI-Runner')
    }

    It 'uses absolute script paths' {
        (By 'VDI-GI-Pipeline').Script | Should -Be (Join-Path $script:root 'Invoke-GIPipeline.ps1')
        (By 'VDI-GI-Dashboard').Script | Should -Be (Join-Path (Join-Path $script:root 'Web') 'Start-GIDashboard.ps1')
        foreach ($d in $script:defs) { [IO.Path]::IsPathRooted($d.Script) | Should -BeTrue }
    }

    It 'has the expected arguments' {
        (By 'VDI-GI-Pipeline').Arguments | Should -Be '-Stage All'
        (By 'VDI-GI-PostCheck').Arguments | Should -Be '-Stage PostCheck'
        (By 'VDI-GI-Dashboard').Arguments | Should -Be ''
        (By 'VDI-GI-Runner').Arguments | Should -Be '-FromRequest'
    }

    It 'has the expected triggers' {
        $p = (By 'VDI-GI-Pipeline').Trigger
        $p.Type | Should -Be 'Weekly'; $p.Day | Should -Be 'Tuesday'; $p.Time | Should -Be '20:00'
        (By 'VDI-GI-PostCheck').Trigger.Type | Should -Be 'Hourly'
        (By 'VDI-GI-Dashboard').Trigger.Type | Should -Be 'AtStartup'
        (By 'VDI-GI-Runner').Trigger.Type | Should -Be 'None'
    }

    It 'has the expected limits and restart settings' {
        (By 'VDI-GI-Pipeline').Settings.ExecutionTimeLimitHours | Should -Be 12
        (By 'VDI-GI-PostCheck').Settings.ExecutionTimeLimitHours | Should -Be 1
        (By 'VDI-GI-Runner').Settings.ExecutionTimeLimitHours | Should -Be 12
        $d = (By 'VDI-GI-Dashboard').Settings
        $d.ExecutionTimeLimitHours | Should -Be 0
        $d.RestartCount | Should -Be 3
        $d.RestartIntervalMinutes | Should -Be 1
        (By 'VDI-GI-Pipeline').Settings.RestartCount | Should -Be 0
    }

    It 'appends the quoted resolved ConfigPath to every task' {
        $r = Get-GIPipelineTaskDefinition -Root $script:root -ConfigPath $script:cfgFile
        foreach ($d in $r) { $d.Arguments | Should -BeLike "*-ConfigPath `"$script:cfgFile`"" }
        ($r | Where-Object Name -eq 'VDI-GI-Pipeline').Arguments | Should -Be "-Stage All -ConfigPath `"$script:cfgFile`""
        ($r | Where-Object Name -eq 'VDI-GI-Dashboard').Arguments | Should -Be "-ConfigPath `"$script:cfgFile`""
    }

    It 'throws for a missing ConfigPath or missing scripts' {
        { Get-GIPipelineTaskDefinition -Root $script:root -ConfigPath (Join-Path $script:root 'nope.psd1') } | Should -Throw
        $empty = Join-Path $script:root 'empty'; New-Item -ItemType Directory $empty | Out-Null
        { Get-GIPipelineTaskDefinition -Root $empty } | Should -Throw '*Script not found*'
    }

    It 'reads the schedule from config' {
        $cfg = @{ Promotion = @{ PipelineSchedule = @{ Day = 'Friday'; Time = '03:15' } } }
        $p = (Get-GIPipelineTaskDefinition -Root $script:root -Config $cfg | Where-Object Name -eq 'VDI-GI-Pipeline').Trigger
        $p.Day | Should -Be 'Friday'; $p.Time | Should -Be '03:15'
    }

    It 'falls back to defaults for a config without a schedule' {
        $p = (Get-GIPipelineTaskDefinition -Root $script:root -Config @{} | Where-Object Name -eq 'VDI-GI-Pipeline').Trigger
        $p.Day | Should -Be 'Tuesday'; $p.Time | Should -Be '20:00'
    }

    It 'explicit PipelineDay/PipelineTime override config' {
        $cfg = @{ Promotion = @{ PipelineSchedule = @{ Day = 'Friday'; Time = '03:15' } } }
        $p = (Get-GIPipelineTaskDefinition -Root $script:root -Config $cfg -PipelineDay Wednesday -PipelineTime 21:30 |
            Where-Object Name -eq 'VDI-GI-Pipeline').Trigger
        $p.Day | Should -Be 'Wednesday'; $p.Time | Should -Be '21:30'
    }

    It 'rejects a bad time' {
        { Get-GIPipelineTaskDefinition -Root $script:root -PipelineTime '25:00' } | Should -Throw
    }
}

Describe 'Windows-only functions off Windows' {
    BeforeEach {
        Mock -ModuleName VDI-GIPipeline Test-GIIsWindows { $false }
    }
    It 'Register-GIPipelineTask throws' {
        $defs = Get-GIPipelineTaskDefinition -Root $script:root
        { Register-GIPipelineTask -Definitions $defs -Credential $script:cred } | Should -Throw '*Windows*'
    }
    It 'Unregister-GIPipelineTask throws' {
        { Unregister-GIPipelineTask } | Should -Throw '*Windows*'
    }
    It 'Test-GIWindowsCredential throws' {
        { Test-GIWindowsCredential -Credential $script:cred } | Should -Throw '*Windows*'
    }
    It 'Test-GIPipelineTaskRegistered reports all false' {
        $r = Test-GIPipelineTaskRegistered
        $r.Keys.Count | Should -Be 4
        foreach ($k in $r.Keys) { $r[$k] | Should -BeFalse }
    }
}

Describe 'Register / Unregister with stubbed ScheduledTasks cmdlets' {
    BeforeAll {
        InModuleScope VDI-GIPipeline {
            function script:New-ScheduledTaskAction { param($Execute, $Argument, $WorkingDirectory) [pscustomobject]@{ Kind = 'Action'; Execute = $Execute; Argument = $Argument; WorkingDirectory = $WorkingDirectory } }
            function script:New-ScheduledTaskTrigger { param([switch]$Weekly, [switch]$Once, [switch]$AtStartup, $DaysOfWeek, $At, $RepetitionInterval) [pscustomobject]@{ Kind = 'Trigger' } }
            function script:New-ScheduledTaskSettingsSet { param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, [switch]$StartWhenAvailable, $MultipleInstances, $ExecutionTimeLimit, $RestartCount, $RestartInterval) [pscustomobject]@{ Kind = 'Settings' } }
            function script:New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) [pscustomobject]@{ Kind = 'Principal'; UserId = $UserId } }
            function script:New-ScheduledTask { param($Action, $Trigger, $Settings, $Principal, $Description) [pscustomobject]@{ Kind = 'Task'; Trigger = $Trigger } }
            function script:Register-ScheduledTask { param($TaskName, $InputObject, $User, $Password, [switch]$Force) }
            function script:Get-ScheduledTask { param($TaskName, $ErrorAction) }
            function script:Unregister-ScheduledTask { param($TaskName, $Confirm) }
        }
        $script:defs = Get-GIPipelineTaskDefinition -Root $script:root
    }
    BeforeEach {
        Mock -ModuleName VDI-GIPipeline Test-GIIsWindows { $true }
        Mock -ModuleName VDI-GIPipeline Get-Command { [pscustomobject]@{ Source = 'C:\pwsh\pwsh.exe' } } -ParameterFilter { $Name -eq 'pwsh' }
        Mock -ModuleName VDI-GIPipeline Register-ScheduledTask { }
    }

    It 'registers four tasks as the credential user with the password' {
        $r = @(Register-GIPipelineTask -Definitions $script:defs -Credential $script:cred)
        $r.Count | Should -Be 4
        ($r | ForEach-Object { $_.Name }) | Should -Be @("VDI-GI-Pipeline","VDI-GI-PostCheck","VDI-GI-Dashboard","VDI-GI-Runner")
        Should -Invoke -ModuleName VDI-GIPipeline Register-ScheduledTask -Times 4 -Exactly -ParameterFilter {
            $User -eq 'LAB\svc' -and $Password -eq 'Sup3r-Secret-PW!' -and $Force
        }
    }

    It 'builds the action with pwsh, args and working directory' {
        Mock -ModuleName VDI-GIPipeline New-ScheduledTaskAction { [pscustomobject]@{ Execute = $Execute; Argument = $Argument; WorkingDirectory = $WorkingDirectory } }
        Register-GIPipelineTask -Definitions $script:defs -Credential $script:cred | Out-Null
        Should -Invoke -ModuleName VDI-GIPipeline New-ScheduledTaskAction -Times 1 -Exactly -ParameterFilter {
            $Execute -eq 'C:\pwsh\pwsh.exe' -and $WorkingDirectory -eq $script:root -and
            $Argument -eq "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $script:root 'Invoke-GIPipeline.ps1')`" -FromRequest"
        }
    }

    It 'gives the Runner no trigger' {
        Mock -ModuleName VDI-GIPipeline New-ScheduledTask { [pscustomobject]@{ HasTrigger = $PSBoundParameters.ContainsKey('Trigger') } }
        Register-GIPipelineTask -Definitions $script:defs -Credential $script:cred | Out-Null
        Should -Invoke -ModuleName VDI-GIPipeline New-ScheduledTask -Times 3 -Exactly -ParameterFilter { $null -ne $Trigger }
        Should -Invoke -ModuleName VDI-GIPipeline New-ScheduledTask -Times 1 -Exactly -ParameterFilter { $null -eq $Trigger }
    }

    It 'passes restart settings only for the dashboard' {
        Mock -ModuleName VDI-GIPipeline New-ScheduledTaskSettingsSet { [pscustomobject]@{} }
        Register-GIPipelineTask -Definitions $script:defs -Credential $script:cred | Out-Null
        Should -Invoke -ModuleName VDI-GIPipeline New-ScheduledTaskSettingsSet -Times 1 -Exactly -ParameterFilter { $RestartCount -eq 3 -and $ExecutionTimeLimit -eq [TimeSpan]::Zero }
        Should -Invoke -ModuleName VDI-GIPipeline New-ScheduledTaskSettingsSet -Times 4 -Exactly -ParameterFilter { $MultipleInstances -eq 'IgnoreNew' }
    }

    It '-WhatIf registers nothing' {
        $r = Register-GIPipelineTask -Definitions $script:defs -Credential $script:cred -WhatIf
        @($r).Count | Should -Be 0
        Should -Invoke -ModuleName VDI-GIPipeline Register-ScheduledTask -Times 0 -Exactly
    }

    It 'never exposes the plain password in definitions or results' {
        $r = @(Register-GIPipelineTask -Definitions $script:defs -Credential $script:cred)
        ($script:defs | ConvertTo-Json -Depth 6) | Should -Not -BeLike "*$script:secret*"
        ($r | ConvertTo-Json -Depth 6) | Should -Not -BeLike "*$script:secret*"
    }

    It 'Unregister removes only tasks that exist' {
        Mock -ModuleName VDI-GIPipeline Get-ScheduledTask { if ($TaskName -in 'VDI-GI-Pipeline', 'VDI-GI-Runner') { [pscustomobject]@{ TaskName = $TaskName } } }
        Mock -ModuleName VDI-GIPipeline Unregister-ScheduledTask { }
        @(Unregister-GIPipelineTask) | Should -Be @('VDI-GI-Pipeline', 'VDI-GI-Runner')
        Should -Invoke -ModuleName VDI-GIPipeline Unregister-ScheduledTask -Times 2 -Exactly
        Unregister-GIPipelineTask -WhatIf | Should -BeNullOrEmpty
        Should -Invoke -ModuleName VDI-GIPipeline Unregister-ScheduledTask -Times 2 -Exactly
    }

    It 'Test-GIPipelineTaskRegistered reflects Get-ScheduledTask' {
        Mock -ModuleName VDI-GIPipeline Get-ScheduledTask { if ($TaskName -eq 'VDI-GI-Dashboard') { [pscustomobject]@{ TaskName = $TaskName } } }
        $r = Test-GIPipelineTaskRegistered
        $r['VDI-GI-Dashboard'] | Should -BeTrue
        $r['VDI-GI-Pipeline'] | Should -BeFalse
    }
}

Describe 'One weekly task per golden image' {
    BeforeAll {
        function script:New-ImgCfg([string[]]$Ids = @('w11-corp', 'win10-lab')) {
            $c = Join-Path ([IO.Path]::GetTempPath()) ("gi-taskimg-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory $c | Out-Null
            Copy-Item (Join-Path $PSScriptRoot '..' 'pipeline.config.psd1') $c
            $cfg = Get-GIConfig -Path (Join-Path $c 'pipeline.config.psd1')
            $null = Invoke-GIConfigMigration -Config $cfg -InformationAction SilentlyContinue
            $list = @($Ids | ForEach-Object { $n = $_; @{ Id = $n; Name = "Image $n"; Paused = $false
                        GoldenImage = @{ VmName = "VM-$n" }; Pools = @{ Test = @{ Name = "T-$n"; LogoffPolicy = 'FORCE_LOGOFF' }; Production = @(@{ Name = "P-$n"; LogoffPolicy = 'WAIT_FOR_LOGOFF' }) }
                        Promotion = @{ PipelineSchedule = @{ Day = $(if ($n -like 'w11*') { 'Friday' } else { 'Sunday' }); Time = $(if ($n -like 'w11*') { '03:15' } else { '21:00' }) } } } })
            Write-GIImageOverlayList -Config $cfg -List $list
            $script:imgRoot = $c
            Get-GIConfig -Path (Join-Path $c 'pipeline.config.psd1')
        }
    }
    AfterAll { if ($script:imgRoot) { Remove-Item $script:imgRoot -Recurse -Force -ErrorAction SilentlyContinue } }

    It 'names the task after the image' {
        Get-GIPipelineTaskName -ImageId 'w11-corp' | Should -Be 'VDI-GI-Pipeline-w11-corp'
        Get-GIPipelineTaskName | Should -Be 'VDI-GI-Pipeline'
    }
    It 'creates a Pipeline task per image with -ImageId and that image''s own schedule, then the shared tasks' {
        $cfg = New-ImgCfg
        $d = Get-GIPipelineTaskDefinition -Root $script:root -Config $cfg
        $d.Name | Should -Be @('VDI-GI-Pipeline-w11-corp', 'VDI-GI-Pipeline-win10-lab', 'VDI-GI-PostCheck', 'VDI-GI-Dashboard', 'VDI-GI-Runner')
        $a = $d | Where-Object Name -eq 'VDI-GI-Pipeline-w11-corp'
        $a.Arguments | Should -Be '-Stage All -ImageId w11-corp'
        $a.Trigger.Type | Should -Be 'Weekly'; $a.Trigger.Day | Should -Be 'Friday'; $a.Trigger.Time | Should -Be '03:15'
        $a.Description | Should -Match "Image w11-corp"
        $b = $d | Where-Object Name -eq 'VDI-GI-Pipeline-win10-lab'
        $b.Trigger.Day | Should -Be 'Sunday'; $b.Trigger.Time | Should -Be '21:00'
        $a.Settings.ExecutionTimeLimitHours | Should -Be 12
        ($d | Where-Object Name -eq 'VDI-GI-Pipeline') | Should -BeNullOrEmpty   # the old all-images task is not defined any more
    }
    It 'appends the ConfigPath to every task, and lets PipelineDay / PipelineTime override every image' {
        $cfg = New-ImgCfg
        $d = Get-GIPipelineTaskDefinition -Root $script:root -Config $cfg -ConfigPath $script:cfgFile -PipelineDay Wednesday -PipelineTime 22:30
        ($d | Where-Object Name -eq 'VDI-GI-Pipeline-w11-corp').Arguments | Should -Be "-Stage All -ImageId w11-corp -ConfigPath `"$script:cfgFile`""
        foreach ($n in 'VDI-GI-Pipeline-w11-corp', 'VDI-GI-Pipeline-win10-lab') { $t = ($d | Where-Object Name -eq $n).Trigger; $t.Day | Should -Be 'Wednesday'; $t.Time | Should -Be '22:30' }
    }
    It 'keeps a paused image''s task (the pipeline script skips it)' {
        $cfg = New-ImgCfg @('only-one')
        @(Get-GIPipelineTaskDefinition -Root $script:root -Config $cfg | Where-Object Name -like 'VDI-GI-Pipeline-*').Count | Should -Be 1
    }
    It 'lists per-image tasks in Test-GIPipelineTaskRegistered when given the config' {
        $cfg = New-ImgCfg
        Mock -ModuleName VDI-GIPipeline Test-GIIsWindows { $false }
        $r = Test-GIPipelineTaskRegistered -Config $cfg
        @($r.Keys | Sort-Object) | Should -Be @('VDI-GI-Dashboard', 'VDI-GI-PostCheck', 'VDI-GI-Pipeline-w11-corp', 'VDI-GI-Pipeline-win10-lab', 'VDI-GI-Runner' | Sort-Object)
    }
}

Describe 'Registering per-image tasks removes the old and stale ones' {
    BeforeAll {
        InModuleScope VDI-GIPipeline {
            function script:New-ScheduledTaskAction { param($Execute, $Argument, $WorkingDirectory) [pscustomobject]@{} }
            function script:New-ScheduledTaskTrigger { param([switch]$Weekly, [switch]$Once, [switch]$AtStartup, $DaysOfWeek, $At, $RepetitionInterval) [pscustomobject]@{} }
            function script:New-ScheduledTaskSettingsSet { param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, [switch]$StartWhenAvailable, $MultipleInstances, $ExecutionTimeLimit, $RestartCount, $RestartInterval) [pscustomobject]@{} }
            function script:New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) [pscustomobject]@{} }
            function script:New-ScheduledTask { param($Action, $Trigger, $Settings, $Principal, $Description) [pscustomobject]@{} }
            function script:Register-ScheduledTask { param($TaskName, $InputObject, $User, $Password, [switch]$Force) }
            function script:Get-ScheduledTask { param($TaskName, $ErrorAction) }
            function script:Unregister-ScheduledTask { param($TaskName, $Confirm) }
        }
    }
    BeforeEach {
        Mock -ModuleName VDI-GIPipeline Test-GIIsWindows { $true }
        Mock -ModuleName VDI-GIPipeline Get-Command { [pscustomobject]@{ Source = 'C:\pwsh\pwsh.exe' } } -ParameterFilter { $Name -eq 'pwsh' }
        Mock -ModuleName VDI-GIPipeline Register-ScheduledTask { }
        Mock -ModuleName VDI-GIPipeline Unregister-ScheduledTask { }
        $script:perImage = @(
            @{ Name = 'VDI-GI-Pipeline-a'; Description = 'a'; Script = (Join-Path $script:root 'Invoke-GIPipeline.ps1'); Arguments = '-Stage All -ImageId a'; Trigger = @{ Type = 'Weekly'; Day = 'Friday'; Time = '03:15' }; Settings = @{ ExecutionTimeLimitHours = 12; RestartCount = 0; RestartIntervalMinutes = 0 } }
            @{ Name = 'VDI-GI-Runner'; Description = 'r'; Script = (Join-Path $script:root 'Invoke-GIPipeline.ps1'); Arguments = '-FromRequest'; Trigger = @{ Type = 'None' }; Settings = @{ ExecutionTimeLimitHours = 12; RestartCount = 0; RestartIntervalMinutes = 0 } })
    }
    It 'removes the old single task and the task of an image that is gone, keeps the rest, and says so in the result' {
        Mock -ModuleName VDI-GIPipeline Get-ScheduledTask { @([pscustomobject]@{ TaskName = 'VDI-GI-Pipeline' }, [pscustomobject]@{ TaskName = 'VDI-GI-Pipeline-a' }, [pscustomobject]@{ TaskName = 'VDI-GI-Pipeline-gone' }, [pscustomobject]@{ TaskName = 'VDI-GI-PostCheck' }) }
        $r = @(Register-GIPipelineTask -Definitions $perImage -Credential $script:cred)
        @($r | Where-Object { $_.Registered } | ForEach-Object { $_.Name }) | Should -Be @('VDI-GI-Pipeline-a', 'VDI-GI-Runner')
        @($r | Where-Object { $_.ContainsKey('Removed') } | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('VDI-GI-Pipeline', 'VDI-GI-Pipeline-gone')
        Should -Invoke -ModuleName VDI-GIPipeline Unregister-ScheduledTask -Times 2 -Exactly
        Should -Invoke -ModuleName VDI-GIPipeline Unregister-ScheduledTask -Times 0 -Exactly -ParameterFilter { $TaskName -in 'VDI-GI-Pipeline-a', 'VDI-GI-PostCheck' }
    }
    It 'removes nothing when the definitions have no per-image task (old single-task registration)' {
        Mock -ModuleName VDI-GIPipeline Get-ScheduledTask { @([pscustomobject]@{ TaskName = 'VDI-GI-Pipeline-a' }) }
        $old = @(Get-GIPipelineTaskDefinition -Root $script:root)
        $null = Register-GIPipelineTask -Definitions $old -Credential $script:cred
        Should -Invoke -ModuleName VDI-GIPipeline Unregister-ScheduledTask -Times 0 -Exactly
    }
    It '-WhatIf removes nothing' {
        Mock -ModuleName VDI-GIPipeline Get-ScheduledTask { @([pscustomobject]@{ TaskName = 'VDI-GI-Pipeline' }) }
        $null = Register-GIPipelineTask -Definitions $perImage -Credential $script:cred -WhatIf
        Should -Invoke -ModuleName VDI-GIPipeline Unregister-ScheduledTask -Times 0 -Exactly
    }
    It 'Unregister also removes every per-image task' {
        Mock -ModuleName VDI-GIPipeline Get-ScheduledTask { if ($TaskName -eq 'VDI-GI-Pipeline-*') { @([pscustomobject]@{ TaskName = 'VDI-GI-Pipeline-a' }, [pscustomobject]@{ TaskName = 'VDI-GI-Pipeline-b' }) } elseif ($TaskName -in 'VDI-GI-Pipeline-a', 'VDI-GI-Pipeline-b', 'VDI-GI-Runner') { [pscustomobject]@{ TaskName = $TaskName } } }
        @(Unregister-GIPipelineTask | Sort-Object) | Should -Be @('VDI-GI-Pipeline-a', 'VDI-GI-Pipeline-b', 'VDI-GI-Runner')
    }
    It 'the setup step counts registered tasks only and reports what it removed' {
        $cfg = @{ Root = $script:root; Paths = @{ State = $TestDrive } }
        Mock -ModuleName VDI-GIPipeline Get-GICurrentUserName { 'LAB\svc' }
        Mock -ModuleName VDI-GIPipeline Test-GIWindowsCredential { $true }
        Mock -ModuleName VDI-GIPipeline Get-GIPipelineTaskDefinition { @(@{ Name = 'VDI-GI-Pipeline-a' }) }
        Mock -ModuleName VDI-GIPipeline Register-GIPipelineTask { @(@{ Name = 'VDI-GI-Pipeline-a'; Registered = $true }, @{ Name = 'VDI-GI-Pipeline'; Registered = $false; Removed = $true }) }
        $r = InModuleScope VDI-GIPipeline -Parameters @{ cfg = $cfg; cred = $script:cred } { param($cfg, $cred) Invoke-GISetupTasks -Config $cfg -State ([pscustomobject]@{ mode = 'Production' }) -Credential $cred }
        $r.Message | Should -Match '^Registered 1 scheduled tasks as LAB\\svc\. Removed VDI-GI-Pipeline '
        @($r.Data.removed) | Should -Be @('VDI-GI-Pipeline')
    }
}
