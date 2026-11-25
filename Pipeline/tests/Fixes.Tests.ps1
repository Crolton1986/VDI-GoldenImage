BeforeDiscovery {
    $dir = Join-Path $PSScriptRoot '..' 'guest' 'fixes'
    $script:FixCases = @(Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File | ForEach-Object { @{ Name = $_.BaseName; Path = $_.FullName } })
}

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'guest' 'GIWatcher.Core.ps1')
    $script:Ast = [System.Management.Automation.Language.Ast]
}

Describe 'Fix script <Name>' -ForEach $script:FixCases {
    BeforeAll {
        $tokens = $null; $perr = $null
        $script:A = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$perr)
        $script:PErr = @($perr)
        $script:Text = Get-Content -LiteralPath $Path -Raw
        $script:Entry = @(Read-GIFixCatalog -Path (Split-Path -Parent $Path) | Where-Object { $_.File -eq $Path })[0]
    }

    It 'parses without errors' { $script:PErr.Count | Should -Be 0 }
    It 'is Valid in the catalog with Id equal to the file name' {
        $script:Entry.Valid | Should -BeTrue -Because ($script:Entry.Errors -join '; ')
        @($script:Entry.Errors).Count | Should -Be 0
        $script:Entry.Meta.Id | Should -BeExactly $Name
    }
    It 'defines Invoke-GIFix with a Context parameter' {
        $fn = @($script:A.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-GIFix' }, $true))
        $fn.Count | Should -Be 1
        @($fn[0].Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) | Should -Contain 'Context'
    }
    It 'has only the $GIFix assignment and function definitions at top level' {
        foreach ($st in $script:A.EndBlock.Statements) {
            $isFn = $st -is [System.Management.Automation.Language.FunctionDefinitionAst]
            $isGi = $st -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $st.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $st.Left.VariablePath.UserPath -eq 'GIFix'
            ($isFn -or $isGi) | Should -BeTrue -Because "unexpected top-level statement: $($st.Extent.Text.Split("`n")[0])"
        }
        $script:A.BeginBlock | Should -BeNullOrEmpty
        $script:A.ProcessBlock | Should -BeNullOrEmpty
    }
    It 'calls none of the banned commands' {
        $banned = 'Stop-Process', 'taskkill', 'taskkill.exe', 'Restart-Computer', 'Stop-Computer', 'shutdown', 'shutdown.exe',
            'Unregister-ScheduledTask', 'Stop-ScheduledTask', 'Invoke-Expression', 'iex', 'wmic', 'wmic.exe'
        $cmds = @($script:A.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
        $hits = @($cmds | Where-Object { $_.GetCommandName() -in $banned } | ForEach-Object { $_.Extent.Text })
        $hits | Should -BeNullOrEmpty
    }
    It 'does not call Remove-Item on WorkDir' {
        $cmds = @($script:A.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'Remove-Item', 'ri', 'rm', 'del', 'erase', 'rd', 'rmdir' }, $true))
        @($cmds | Where-Object { $_.Extent.Text -match 'WorkDir' }) | Should -BeNullOrEmpty
    }
    It 'does not call .Kill()' {
        $m = @($script:A.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -eq 'Kill' }, $true))
        $m.Count | Should -Be 0
    }
    It 'avoids PowerShell 7 only operators (5.1 compatible)' {
        $tokens = $null; $e = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:Text, [ref]$tokens, [ref]$e)
        @($tokens | Where-Object { $_.Text -in '??', '?.', '??=', '?[' -or $_.Kind -in 'QuestionQuestion', 'QuestionDot', 'QuestionQuestionEquals', 'QuestionLBracket' }) | Should -BeNullOrEmpty
        $script:Text | Should -Not -Match '\?\?|\?\.'
        $script:Text | Should -Not -Match '(?m)^\s*#requires\s+-version\s+[67]'
    }
}
