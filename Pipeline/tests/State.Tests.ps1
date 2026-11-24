BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'src' 'State.ps1')
    $script:stages = @('Preflight', 'Maintain', 'Snapshot', 'TestPush', 'Validate', 'Approval', 'Promote', 'PostCheck')
}

Describe 'State' {
    BeforeEach {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir
        $script:cfg = @{ Paths = @{ State = $dir }; GoldenImage = @{ VmName = 'W11-GI-01' } }
    }

    Context 'New-GIRun' {
        It 'creates all stages Pending in order' {
            $run = New-GIRun -Config $cfg -RunId '20261124-213005'
            $run.runId | Should -Be '20261124-213005'
            $run.status | Should -Be 'Running'
            $run.goldenVm | Should -Be 'W11-GI-01'
            @($run.stages.PSObject.Properties.Name) | Should -Be $stages
            foreach ($s in $stages) {
                $run.stages.$s.status | Should -Be 'Pending'
                $run.stages.$s.startedAt | Should -BeNullOrEmpty
            }
        }

        It 'persists and generates a RunId by default' {
            $run = New-GIRun -Config $cfg
            $run.runId | Should -Match '^\d{8}-\d{6}$'
            Test-Path (Join-Path $cfg.Paths.State "$($run.runId).json") | Should -BeTrue
        }

        It 'matches the shape of a loaded run and keeps timestamps as strings' {
            $run = New-GIRun -Config $cfg -RunId '20261124-213005'
            $loaded = Get-GIRun -Config $cfg -RunId '20261124-213005'
            $run.createdAt | Should -BeOfType ([string])
            $loaded.createdAt | Should -BeOfType ([string])
            $loaded.stages.Maintain.data | Should -BeOfType ([pscustomobject])
            @($loaded.validation.checks).Count | Should -Be 0
            @($loaded.stages.PSObject.Properties.Name) | Should -Be $stages
        }

        It 'Get-GIRun throws when missing' {
            { Get-GIRun -Config $cfg -RunId '19990101-000000' } | Should -Throw '*not found*'
        }
    }

    Context 'Set-GIStage' {
        It 'sets timestamps and currentStage' {
            $run = New-GIRun -Config $cfg -RunId '20261124-213005'
            Set-GIStage -Config $cfg -Run $run -Stage Preflight -Status Running
            $run.stages.Preflight.startedAt | Should -Not -BeNullOrEmpty
            $run.stages.Preflight.endedAt | Should -BeNullOrEmpty
            $run.currentStage | Should -Be 'Preflight'
            Set-GIStage -Config $cfg -Run $run -Stage Preflight -Status Succeeded -Message 'ok'
            $loaded = Get-GIRun -Config $cfg -RunId $run.runId
            $loaded.stages.Preflight.status | Should -Be 'Succeeded'
            $loaded.stages.Preflight.endedAt | Should -Not -BeNullOrEmpty
            $loaded.stages.Preflight.message | Should -Be 'ok'
            $loaded.status | Should -Be 'Running'
        }

        It 'Failed sets run status and error' {
            $run = New-GIRun -Config $cfg -RunId '20261124-213005'
            Set-GIStage -Config $cfg -Run $run -Stage Maintain -Status Failed -Message 'boom'
            $loaded = Get-GIRun -Config $cfg -RunId $run.runId
            $loaded.status | Should -Be 'Failed'
            $loaded.error | Should -Be 'boom'
            $loaded.currentStage | Should -Be 'Maintain'
            $loaded.stages.Maintain.endedAt | Should -Not -BeNullOrEmpty
        }

        It 'merges Data keys' {
            $run = New-GIRun -Config $cfg -RunId '20261124-213005'
            Set-GIStage -Config $cfg -Run $run -Stage Maintain -Status Running -Data @{ a = 1; b = 'x' }
            Set-GIStage -Config $cfg -Run $run -Stage Maintain -Status Running -Data @{ b = 'y'; c = @(1, 2) }
            $loaded = Get-GIRun -Config $cfg -RunId $run.runId
            $loaded.stages.Maintain.data.a | Should -Be 1
            $loaded.stages.Maintain.data.b | Should -Be 'y'
            @($loaded.stages.Maintain.data.c).Count | Should -Be 2
        }

        It 'rejects invalid enum values' {
            $run = New-GIRun -Config $cfg -RunId '20261124-213005'
            { Set-GIStage -Config $cfg -Run $run -Stage Nope -Status Running } | Should -Throw
            { Set-GIStage -Config $cfg -Run $run -Stage Maintain -Status Nope } | Should -Throw
        }
    }

    Context 'Set-GIProgress and Save-GIRun' {
        It 'stores progress and updates updatedAt' {
            $run = New-GIRun -Config $cfg -RunId '20261124-213005'
            $before = $run.updatedAt
            Start-Sleep -Milliseconds 20
            Set-GIProgress -Config $cfg -Run $run -Message 'rebooting'
            $loaded = Get-GIRun -Config $cfg -RunId $run.runId
            $loaded.progress | Should -Be 'rebooting'
            $loaded.updatedAt | Should -Not -Be $before
        }

        It 'leaves no .tmp files' {
            $run = New-GIRun -Config $cfg
            Save-GIRun -Config $cfg -Run $run
            Set-GILastKnownGood -Config $cfg -Run $run
            Get-ChildItem $cfg.Paths.State -Filter '*.tmp' | Should -BeNullOrEmpty
        }
    }

    Context 'Get-GIRunList' {
        It 'returns newest first and honours -Last' {
            foreach ($id in '20261120-010000', '20261124-010000', '20261122-010000') { $null = New-GIRun -Config $cfg -RunId $id }
            $all = @(Get-GIRunList -Config $cfg)
            $all.runId | Should -Be @('20261124-010000', '20261122-010000', '20261120-010000')
            $two = @(Get-GIRunList -Config $cfg -Last 2)
            $two.Count | Should -Be 2
            $two[0].runId | Should -Be '20261124-010000'
        }

        It 'ignores lastKnownGood.json' {
            $run = New-GIRun -Config $cfg -RunId '20261120-010000'
            $run.snapshot = [pscustomobject]@{ id = 's1'; name = 'GI-1' }
            Set-GILastKnownGood -Config $cfg -Run $run
            @(Get-GIRunList -Config $cfg).Count | Should -Be 1
        }

        It 'returns nothing for an empty folder' {
            @(Get-GIRunList -Config $cfg).Count | Should -Be 0
        }
    }

    Context 'LastKnownGood' {
        It 'returns $null when absent' {
            Get-GILastKnownGood -Config $cfg | Should -BeNullOrEmpty
            $null -eq (Get-GILastKnownGood -Config $cfg) | Should -BeTrue
        }

        It 'round-trips' {
            $run = New-GIRun -Config $cfg -RunId '20261124-213005'
            $run.snapshot = [pscustomobject]@{ id = 'snap-1'; name = 'GI-20261124-213005' }
            Set-GILastKnownGood -Config $cfg -Run $run
            $l = Get-GILastKnownGood -Config $cfg
            $l.goldenVm | Should -Be 'W11-GI-01'
            $l.snapshotId | Should -Be 'snap-1'
            $l.snapshotName | Should -Be 'GI-20261124-213005'
            $l.runId | Should -Be '20261124-213005'
            $l.promotedAt | Should -Not -BeNullOrEmpty
        }
    }
}
