BeforeAll {
    # A stub that fails the test if image removal ever talks to vCenter or Horizon
    function global:Connect-VIServer { throw 'vCenter must not be contacted' }
    Import-Module (Join-Path $PSScriptRoot '..' 'VDI-GIPipeline.psd1') -Force
    function script:New-Root {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("gi-img-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $root | Out-Null
        Copy-Item (Join-Path $PSScriptRoot '..' 'pipeline.config.psd1') $root
        $root
    }
    function script:Load([string]$Root) { Get-GIConfig -Path (Join-Path $Root 'pipeline.config.psd1') }
    function script:New-Payload([string]$Name, [string]$Vm, [string]$Test, [string]$Prod) {
        @{ Name = $Name; Description = 'd'; Os = 'Windows 11'
            GoldenImage = @{ VmName = $Vm; GuestCredentialSecret = "GI-$Vm" }
            Pools = @{ Test = @{ Name = $Test; LogoffPolicy = 'FORCE_LOGOFF' }; Production = @(@{ Name = $Prod; LogoffPolicy = 'WAIT_FOR_LOGOFF' }) } }
    }
}

AfterAll { Remove-Item function:global:Connect-VIServer -ErrorAction SilentlyContinue }

Describe 'Golden image list and migration' {
    BeforeEach { $script:root = New-Root }
    AfterEach { Remove-Item $script:root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'derives one image from the old single-image config' {
        $e = @(Get-GIImageEntries -Config (Load $script:root))
        $e.Count | Should -Be 1
        $e[0].Id | Should -Be 'w11-gi-01'
        $e[0].Legacy | Should -BeTrue
    }
    It 'migrates once: moves runs, writes imageId and a backup, and a second run changes nothing' {
        $c = Load $script:root
        '{"runId":"20261101-010101","status":"Completed","stages":{"Maintain":{}}}' | Set-Content (Join-Path $c.Paths.State '20261101-010101.json')
        'x' | Set-Content (Join-Path $c.Paths.Logs '20261101-010101.log')
        '{"snapshotName":"B1"}' | Set-Content (Join-Path $c.Paths.State 'lastKnownGood.json')
        $m = Invoke-GIConfigMigration -Config $c -InformationAction SilentlyContinue
        $m.Migrated | Should -BeTrue
        Test-Path (Join-Path $m.Backup 'State' '20261101-010101.json') | Should -BeTrue
        Test-Path (Join-Path $m.Backup 'pipeline.config.psd1') | Should -BeTrue
        $c2 = Load $script:root
        $ic = Get-GIImageConfig -Config $c2 -ImageId 'w11-gi-01'
        (Get-GIRun -Config $ic -RunId '20261101-010101').imageId | Should -Be 'w11-gi-01'
        Test-Path (Join-Path $c2.Paths.State '20261101-010101.json') | Should -BeFalse
        (Get-GILastKnownGood -Config $ic).snapshotName | Should -Be 'B1'
        Test-Path (Join-Path $ic.Paths.Logs '20261101-010101.log') | Should -BeTrue
        $before = Get-Content (Join-Path $script:root 'config' 'settings.json') -Raw
        (Invoke-GIConfigMigration -Config $c2).Migrated | Should -BeFalse
        Get-Content (Join-Path $script:root 'config' 'settings.json') -Raw | Should -Be $before
        @(Get-ChildItem (Join-Path $script:root 'config') -Directory -Filter 'migration-backup-*').Count | Should -Be 1
    }
    It 'scopes state, logs and reports per image but keeps one audit log' {
        $null = Invoke-GIConfigMigration -Config (Load $script:root) -InformationAction SilentlyContinue
        $c = Load $script:root
        $ic = Get-GIImageConfig -Config $c -ImageId 'w11-gi-01'
        $ic.Paths.State | Should -Be (Join-Path $c.Paths.State 'w11-gi-01')
        $ic.GoldenImage.VmName | Should -Be 'W11-GI-01'
        (Get-GIAuditPath -Config $ic) | Should -Be (Get-GIAuditPath -Config $c)
        (New-GIRun -Config $ic).imageId | Should -Be 'w11-gi-01'
    }
    It 'creates a second image and keeps the two independent' {
        $null = Invoke-GIConfigMigration -Config (Load $script:root) -InformationAction SilentlyContinue
        $e = New-GIImageFromPayload -Config (Load $script:root) -Payload (New-Payload 'Win10 Kiosk' 'W10-GI-01' 'TST-W10' 'PRD-W10') -By 'LAB\admin'
        $e.Id | Should -Be 'win10-kiosk'
        $c = Load $script:root
        @(Get-GIImageEntries -Config $c).Count | Should -Be 2
        $a = Get-GIImageConfig -Config $c -ImageId 'w11-gi-01'; $b = Get-GIImageConfig -Config $c -ImageId 'win10-kiosk'
        $a.Paths.State | Should -Not -Be $b.Paths.State
        $b.Pools.Test.Name | Should -Be 'TST-W10'
        (Get-GIAudit -Config $c -Last 5 | Where-Object action -eq 'image.create').user | Should -Be 'LAB\admin'
        # Both can hold a run at the same time
        $ra = New-GIRun -Config $a; $rb = New-GIRun -Config $b
        Test-GIImageBusy -ImageConfig $a | Should -BeTrue
        Test-GIImageBusy -ImageConfig $b | Should -BeTrue
    }
    It 'makes ids unique with a number suffix' {
        $null = Invoke-GIConfigMigration -Config (Load $script:root) -InformationAction SilentlyContinue
        $null = New-GIImageFromPayload -Config (Load $script:root) -Payload (New-Payload 'Pool A' 'VM-A' 'T-A' 'P-A')
        (New-GIImageId -Name 'Pool A' -Existing @('pool-a')) | Should -Be 'pool-a-2'
    }
    It 'refuses duplicate names, shared VMs, shared pools and a test pool that is also production' {
        $null = Invoke-GIConfigMigration -Config (Load $script:root) -InformationAction SilentlyContinue
        $c = Load $script:root
        { New-GIImageFromPayload -Config $c -Payload (New-Payload 'w11-gi-01' 'OTHER' 'T1' 'P1') } | Should -Throw '*used twice*'
        { New-GIImageFromPayload -Config $c -Payload (New-Payload 'X' 'W11-GI-01' 'T1' 'P1') } | Should -Throw '*A VM can belong to one image*'
        { New-GIImageFromPayload -Config $c -Payload (New-Payload 'X' 'VM-X' 'TST-W11' 'P1') } | Should -Throw '*A pool can belong to one image*'
        { New-GIImageFromPayload -Config $c -Payload (New-Payload 'X' 'VM-X' 'SAME' 'SAME') } | Should -Throw '*both test pool and production pool*'
    }
    It 'pauses, resumes and removes an image without touching state on disk' {
        $null = Invoke-GIConfigMigration -Config (Load $script:root) -InformationAction SilentlyContinue
        $null = New-GIImageFromPayload -Config (Load $script:root) -Payload (New-Payload 'Second' 'VM-2' 'T2' 'P2')
        Set-GIImagePaused -Config (Load $script:root) -ImageId 'second' -Paused $true
        (Get-GIImageEntry -Config (Load $script:root) -Id 'second').Paused | Should -BeTrue
        $ic = Get-GIImageConfig -Config (Load $script:root) -ImageId 'second'
        $run = New-GIRun -Config $ic
        { Remove-GIImageEntry -Config (Load $script:root) -ImageId 'second' } | Should -Throw '*run is active*'
        $run.status = 'Completed'; Save-GIRun -Config $ic -Run $run
        Remove-GIImageEntry -Config (Load $script:root) -ImageId 'second' -By 'LAB\admin'
        @(Get-GIImageEntries -Config (Load $script:root)).Id | Should -Not -Contain 'second'
        Test-Path (Join-Path $ic.Paths.State "$($run.runId).json") | Should -BeTrue
    }
    It 'saves one per-image section and validates it' {
        $null = Invoke-GIConfigMigration -Config (Load $script:root) -InformationAction SilentlyContinue
        $r = Save-GIImageSection -Config (Load $script:root) -ImageId 'w11-gi-01' -Section 'General' -Values @{ Name = 'Main desktop'; Description = 'Pool image' }
        $r.Changed | Should -Contain 'Name'
        (Get-GIImageEntry -Config (Load $script:root) -Id 'w11-gi-01').Name | Should -Be 'Main desktop'
        $null = Save-GIImageSection -Config (Load $script:root) -ImageId 'w11-gi-01' -Section 'Promotion' -Values @{ AutoPromote = $true }
        (Get-GIImageEntry -Config (Load $script:root) -Id 'w11-gi-01').Promotion.AutoPromote | Should -BeTrue
    }
}

Describe 'Saving one image section' {
    It 'does not fail because another section of the image is invalid' {
        $e = @{ Validation = @{ GuestSampleCount = 2; RequiredServices = @('wsnm'); MachineReadyTimeoutMin = 60 }
                Pools = @{ Test = @{ Name = '' }; Production = @() } }
        $p = @(Get-GIImageEntryProblems -Entry $e -OnlySections @() -SkipConstraints)
        $p.Count | Should -Be 0
    }
    It 'still reports problems in the sections it is asked to check' {
        $e = @{ Pools = @{ Test = @{ Name = '' }; Production = @() } }
        @(Get-GIImageEntryProblems -Entry $e -OnlySections @('Pools') -SkipConstraints).Count | Should -BeGreaterThan 0
    }
}
