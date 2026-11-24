BeforeAll {
    $script:LauncherPath = (Resolve-Path (Join-Path $PSScriptRoot '..' 'Start-GIPipeline.ps1')).Path
    $script:Tokens = $null
    $script:Errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:LauncherPath, [ref]$script:Tokens, [ref]$script:Errors)
    $script:Text = Get-Content -LiteralPath $script:LauncherPath -Raw

    # Line of the elevation section: everything above it must run in Windows PowerShell 5.1
    $marker = (Select-String -LiteralPath $script:LauncherPath -Pattern '#----- 2\. Elevation' | Select-Object -First 1)
    $script:ElevationLine = if ($marker) { $marker.LineNumber } else { 0 }

    # Extract the helper and swap the automatic variable for one the test controls
    $fn = $script:Ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-GILauncherArgs' }, $true)
    $script:FnText = if ($fn) { $fn.Extent.Text } else { $null }
    $script:FakeLauncher = 'C:\Pipeline\Start-GIPipeline.ps1'
    if ($script:FnText) {
        $patched = $script:FnText.Replace('$PSCommandPath', '$script:FakeLauncher')
        Invoke-Expression $patched
    }
}

Describe 'Start-GIPipeline.ps1 structure' {
    It 'parses without errors' {
        @($script:Errors).Count | Should -Be 0
    }
    It 'defines Get-GILauncherArgs and has the elevation marker' {
        $script:FnText | Should -Not -BeNullOrEmpty
        $script:ElevationLine | Should -BeGreaterThan 0
    }
}

Describe 'Get-GILauncherArgs' {
    It 'starts with NoProfile/Bypass and points -File at the script path variable, quoted' {
        $a = Get-GILauncherArgs -Bound @{}
        $a[0..3] | Should -Be @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File')
        $a[4] | Should -Be "`"$script:FakeLauncher`""
        $a.Count | Should -Be 5
        $script:FnText | Should -Match '-File.*\$PSCommandPath'
    }
    It 'emits a switch only when it is present' {
        $a = Get-GILauncherArgs -Bound @{ LocalAdmin = [System.Management.Automation.SwitchParameter]$true; NoBrowser = [System.Management.Automation.SwitchParameter]$false }
        $a | Should -Contain '-LocalAdmin'
        $a | Should -Not -Contain '-NoBrowser'
        $a | Should -Not -Contain '"False"'
        $a | Should -Not -Contain '"True"'
    }
    It 'quotes string and number values after their name' {
        $a = Get-GILauncherArgs -Bound @{ ConfigPath = 'C:\my dir\pipeline.config.psd1'; Port = 9090 }
        $i = [array]::IndexOf($a, '-ConfigPath')
        $i | Should -BeGreaterThan 4
        $a[$i + 1] | Should -Be '"C:\my dir\pipeline.config.psd1"'
        $j = [array]::IndexOf($a, '-Port')
        $a[$j + 1] | Should -Be '"9090"'
    }
    It 'emits nothing extra for an empty bound set' {
        @(Get-GILauncherArgs -Bound @{}).Count | Should -Be 5
    }
}

Describe 'Windows PowerShell 5.1 compatibility before the pwsh handoff' {
    BeforeAll {
        $script:Pre = @($script:Tokens | Where-Object { $_.Extent.StartLineNumber -lt $script:ElevationLine -and $_.Kind -ne 'Comment' })
    }
    It 'has tokens to check' {
        $script:Pre.Count | Should -BeGreaterThan 50
    }
    It 'uses no null-coalescing or null-conditional operators' {
        @($script:Pre | Where-Object { $_.Kind.ToString() -in 'QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket' }).Count | Should -Be 0
    }
    It 'uses no ternary operator' {
        @($script:Pre | Where-Object { $_.Kind.ToString() -eq 'QuestionMark' }).Count | Should -Be 0
        $t = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TernaryExpressionAst] -and $n.Extent.StartLineNumber -lt $script:ElevationLine }, $true)
        @($t).Count | Should -Be 0
    }
    It 'uses no pipeline chain operators (&& ||)' {
        @($script:Pre | Where-Object { $_.Kind.ToString() -in 'AndAnd', 'OrOr' }).Count | Should -Be 0
        $c = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.PipelineChainAst] -and $n.Extent.StartLineNumber -lt $script:ElevationLine }, $true)
        @($c).Count | Should -Be 0
    }
    It 'uses no -AsHashtable' {
        @($script:Pre | Where-Object { $_.Kind.ToString() -eq 'Parameter' -and $_.Text -match '^-AsHashtable' }).Count | Should -Be 0
    }
    It 'does not use $IsWindows (undefined in 5.1)' {
        @($script:Pre | Where-Object { $_.Kind.ToString() -eq 'Variable' -and $_.Name -eq 'IsWindows' }).Count | Should -Be 0
    }
    It 'also passes a plain-text scan of the code above the marker (comments stripped)' {
        $lines = ($script:Text -split "`r?`n") | Select-Object -First ($script:ElevationLine - 1)
        $code = ($lines | ForEach-Object { $_ -replace '^\s*#.*$', '' }) -join "`n"
        $code | Should -Not -Match '\$IsWindows'
        $code | Should -Not -Match '-AsHashtable'
        $code | Should -Not -Match '\?\?'
        $code | Should -Not -Match '&&|\|\|'
    }
}
