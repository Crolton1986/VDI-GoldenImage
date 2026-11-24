BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'VDI-GIPipeline.psd1') -Force
    # Stubs for commands that may not exist on this box (or are defined by a concurrent src file)
    InModuleScope VDI-GIPipeline {
        $stubs = @{
            'Install-Module'            = { param($Name, $MinimumVersion, $MaximumVersion, $Scope, [switch]$Force, [switch]$AllowClobber, [switch]$SkipPublisherCheck, $ErrorAction) }
            'Set-PSRepository'          = { param($Name, $InstallationPolicy) }
            'Get-PSRepository'          = { param($Name) }
            'Get-PackageProvider'       = { param($Name, [switch]$ListAvailable) }
            'Install-PackageProvider'   = { param($Name, $MinimumVersion, $Scope, [switch]$Force) }
            'Set-PowerCLIConfiguration' = { param($Scope, $ParticipateInCEIP, $InvalidCertificateAction, $Confirm) }
            'Write-GISetupProgress'     = { param($Config, $Step, $Line) }
            'Set-GISetupStepData'       = { param($Config, $Step, $Data) }
        }
        foreach ($n in $stubs.Keys) {
            if (-not (Get-Command $n -ErrorAction SilentlyContinue)) {
                Set-Item -Path "function:script:$n" -Value $stubs[$n]
            }
        }
    }
    function script:Mod($n, $v) { [pscustomobject]@{ Name = $n; Version = [version]$v } }
}

Describe 'Get-GIRequiredModule' {
    It 'lists the six modules with Pode capped at 2.x' {
        InModuleScope VDI-GIPipeline {
            $m = Get-GIRequiredModule
            $m.Count | Should -Be 6
            ($m | Where-Object Name -eq 'Pode')['MaximumVersion'] | Should -Be '2.99.99'
            @($m | Where-Object { -not $_['Required'] }).Name | Should -Be @('Pester', 'PSScriptAnalyzer')
        }
    }
}

Describe 'Get-GIModuleStatus' {
    BeforeAll {
        $script:pode = @{ Name = 'Pode'; MinimumVersion = '2.10.0'; MaximumVersion = '2.99.99'; Required = $true }
        $script:pc = @{ Name = 'VMware.PowerCLI'; MinimumVersion = '13.0.0'; Required = $true }
    }
    It 'is missing when nothing is installed' {
        Mock -ModuleName VDI-GIPipeline Get-Module { @() }
        $r = Get-GIModuleStatus -Module $script:pc
        $r.status | Should -Be 'missing'
        $r.installed | Should -BeNullOrEmpty
        $r.required | Should -Be '13.0.0'
    }
    It 'is ok for an in-range version and reports the range' {
        Mock -ModuleName VDI-GIPipeline Get-Module { script:Mod 'Pode' '2.12.1' }
        $r = Get-GIModuleStatus -Module $script:pode
        $r.status | Should -Be 'ok'; $r.installed | Should -Be '2.12.1'; $r.required | Should -Be '2.10.0 - 2.99.99'
    }
    It 'is outdated below the minimum' {
        Mock -ModuleName VDI-GIPipeline Get-Module { script:Mod 'VMware.PowerCLI' '12.7.0' }
        $r = Get-GIModuleStatus -Module $script:pc
        $r.status | Should -Be 'outdated'; $r.installed | Should -Be '12.7.0'
    }
    It 'is too-new when only Pode 3 is installed' {
        Mock -ModuleName VDI-GIPipeline Get-Module { script:Mod 'Pode' '3.0.1' }
        $r = Get-GIModuleStatus -Module $script:pode
        $r.status | Should -Be 'too-new'; $r.installed | Should -Be '3.0.1'
    }
    It 'is ok with 2.x when Pode 2 and 3 are both installed' {
        Mock -ModuleName VDI-GIPipeline Get-Module { (script:Mod 'Pode' '3.0.1'), (script:Mod 'Pode' '2.11.0'), (script:Mod 'Pode' '2.9.0') }
        $r = Get-GIModuleStatus -Module $script:pode
        $r.status | Should -Be 'ok'; $r.installed | Should -Be '2.11.0'
    }
}

