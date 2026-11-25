BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'src' 'State.ps1')
    . (Join-Path $PSScriptRoot '..' 'Web' 'DashboardViews.ps1')
    . (Join-Path $PSScriptRoot '..' 'Web' 'Components.ps1')
    $script:stages = @('Preflight', 'Maintain', 'Snapshot', 'TestPush', 'Validate', 'Approval', 'Promote', 'PostCheck')
}

Describe 'Test-GIRunId' {
    It 'accepts a valid id' { Test-GIRunId '20261124-213005' | Should -BeTrue }
    It 'rejects <_>' -ForEach @('../x', '..\x', '20261124-213005/../..', '20261124-21300', '20261124-213005x', '', "20261124-213005`n") {
        Test-GIRunId $_ | Should -BeFalse
    }
    It 'rejects null' { Test-GIRunId $null | Should -BeFalse }
}

