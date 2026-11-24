BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'src' 'Config.ps1')

    function script:New-TestConfigFile {
        param([string]$Dir, [scriptblock]$Mutate)
        $cfg = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot '..' 'pipeline.config.psd1')
        if ($Mutate) { & $Mutate $cfg }
        $text = '@{' + [Environment]::NewLine
        $text += "Paths = @{ State = 'st'; Reports = 'rep'; Logs = 'lg' }" + [Environment]::NewLine
        $text += "vCenter = @{ Server = 'vc' }; Horizon = @{ Server = 'hz' }; GoldenImage = @{ VmName = 'vm' }" + [Environment]::NewLine
        $text += "Pools = @{ Test = @{ Name = 'T' }; Production = @( @{ Name = 'P' } ) }; Snapshots = @{ Keep = 3 }" + [Environment]::NewLine
        $text += "Promotion = @{ MaintenanceWindow = @{ Days = @('Saturday'); StartTime = '22:00' } }" + [Environment]::NewLine + '}'
        $file = Join-Path $Dir 'cfg.psd1'
        Set-Content -LiteralPath $file -Value $text
        $file
    }
}

Describe 'Get-GIConfig' {
    It 'loads the shipped default config' {
        $cfg = Get-GIConfig -Path (Join-Path $PSScriptRoot '..' 'pipeline.config.psd1')
        $cfg.GoldenImage.VmName | Should -Be 'W11-GI-01'
        [System.IO.Path]::IsPathRooted($cfg.Paths.State) | Should -BeTrue
    }

    It 'resolves relative paths against Root and creates the folders' {
        $file = New-TestConfigFile -Dir $TestDrive
        $cfg = Get-GIConfig -Path $file
        $cfg.Root | Should -Be (Resolve-Path $TestDrive).ProviderPath
        $cfg.Paths.State | Should -Be (Join-Path $cfg.Root 'st')
        Test-Path $cfg.Paths.State | Should -BeTrue
        Test-Path $cfg.Paths.Reports | Should -BeTrue
        Test-Path $cfg.Paths.Logs | Should -BeTrue
    }

    It 'keeps absolute paths' {
        $abs = Join-Path $TestDrive 'abs-state'
        $file = Join-Path $TestDrive 'abs.psd1'
        (Get-Content (New-TestConfigFile -Dir $TestDrive) -Raw).Replace("State = 'st'", "State = '$abs'") | Set-Content $file
        (Get-GIConfig -Path $file).Paths.State | Should -Be $abs
    }

    It 'throws one error listing all missing keys' {
        $file = Join-Path $TestDrive 'bad.psd1'
        Set-Content $file "@{ Paths = @{ State = 's' }; vCenter = @{ Server = 'x' } }"
        $err = { Get-GIConfig -Path $file } | Should -Throw -PassThru
        foreach ($k in 'Paths.Reports', 'Paths.Logs', 'Horizon.Server', 'GoldenImage.VmName', 'Pools.Test.Name',
            'Pools.Production', 'Snapshots.Keep', 'Promotion.MaintenanceWindow') {
            $err.Exception.Message | Should -BeLike "*$k*"
        }
        $err.Exception.Message | Should -Not -BeLike '*Paths.State*'
        $err.Exception.Message | Should -Not -BeLike '*vCenter.Server*'
    }

    It 'throws when the file does not exist' {
        { Get-GIConfig -Path (Join-Path $TestDrive 'nope.psd1') } | Should -Throw '*not found*'
    }
}

Describe 'Get-GINextMaintenanceWindow' {
    BeforeAll {
        # 2026-11-24 is a Tuesday; 2026-11-28 a Saturday
        function script:Cfg($days, $time = '22:00') {
            @{ Promotion = @{ MaintenanceWindow = @{ Days = $days; StartTime = $time } } }
        }
    }

    It 'returns same day when before start time' {
        $r = Get-GINextMaintenanceWindow -Config (Cfg @('Tuesday')) -From ([datetime]'2026-11-24 10:00')
        $r | Should -Be ([datetime]'2026-11-24 22:00')
    }

    It 'counts exact start time as in the window' {
        $r = Get-GINextMaintenanceWindow -Config (Cfg @('Tuesday')) -From ([datetime]'2026-11-24 22:00')
        $r | Should -Be ([datetime]'2026-11-24 22:00')
    }

    It 'wraps to next week when start time has passed' {
        $r = Get-GINextMaintenanceWindow -Config (Cfg @('Tuesday')) -From ([datetime]'2026-11-24 22:01')
        $r | Should -Be ([datetime]'2026-12-01 22:00')
    }

    It 'finds the upcoming day from another weekday' {
        $r = Get-GINextMaintenanceWindow -Config (Cfg @('Saturday')) -From ([datetime]'2026-11-24 09:00')
        $r | Should -Be ([datetime]'2026-11-28 22:00')
    }

    It 'picks the earliest of multiple days' {
        $c = Cfg @('Saturday', 'Thursday', 'Sunday') '03:30'
        Get-GINextMaintenanceWindow -Config $c -From ([datetime]'2026-11-24 09:00') | Should -Be ([datetime]'2026-11-26 03:30')
        Get-GINextMaintenanceWindow -Config $c -From ([datetime]'2026-11-28 04:00') | Should -Be ([datetime]'2026-11-29 03:30')
        Get-GINextMaintenanceWindow -Config $c -From ([datetime]'2026-11-29 04:00') | Should -Be ([datetime]'2026-12-03 03:30')
    }

    It 'returns a datetime' {
        (Get-GINextMaintenanceWindow -Config (Cfg @('Monday'))) | Should -BeOfType ([datetime])
    }
}

Describe 'Get-GISecretCredential' {
    It 'throws a clear error when SecretManagement is missing' -Skip:([bool](Get-Command Get-Secret -ErrorAction SilentlyContinue) -or [bool](Get-Module -ListAvailable Microsoft.PowerShell.SecretManagement)) {
        { Get-GISecretCredential -Name 'x' } | Should -Throw '*SecretManagement*'
    }
}