Describe 'Invoke-GISetupModules' {
    BeforeEach {
        $script:installed = @{}   # name -> version; Install-Module adds here
        $script:installCalls = [System.Collections.Generic.List[object]]::new()
        $script:failFor = [System.Collections.Generic.List[string]]::new()
        $ctx = @{ installed = $script:installed; calls = $script:installCalls; fail = @{ Value = $script:failFor } }
        Mock -ModuleName VDI-GIPipeline Write-GISetupProgress {}
        Mock -ModuleName VDI-GIPipeline Set-GISetupStepData {}
        Mock -ModuleName VDI-GIPipeline Get-PackageProvider { [pscustomobject]@{ Name = 'NuGet'; Version = [version]'2.8.5.208' } }
        Mock -ModuleName VDI-GIPipeline Install-PackageProvider {}
        Mock -ModuleName VDI-GIPipeline Get-PSRepository { [pscustomobject]@{ Name = 'PSGallery'; InstallationPolicy = 'Untrusted' } }
        Mock -ModuleName VDI-GIPipeline Set-PSRepository {}
        $getMod = {
            param($Name)
            $n = "$Name"; if ($ctx.installed.ContainsKey($n)) { [pscustomobject]@{ Name = $n; Version = [version]$ctx.installed[$n] } }
        }.GetNewClosure()
        $instMod = {
            param($Name, $MinimumVersion, $MaximumVersion, $Scope, $SkipPublisherCheck)
            $Name = "$Name"
            $ctx.calls.Add(@{ Name = $Name; Scope = $Scope; Max = $MaximumVersion; Skip = [bool]$SkipPublisherCheck })
            if ($Name -in $ctx.fail['Value']) { throw "gallery says no for $Name" }
            $ctx.installed[$Name] = "$MinimumVersion"
        }.GetNewClosure()
        Mock -ModuleName VDI-GIPipeline Get-Module -MockWith $getMod
        Mock -ModuleName VDI-GIPipeline Install-Module -MockWith $instMod
        $script:cfg = @{ Root = $TestDrive }
    }

    It 'uses CurrentUser scope in Lab and AllUsers in Production' {
        Invoke-GISetupModules -Config $script:cfg -State @{ mode = 'Lab' } | Out-Null
        ($script:installCalls | ForEach-Object { $_.Scope } | Select-Object -Unique) | Should -Be 'CurrentUser'
        $script:installed.Clear(); $script:installCalls.Clear()
        Invoke-GISetupModules -Config $script:cfg -State ([pscustomobject]@{ mode = 'Production' }) | Out-Null
        ($script:installCalls | ForEach-Object { $_.Scope } | Select-Object -Unique) | Should -Be 'AllUsers'
    }
    It 'trusts PSGallery when untrusted' {
        Invoke-GISetupModules -Config $script:cfg -State @{ mode = 'Lab' } | Out-Null
        Should -Invoke -ModuleName VDI-GIPipeline Set-PSRepository -Times 1 -ParameterFilter { $InstallationPolicy -eq 'Trusted' }
    }
    It 'does not touch an already-trusted PSGallery' {
        Mock -ModuleName VDI-GIPipeline Get-PSRepository { [pscustomobject]@{ Name = 'PSGallery'; InstallationPolicy = 'Trusted' } }
        Invoke-GISetupModules -Config $script:cfg -State @{ mode = 'Lab' } | Out-Null
        Should -Invoke -ModuleName VDI-GIPipeline Set-PSRepository -Times 0
    }
    It 'installs NuGet when missing' {
        Mock -ModuleName VDI-GIPipeline Get-PackageProvider { @() }
        Invoke-GISetupModules -Config $script:cfg -State @{ mode = 'Lab' } | Out-Null
        Should -Invoke -ModuleName VDI-GIPipeline Install-PackageProvider -Times 1
    }
    It 'skips Install-Module for modules already installed' {
        foreach ($m in 'Pode:2.12.0', 'VMware.PowerCLI:13.3.0', 'Microsoft.PowerShell.SecretManagement:1.1.2',
            'Microsoft.PowerShell.SecretStore:1.0.6', 'Pester:5.6.0', 'PSScriptAnalyzer:1.22.0') {
            $n, $v = $m -split ':'; $script:installed[$n] = $v
        }
        $r = Invoke-GISetupModules -Config $script:cfg -State @{ mode = 'Lab' }
        Should -Invoke -ModuleName VDI-GIPipeline Install-Module -Times 0
        $r.Message | Should -Be '0 installed, 6 already present'
        @($r.Data.items).Count | Should -Be 6
    }
    It 'passes MaximumVersion for Pode and SkipPublisherCheck only for Pester' {
        $r = Invoke-GISetupModules -Config $script:cfg -State @{ mode = 'Lab' }
        ($script:installCalls | Where-Object Name -eq 'Pode').Max | Should -Be '2.99.99'
        ($script:installCalls | Where-Object Name -eq 'VMware.PowerCLI').Max | Should -BeNullOrEmpty
        ($script:installCalls | Where-Object Name -eq 'Pester').Skip | Should -BeTrue
        ($script:installCalls | Where-Object Name -eq 'Pode').Skip | Should -BeFalse
        $r.Message | Should -Be '6 installed, 0 already present'
        Should -Invoke -ModuleName VDI-GIPipeline Set-GISetupStepData -Times 6
    }
    It 'throws naming a failing required module and stops' {
        $script:failFor.Add('VMware.PowerCLI')
        { Invoke-GISetupModules -Config $script:cfg -State @{ mode = 'Lab' } } | Should -Throw '*VMware.PowerCLI*gallery says no*'
        $script:installCalls.Name | Should -Not -Contain 'Microsoft.PowerShell.SecretManagement'
    }
    It 'continues after an optional failure and reports it' {
        $script:failFor.Add('Pester')
        $r = Invoke-GISetupModules -Config $script:cfg -State @{ mode = 'Lab' }
        $r.Message | Should -Be '5 installed, 0 already present, 1 optional failed'
        $p = $r.Data.items | Where-Object name -eq 'Pester'
        $p.status | Should -Be 'failed'; $p.error | Should -BeLike '*gallery says no*'
        ($r.Data.items | Where-Object name -eq 'PSScriptAnalyzer').status | Should -Be 'ok'
    }
}

