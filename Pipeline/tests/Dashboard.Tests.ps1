BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'src' 'State.ps1')
    . (Join-Path $PSScriptRoot '..' 'Web' 'DashboardViews.ps1')
    . (Join-Path $PSScriptRoot '..' 'Web' 'Components.ps1')
    $script:stages = @('Preflight', 'Maintain', 'Snapshot', 'TestPush', 'Validate', 'Approval', 'Promote', 'PostCheck')
}

Describe 'Dashboard views' {
    BeforeAll {
        $dir = Join-Path $TestDrive 'state'
        $null = New-Item -ItemType Directory -Path $dir
        $script:cfg = @{ Paths = @{ State = $dir }; GoldenImage = @{ VmName = 'W11-GI-01' } }

        # Run 1: awaiting approval, with snapshot, validation and a hostile message
        $r1 = New-GIRun -Config $cfg -RunId '20261124-213005'
        Set-GIStage -Config $cfg -Run $r1 -Stage Preflight -Status Succeeded -Message 'ok'
        Set-GIStage -Config $cfg -Run $r1 -Stage Maintain -Status Succeeded -Message '<script>alert(1)</script>'
        $r1.snapshot = [pscustomobject]@{ id = 's1'; name = 'GI-20261124-213005'; createdAt = (Get-Date).ToString('o'); manifest = [pscustomobject]@{ VmTools = '12.5.0'; Horizon = '2512.0.0' } }
        $r1.validation = [pscustomobject]@{ passed = $true; checks = @(
                [pscustomobject]@{ category = 'Horizon'; name = 'MachineState'; target = 'TST-W11-001'; passed = $true; detail = 'AVAILABLE' },
                [pscustomobject]@{ category = 'Guest'; name = 'Service'; target = 'TST-W11-001'; passed = $false; detail = 'frxsvc stopped' }) }
        Set-GIStage -Config $cfg -Run $r1 -Stage TestPush -Status Succeeded
        Set-GIStage -Config $cfg -Run $r1 -Stage Validate -Status Succeeded
        Set-GIStage -Config $cfg -Run $r1 -Stage Approval -Status Running
        $r1.status = 'AwaitingApproval'
        Save-GIRun -Config $cfg -Run $r1

        # Run 2: completed with promotion
        $r2 = New-GIRun -Config $cfg -RunId '20261120-100000'
        $r2.status = 'Completed'
        $r2.snapshot = [pscustomobject]@{ id = 's0'; name = 'GI-20261120-100000'; createdAt = (Get-Date).ToString('o'); manifest = [pscustomobject]@{} }
        $r2.promotion = [pscustomobject]@{ pools = @([pscustomobject]@{ poolName = 'PRD-W11'; poolId = 'p'; scheduledStart = (Get-Date).ToString('o'); status = 'Succeeded'; message = '' }) }
        Save-GIRun -Config $cfg -Run $r2

        $script:runs = @(Get-GIRunList -Config $cfg -Last 50)
        $script:detail = New-GIRunDetailPage -Run (Get-GIRun -Config $cfg -RunId '20261124-213005') -RefreshSeconds 15
    }

    It 'list page shows runs and the Needs approval section' {
        $html = New-GIRunListPage -Runs $runs -RefreshSeconds 20
        $html | Should -Match 'Needs approval'
        $html | Should -Match 'href="/runs/20261124-213005"'
        $html | Should -Match 'href="/runs/20261120-100000"'
        $html | Should -Match 'http-equiv="refresh" content="20"'
    }

    It 'list page omits Needs approval when nothing waits' {
        New-GIRunListPage -Runs @($runs[1]) | Should -Not -Match 'Needs approval'
    }

    It 'detail page shows all 8 stages in order' {
        $pos = foreach ($s in $stages) { $detail.IndexOf("</span>$s</td>") }
        $pos | Should -Not -Contain -1
        ($pos | Sort-Object) | Should -Be $pos
    }

    It 'detail page groups validation checks and shows manifest, report and log links' {
        $detail | Should -Match 'class="cat"><td colspan="4">Horizon'
        $detail | Should -Match 'class="cat"><td colspan="4">Guest'
        $detail | Should -Match 'VmTools'
        $detail | Should -Match '/reports/20261124-213005'
        $detail | Should -Match '/logs/20261124-213005'
    }

    It 'HTML-encodes stage messages' {
        $detail | Should -Not -Match '<script>alert'
        $detail | Should -Match '&lt;script&gt;alert\(1\)&lt;/script&gt;'
    }

    It 'pools page uses latest promotion per pool and last known good' {
        $lkg = [pscustomobject]@{ goldenVm = 'W11-GI-01'; snapshotName = 'GI-20261120-100000'; runId = '20261120-100000'; promotedAt = (Get-Date).ToString('o') }
        $html = New-GIPoolsPage -LastKnownGood $lkg -Runs $runs -TestPoolName 'TST-W11'
        $html | Should -Match 'PRD-W11'
        $html | Should -Match 'GI-20261124-213005'   # test pool snapshot
        $html | Should -Match 'Last known good'
    }

    It 'not found page renders' {
        New-GINotFoundPage | Should -Match '404'
    }
}

Describe 'Test-GIRunId' {
    It 'accepts a valid id' { Test-GIRunId '20261124-213005' | Should -BeTrue }
    It 'rejects <_>' -ForEach @('../x', '..\x', '20261124-213005/../..', '20261124-21300', '20261124-213005x', '', "20261124-213005`n") {
        Test-GIRunId $_ | Should -BeFalse
    }
    It 'rejects null' { Test-GIRunId $null | Should -BeFalse }
}