Describe 'Invoke-GISetupPrerequisites' {
    BeforeEach {
        Mock -ModuleName VDI-GIPipeline Write-GISetupProgress {}
        Mock -ModuleName VDI-GIPipeline Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200 } }
        Mock -ModuleName VDI-GIPipeline Test-GIIsAdministrator { $true }
        $script:cfg = @{ Root = $TestDrive }
    }
    It 'passes when everything is fine (Lab)' {
        $r = Invoke-GISetupPrerequisites -Config $script:cfg -State @{ mode = 'Lab' }
        $r.Message | Should -BeLike '* checks passed'
        @($r.Data.checks | Where-Object { -not $_.ok -and $_.blocking }).Count | Should -Be 0
        ($r.Data.checks | Where-Object name -eq 'PowerShell version').ok | Should -BeTrue
    }
    It 'blocks when the gallery is unreachable' {
        Mock -ModuleName VDI-GIPipeline Invoke-WebRequest { throw 'no route' }
        { Invoke-GISetupPrerequisites -Config $script:cfg -State @{ mode = 'Lab' } } | Should -Throw '1 prerequisite(s) failed*PSGallery*'
    }
    It 'blocks on low disk space' {
        Mock -ModuleName VDI-GIPipeline Get-GIFreeDiskGB { 0.5 }
        { Invoke-GISetupPrerequisites -Config $script:cfg -State @{ mode = 'Lab' } } | Should -Throw '*Free disk space*'
    }
    It 'reports the disk check as ok with plenty of space' {
        Mock -ModuleName VDI-GIPipeline Get-GIFreeDiskGB { 50 }
        $r = Invoke-GISetupPrerequisites -Config $script:cfg -State @{ mode = 'Lab' }
        ($r.Data.checks | Where-Object name -eq 'Free disk space').ok | Should -BeTrue
    }
    It 'blocks a non-admin in Production but not in Lab' {
        Mock -ModuleName VDI-GIPipeline Test-GIIsAdministrator { $false }
        $lab = Invoke-GISetupPrerequisites -Config $script:cfg -State @{ mode = 'Lab' }
        ($lab.Data.checks | Where-Object name -eq 'Administrator').blocking | Should -BeFalse
        { Invoke-GISetupPrerequisites -Config $script:cfg -State @{ mode = 'Production' } } | Should -Throw '*Administrator*'
    }
}

Describe 'Invoke-GISetupPowerCLI' {
    BeforeEach {
        Mock -ModuleName VDI-GIPipeline Write-GISetupProgress {}
        Mock -ModuleName VDI-GIPipeline Import-Module {} -ParameterFilter { $Name -eq 'VMware.VimAutomation.Core' }
        Mock -ModuleName VDI-GIPipeline Set-PowerCLIConfiguration {}
    }
    It 'rejects an invalid certificate action' {
        { Invoke-GISetupPowerCLI -Config @{} -State @{ mode = 'Lab'; options = @{ invalidCertAction = 'Maybe' } } } | Should -Throw '*Invalid certificate action*'
        Should -Invoke -ModuleName VDI-GIPipeline Set-PowerCLIConfiguration -Times 0
    }
    It 'turns CEIP off and applies the chosen action' {
        $r = Invoke-GISetupPowerCLI -Config @{} -State @{ mode = 'Lab'; options = @{ invalidCertAction = 'Ignore' } }
        Should -Invoke -ModuleName VDI-GIPipeline Set-PowerCLIConfiguration -Times 1 -ParameterFilter {
            $ParticipateInCEIP -eq $false -and $InvalidCertificateAction -eq 'Ignore' -and $Scope -eq 'User' }
        $r.Message | Should -BeLike '*Ignore*'
    }
    It 'defaults to Warn when no option is set' {
        Invoke-GISetupPowerCLI -Config @{} -State @{ mode = 'Lab' } | Out-Null
        Should -Invoke -ModuleName VDI-GIPipeline Set-PowerCLIConfiguration -Times 1 -ParameterFilter { $InvalidCertificateAction -eq 'Warn' }
    }
    It 'fails clearly when PowerCLI is missing' {
        Mock -ModuleName VDI-GIPipeline Import-Module { throw 'not found' } -ParameterFilter { $Name -eq 'VMware.VimAutomation.Core' }
        { Invoke-GISetupPowerCLI -Config @{} -State @{ mode = 'Lab' } } | Should -Throw '*VMware.PowerCLI is not installed*'
    }
}
