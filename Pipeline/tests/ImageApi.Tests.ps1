BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'VDI-GIPipeline.psd1') -Force
    function script:New-Root {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("gi-api-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $root | Out-Null
        Copy-Item (Join-Path $PSScriptRoot '..' 'pipeline.config.psd1') $root
        $c = Get-GIConfig -Path (Join-Path $root 'pipeline.config.psd1')
        $null = Invoke-GIConfigMigration -Config $c -InformationAction SilentlyContinue
        $root
    }
    function script:Cfg { Get-GIConfig -Path (Join-Path $script:root 'pipeline.config.psd1') }
    function script:Api([string]$M, [string]$P, $Body = $null, [string]$Role = 'Admin', [hashtable]$Query = @{}, [hashtable]$Options = @{}) {
        Invoke-GIApiRequest -Config (Cfg) -Method $M -Path $P -Body $Body -User "LAB\$($Role.ToLower())1" -Role $Role -Query $Query -Options $Options
    }
    function script:Payload([string]$n, [string]$vm, [string]$t, [string]$p) {
        @{ Name = $n; GoldenImage = @{ VmName = $vm }; Pools = @{ Test = @{ Name = $t; LogoffPolicy = 'FORCE_LOGOFF' }; Production = @(@{ Name = $p; LogoffPolicy = 'WAIT_FOR_LOGOFF' }) } }
    }
    function script:Awaiting([string]$Id = 'w11-gi-01') {
        $ic = Get-GIImageConfig -Config (Cfg) -ImageId $Id
        $r = New-GIRun -Config $ic; $r.status = 'AwaitingApproval'; Save-GIRun -Config $ic -Run $r; $r.runId
    }
}

Describe 'Image API' {
    BeforeEach { $script:root = New-Root }
    AfterEach { Remove-Item $script:root -Recurse -Force -ErrorAction SilentlyContinue }

    Context 'reads' {
        It 'lists images with last and active run, without any live call' {
            $ic = Get-GIImageConfig -Config (Cfg) -ImageId 'w11-gi-01'; $r = New-GIRun -Config $ic
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $a = Api GET '/api/images' -Role Viewer
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 2
            $a.Code | Should -Be 200
            $a.Body.images[0].id | Should -Be 'w11-gi-01'
            $a.Body.images[0].activeRun.runId | Should -Be $r.runId
            $a.Body.images[0].productionPools | Should -Contain 'PRD-W11'
        }
        It 'returns 404 for an unknown image or bad id' {
            (Api GET '/api/images/nope/runs' -Role Viewer).Code | Should -Be 404
            (Api GET '/api/images/..%2f..%2fx/runs' -Role Viewer).Code | Should -Be 404
            (Api GET '/api/unknown' -Role Viewer).Code | Should -Be 404
        }
        It 'pages and filters runs' {
            $ic = Get-GIImageConfig -Config (Cfg) -ImageId 'w11-gi-01'
            foreach ($i in 1..3) { $r = New-GIRun -Config $ic -RunId "2026110$i-010101"; if ($i -eq 2) { $r.status = 'Failed'; Save-GIRun -Config $ic -Run $r } }
            (Api GET '/api/images/w11-gi-01/runs' -Role Viewer).Body.total | Should -Be 3
            (Api GET '/api/images/w11-gi-01/runs' -Role Viewer).Body.runs[0].runId | Should -Be '20261103-010101'
            (Api GET '/api/images/w11-gi-01/runs' -Role Viewer -Query @{ status = 'Failed' }).Body.runs.Count | Should -Be 1
        }
        It 'returns run detail with steps, approval evidence and the bundle link' {
            $id = Awaiting
            $b = (Api GET "/api/images/w11-gi-01/runs/$id" -Role Viewer).Body
            $b.imageId | Should -Be 'w11-gi-01'
            $b.approval.poolsToUpdate[0].name | Should -Be 'PRD-W11'
            $b.approval.nextWindow | Should -Not -BeNullOrEmpty
            $b.logBundleUrl | Should -Be "/api/images/w11-gi-01/runs/$id/logs.zip"
            (Api GET '/api/images/w11-gi-01/runs/20200101-000000' -Role Viewer).Code | Should -Be 404
        }
        It 'returns packages and never a password' {
            $b = (Api GET '/api/images/w11-gi-01/packages' -Role Viewer).Body
            @($b.packages).Count | Should -BeGreaterThan 5
            ($b.packages | Where-Object id -eq 'Horizon').selected | Should -BeTrue
            $all = (Api GET '/api/images' -Role Viewer).Body | ConvertTo-Json -Depth 10
            $all | Should -Not -Match '(?i)password'
        }
        It 'reads per-image and global settings' {
            (Api GET '/api/images/w11-gi-01/settings/General' -Role Viewer).Body.values.Name | Should -Be 'W11-GI-01'
            (Api GET '/api/images/w11-gi-01/settings/Pools' -Role Viewer).Code | Should -Be 200
            (Api GET '/api/settings/vCenter' -Role Viewer).Body.values.Server | Should -Be 'vcsa01.domain.local'
            (Api GET '/api/settings/Dashboard' -Role Viewer).Body.readOnly | Should -BeTrue
        }
    }

    Context 'roles' {
        It 'refuses every write for a Viewer with 403 and audits it' {
            $id = Awaiting
            $writes = @(
                @('POST', '/api/images'), @('DELETE', '/api/images/w11-gi-01'), @('POST', '/api/images/w11-gi-01/runs'),
                @('POST', "/api/images/w11-gi-01/runs/$id/retry"), @('POST', "/api/images/w11-gi-01/runs/$id/approve"), @('POST', "/api/images/w11-gi-01/runs/$id/reject"),
                @('POST', '/api/images/w11-gi-01/pause'), @('POST', '/api/images/w11-gi-01/resume'), @('POST', '/api/images/w11-gi-01/vm/power'),
                @('POST', '/api/images/w11-gi-01/vm/revert'), @('POST', '/api/images/w11-gi-01/pools/TST-W11/rollback'),
                @('POST', '/api/images/w11-gi-01/settings/Pools'), @('POST', '/api/settings/vCenter'), @('POST', '/api/settings/vCenter/test'))
            foreach ($w in $writes) { (Api $w[0] $w[1] @{} -Role Viewer).Code | Should -Be 403 -Because "$($w[0]) $($w[1])" }
            $denied = @(Get-GIAudit -Config (Cfg) -Last 50 | Where-Object action -eq 'auth.denied')
            $denied.Count | Should -Be $writes.Count
            $denied[0].role | Should -Be 'Viewer'
        }
        It 'lets an Approver approve and reject but nothing else' {
            foreach ($w in @(@('POST', '/api/images/w11-gi-01/runs'), @('POST', '/api/images/w11-gi-01/pause'), @('POST', '/api/images/w11-gi-01/vm/power'), @('POST', '/api/images/w11-gi-01/pools/TST-W11/rollback'), @('POST', '/api/images'))) {
                (Api $w[0] $w[1] @{} -Role Approver).Code | Should -Be 403
            }
            $id = Awaiting
            (Api POST "/api/images/w11-gi-01/runs/$id/reject" @{ comment = '' } -Role Approver).Code | Should -Be 400
            (Api POST "/api/images/w11-gi-01/runs/$id/reject" @{ comment = 'Bad test results' } -Role Approver).Code | Should -Be 200
            (Get-GIRun -Config (Get-GIImageConfig -Config (Cfg) -ImageId 'w11-gi-01') -RunId $id).status | Should -Be 'Rejected'
        }
        It 'names who already decided on a second decision' {
            $id = Awaiting
            $null = Api POST "/api/images/w11-gi-01/runs/$id/reject" @{ comment = 'no' } -Role Approver
            $r = Api POST "/api/images/w11-gi-01/runs/$id/approve" @{} -Role Approver
            $r.Code | Should -Be 409
            $r.Body.error | Should -Match 'Already rejected by LAB\\approver1 at'
        }
    }

    Context 'admin writes' {
        It 'creates an image (201), does not start a run, and rejects invalid payloads' {
            $r = Api POST '/api/images' (Payload 'Second' 'VM-2' 'T2' 'P2')
            $r.Code | Should -Be 201
            $r.Body.id | Should -Be 'second'
            @(Get-GIRunList -Config (Get-GIImageConfig -Config (Cfg) -ImageId 'second')).Count | Should -Be 0
            (Api POST '/api/images' (Payload 'Third' 'VM-2' 'T3' 'P3')).Code | Should -Be 400
            (Api POST '/api/images' (Payload 'Fourth' 'VM-4' 'TST-W11' 'P4')).Body.error | Should -Match 'A pool can belong to one image'
        }
        It 'saves a section and writes settings.update without secret values' {
            $r = Api POST '/api/images/w11-gi-01/settings/Promotion' @{ AutoPromote = $true }
            $r.Code | Should -Be 200
            $e = Get-GIAudit -Config (Cfg) -Last 5 | Where-Object action -eq 'settings.update' | Select-Object -First 1
            $e.detail.section | Should -Be 'Promotion'
            ($e | ConvertTo-Json -Depth 6) | Should -Not -Match '(?i)password|secret'
        }
        It 'pauses blocks and resumes runs' {
            (Api POST '/api/images/w11-gi-01/pause').Code | Should -Be 200
            $r = Api POST '/api/images/w11-gi-01/runs'
            $r.Code | Should -Be 409; $r.Body.error | Should -Match 'paused'
            (Api POST '/api/images/w11-gi-01/resume').Code | Should -Be 200
            (Api POST '/api/images/w11-gi-01/runs').Code | Should -Be 202
        }
        It 'refuses a second run on one image and allows runs on two images' {
            $null = Api POST '/api/images' (Payload 'Second' 'VM-2' 'T2' 'P2')
            (Api POST '/api/images/w11-gi-01/runs').Code | Should -Be 202
            $ic = Get-GIImageConfig -Config (Cfg) -ImageId 'w11-gi-01'
            $null = New-GIRun -Config $ic
            Remove-Item (Get-GIRequestPath $ic) -ErrorAction SilentlyContinue
            (Api POST '/api/images/w11-gi-01/runs').Code | Should -Be 409
            (Api POST '/api/images/second/runs').Code | Should -Be 202
        }
        It 'refuses to delete while a run is active and leaves vCenter and Horizon alone when it deletes' {
            function global:Connect-VIServer { throw 'no vCenter' }
            try {
                $null = Api POST '/api/images' (Payload 'Second' 'VM-2' 'T2' 'P2')
                $ic = Get-GIImageConfig -Config (Cfg) -ImageId 'second'; $r = New-GIRun -Config $ic
                (Api DELETE '/api/images/second').Code | Should -Be 409
                $r.status = 'Completed'; Save-GIRun -Config $ic -Run $r
                (Api DELETE '/api/images/second').Code | Should -Be 200
                Test-Path (Join-Path $ic.Paths.State "$($r.runId).json") | Should -BeTrue
            } finally { Remove-Item function:global:Connect-VIServer }
        }
        It 'retries only a failed run' {
            $ic = Get-GIImageConfig -Config (Cfg) -ImageId 'w11-gi-01'
            $r = New-GIRun -Config $ic -RunId '20261101-010101'; $r.status = 'Completed'; Save-GIRun -Config $ic -Run $r
            (Api POST '/api/images/w11-gi-01/runs/20261101-010101/retry').Code | Should -Be 409
            $r.status = 'Failed'; $r.currentStage = 'TestPush'; Save-GIRun -Config $ic -Run $r
            $x = Api POST '/api/images/w11-gi-01/runs/20261101-010101/retry'
            $x.Code | Should -Be 202; $x.Body.stage | Should -Be 'TestPush'
        }
        It 'powers and reverts the VM through the live worker and blocks both while a run is active' {
            $calls = [System.Collections.Generic.List[string]]::new()
            $inv = { param($n, $w, $a, $t) $calls.Add("$($a[1]):$($a[2])"); @{ Ok = $true; Data = 'ok' } }.GetNewClosure()
            (Api POST '/api/images/w11-gi-01/vm/power' @{ action = 'bogus' } -Options @{ LiveInvoker = $inv }).Code | Should -Be 400
            (Api POST '/api/images/w11-gi-01/vm/power' @{ action = 'on' } -Options @{ LiveInvoker = $inv }).Code | Should -Be 200
            (Api POST '/api/images/w11-gi-01/vm/revert' @{ snapshot = 'Baseline 26.11.01.0100' } -Options @{ LiveInvoker = $inv }).Code | Should -Be 200
            $calls | Should -Contain 'on:'
            $calls | Should -Contain 'revert:Baseline 26.11.01.0100'
            $null = New-GIRun -Config (Get-GIImageConfig -Config (Cfg) -ImageId 'w11-gi-01')
            (Api POST '/api/images/w11-gi-01/vm/power' @{ action = 'off' } -Options @{ LiveInvoker = $inv }).Code | Should -Be 409
            (Api POST '/api/images/w11-gi-01/vm/revert' @{ snapshot = 'x' } -Options @{ LiveInvoker = $inv }).Code | Should -Be 409
        }
        It 'rolls back one pool and refuses pools of other images' {
            $seen = @{}
            $runner = { param($a) $seen.p = $a; [pscustomobject]@{ PoolName = $a.PoolName; SnapshotName = 'Baseline 1' } }.GetNewClosure()
            $r = Api POST '/api/images/w11-gi-01/pools/PRD-W11/rollback' @{ snapshot = 'Baseline 1'; logoffPolicy = 'FORCE_LOGOFF' } -Options @{ RollbackRunner = $runner }
            $r.Code | Should -Be 200
            $seen.p.ForceLogoff | Should -BeTrue
            (Api POST '/api/images/w11-gi-01/pools/OTHER/rollback' @{} -Options @{ RollbackRunner = $runner }).Code | Should -Be 404
            (Api POST '/api/images/w11-gi-01/pools/PRD-W11/rollback' @{ logoffPolicy = 'NOPE' } -Options @{ RollbackRunner = $runner }).Code | Should -Be 400
            (Get-GIAudit -Config (Cfg) -Last 10 | Where-Object action -eq 'pool.rollback').Count | Should -BeGreaterThan 0
        }
        It 'Invoke-GIRollback marks the related run RolledBack' {
            $ic = Get-GIImageConfig -Config (Cfg) -ImageId 'w11-gi-01'
            $run = New-GIRun -Config $ic; $run.status = 'Completed'; Save-GIRun -Config $ic -Run $run
            InModuleScope VDI-GIPipeline -Parameters @{ ic = $ic; id = $run.runId } {
                param($ic, $id)
                Mock Get-GIHorizonBaseImage { @{ BaseVm = @{ id = 'vm1' }; Snapshot = @{ id = 's1' } } }
                Mock Get-GIHorizonPool { @{ id = 'p1' } }
                Mock Get-GIPoolImageInfo { [pscustomobject]@{ PendingSnapshotId = $null } }
                Mock Invoke-GIHorizonPushImage {}
                $null = Invoke-GIRollback -Config $ic -PoolName 'PRD-W11' -SnapshotName 'Baseline 1' -RunId $id
                (Get-GIRun -Config $ic -RunId $id).status | Should -Be 'RolledBack'
            }
        }
        It 'tests unsaved values without saving them' {
            $got = @{}
            $runner = { param($cp, $s, $o) $got.o = $o; $got.s = $s; @{ ok = $true; detail = 'fine'; seconds = 1 } }.GetNewClosure()
            $r = Api POST '/api/settings/vCenter/test' @{ Server = 'other.example.com'; CredentialSecret = 'x' } -Options @{ TestRunner = $runner }
            $r.Body.ok | Should -BeTrue
            $got.o.vCenter.Server | Should -Be 'other.example.com'
            $got.o.vCenter.Keys | Should -Not -Contain 'CredentialSecret'
            (Cfg).vCenter.Server | Should -Be 'vcsa01.domain.local'
        }
        It 'remembers only the result and time of a global connection test, and forgets it when the section is saved' {
            $runner = { param($cp, $s, $o) @{ ok = $false; detail = 'password Hunter2 rejected'; seconds = 1 } }
            $null = Api POST '/api/settings/vCenter/test' @{ Server = 'vc1' } -Options @{ TestRunner = $runner }
            (Get-GIConnectionStatus -Config (Cfg) -Section vCenter).State | Should -Be 'Failed'
            (Get-GIConnectionStatus -Config (Cfg) -Section Horizon).State | Should -Be 'NotTested'
            (Get-Content (Get-GIConnectionStatePath -Config (Cfg)) -Raw) | Should -Not -Match 'Hunter2'
            $ok = { param($cp, $s, $o) @{ ok = $true; detail = 'fine'; seconds = 1 } }
            $null = Api POST '/api/settings/vCenter/test' @{ Server = 'vc1' } -Options @{ TestRunner = $ok }
            (Get-GIConnectionStatus -Config (Cfg) -Section vCenter).State | Should -Be 'Connected'
            (Api POST '/api/settings/vCenter' @{ Server = 'vc-new.example.com' }).Code | Should -Be 200
            (Get-GIConnectionStatus -Config (Cfg) -Section vCenter).State | Should -Be 'NotTested'
        }
        It 'tests the Guest VM and Pools sections of one image with the unsaved form values' {
            $got = @{}
            $runner = { param($cp, $s, $o, $i) $got.o = $o; $got.s = $s; $got.i = $i; @{ ok = $true; detail = 'fine'; seconds = 1 } }.GetNewClosure()
            $r = Api POST '/api/images/w11-gi-01/settings/GoldenImage/test' @{ VmName = 'OTHER-VM'; ScriptPathInGuest = 'C:\x.ps1'; GuestWorkDir = 'C:\w'; FinalizeAction = 'Finalize'; PowerOffTimeoutMin = '30'; GuestCredentialSecret = 'must-not-pass' } -Options @{ TestRunner = $runner }
            $r.Code | Should -Be 200; $r.Body.ok | Should -BeTrue
            $got.s | Should -Be 'GoldenImage'; $got.i | Should -Be 'w11-gi-01'
            $got.o.GoldenImage.VmName | Should -Be 'OTHER-VM'
            $got.o.GoldenImage.Keys | Should -Not -Contain 'GuestCredentialSecret'
            (Get-GIImageConfig -Config (Cfg) -ImageId 'w11-gi-01').GoldenImage.VmName | Should -Not -Be 'OTHER-VM'   # nothing saved
            $p = Api POST '/api/images/w11-gi-01/settings/Pools/test' @{ 'Test.Name' = 'TST-NEW'; 'Test.LogoffPolicy' = 'FORCE_LOGOFF'; 'Production[0].Name' = 'PRD-NEW'; 'Production[0].LogoffPolicy' = 'WAIT_FOR_LOGOFF'; PushTimeoutMin = '120' } -Options @{ TestRunner = $runner }
            $p.Code | Should -Be 200
            $got.o.Pools.Test.Name | Should -Be 'TST-NEW'
            @($got.o.Pools.Production)[0].Name | Should -Be 'PRD-NEW'
        }
        It 'refuses the image test for Viewers and Approvers, for sections without a test, and for bad values' {
            $ok = { param($cp, $s, $o, $i) @{ ok = $true; detail = 'x'; seconds = 1 } }
            (Api POST '/api/images/w11-gi-01/settings/Pools/test' @{} -Role Viewer -Options @{ TestRunner = $ok }).Code | Should -Be 403
            (Api POST '/api/images/w11-gi-01/settings/Pools/test' @{} -Role Approver -Options @{ TestRunner = $ok }).Code | Should -Be 403
            (Api POST '/api/images/w11-gi-01/settings/Snapshots/test' @{} -Options @{ TestRunner = $ok }).Code | Should -Be 404
            (Api POST '/api/images/nope/settings/Pools/test' @{} -Options @{ TestRunner = $ok }).Code | Should -Be 404
            (Api POST '/api/images/w11-gi-01/settings/GoldenImage/test' @{ VmName = ''; PowerOffTimeoutMin = '1' } -Options @{ TestRunner = $ok }).Code | Should -Be 400
        }
        It 'turns an unexpected failure into a 500 with an error id and no stack trace' {
            Mock Get-GIImageSummary { throw 'boom at C:\secret\path' } -ModuleName VDI-GIPipeline
            $r = Invoke-GIApiRequest -Config (Cfg) -Method GET -Path '/api/images' -Role Viewer
            $r.Code | Should -Be 500
            $r.Body.errorId | Should -Match '^[0-9a-f]{8}$'
            ($r.Body | ConvertTo-Json) | Should -Not -Match 'secret'
        }
    }
}

Describe 'Live state' {
    BeforeEach { $script:root = New-Root }
    AfterEach { Remove-Item $script:root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'reports each failing source by name and still returns the other one' {
        $inv = { param($n, $w, $a, $t) if ($n -eq 'vCenter') { @{ Ok = $false; Error = 'vCenter did not answer within 15 seconds' } } else { @{ Ok = $true; Data = [pscustomobject]@{ pools = @([pscustomobject]@{ pool = 'TST-W11'; snapshot = 'B1'; pending = ''; state = '' }) } } } }
        $r = Api GET '/api/images/w11-gi-01/live' -Role Viewer -Options @{ LiveInvoker = $inv }
        $r.Code | Should -Be 200
        $r.Body.errors | Should -Be 'vCenter did not answer within 15 seconds'
        $r.Body.vm | Should -BeNullOrEmpty
        $r.Body.pools[0].pool | Should -Be 'TST-W11'
    }
    It 'marks pools that match the latest VM snapshot' {
        $inv = { param($n, $w, $a, $t)
            if ($n -eq 'vCenter') { @{ Ok = $true; Data = [pscustomobject]@{ power = 'PoweredOff'; snapshots = @([pscustomobject]@{ name = 'B1'; created = '2026-11-01T00:00:00'; isCurrent = $false }, [pscustomobject]@{ name = 'B2'; created = '2026-11-08T00:00:00'; isCurrent = $true }) } } } else { @{ Ok = $true; Data = [pscustomobject]@{ pools = @([pscustomobject]@{ pool = 'TST-W11'; snapshot = 'B2' }, [pscustomobject]@{ pool = 'PRD-W11'; snapshot = 'B1' }) } } } }
        $b = (Api GET '/api/images/w11-gi-01/live' -Role Viewer -Options @{ LiveInvoker = $inv }).Body
        $b.vm.power | Should -Be 'PoweredOff'
        ($b.pools | Where-Object pool -eq 'TST-W11').matchesLatest | Should -BeTrue
        ($b.pools | Where-Object pool -eq 'PRD-W11').matchesLatest | Should -BeFalse
        $b.errors.Count | Should -Be 0
    }
    It 'stops waiting after the time limit and names the source' {
        InModuleScope VDI-GIPipeline {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-GILiveSource -Name 'TimeoutTest' -Work { Start-Sleep -Seconds 20 } -TimeoutSec 1
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 8
            $r.Ok | Should -BeFalse
            $r.Error | Should -Be 'TimeoutTest did not answer within 1 seconds'
        }
    }
    It 'reuses the same worker session between calls and recovers after a timeout' {
        InModuleScope VDI-GIPipeline {
            $a = Invoke-GILiveSource -Name 'ReuseTest' -Work { $global:giCount = 1 + [int]$global:giCount; $global:giCount }
            $b = Invoke-GILiveSource -Name 'ReuseTest' -Work { $global:giCount = 1 + [int]$global:giCount; $global:giCount }
            $a.Data | Should -Be 1; $b.Data | Should -Be 2
            $null = Invoke-GILiveSource -Name 'ReuseTest' -Work { Start-Sleep -Seconds 20 } -TimeoutSec 1
            (Invoke-GILiveSource -Name 'ReuseTest' -Work { 'again' }).Data | Should -Be 'again'
            Stop-GILiveWorker 'ReuseTest'
        }
    }
    It 'surfaces an error thrown inside the worker' {
        InModuleScope VDI-GIPipeline {
            $r = Invoke-GILiveSource -Name 'ErrTest' -Work { throw 'login refused' }
            $r.Ok | Should -BeFalse; $r.Error | Should -Match 'login refused'
            Stop-GILiveWorker 'ErrTest'
        }
    }
}

Describe 'Wizard validation per step (gap 13)' {
    BeforeEach { $script:root = New-Root }
    AfterEach { Remove-Item $script:root -Recurse -Force -ErrorAction SilentlyContinue }
    function script:Dry([int]$Step, $Body, [string]$Role = 'Admin') {
        $q = @{ dryRun = '1' }; if ($Step) { $q.step = [string]$Step }
        Api POST '/api/images' $Body -Role $Role -Query $q
    }
    BeforeAll {
        function script:Good { Payload 'Win10-Lab' 'GI-W10-01' 'TST-W10' 'PRD-W10' }
    }
    It 'step 1 reports only the name problems, and nothing about VM or pools that are still empty' {
        $r = Dry 1 @{ Name = ''; GoldenImage = @{ VmName = '' }; Pools = @{ Test = @{ Name = '' }; Production = @() } }
        $r.Code | Should -Be 400; $r.Body.error | Should -Match 'Name: required'; $r.Body.error | Should -Not -Match 'VM|pool'
        (Dry 1 @{ Name = '<b>x</b>' }).Body.error | Should -Match 'letters, numbers and dashes'
        (Dry 1 @{ Name = 'W11-GI-01' }).Body.error | Should -Match 'is used twice'   # the existing image's name
        (Dry 1 (Good)).Code | Should -Be 200
    }
    It 'step 2 reports VM and pool problems, including ones used by another image' {
        $r = Dry 2 @{ Name = 'Win10-Lab'; GoldenImage = @{ VmName = '' }; Pools = @{ Test = @{ Name = 'TST-W10'; LogoffPolicy = 'FORCE_LOGOFF' }; Production = @(@{ Name = 'TST-W10'; LogoffPolicy = 'WAIT_FOR_LOGOFF' }) } }
        $r.Code | Should -Be 400; $r.Body.error | Should -Match 'no VM name'; $r.Body.error | Should -Match 'both test pool and production pool'
        $cfg = Get-GIImageConfig -Config (Cfg) -ImageId 'w11-gi-01'
        $taken = Payload 'Win10-Lab' $cfg.GoldenImage.VmName 'TST-W10' $cfg.Pools.Test.Name
        $t = Dry 2 $taken
        $t.Code | Should -Be 400; $t.Body.error | Should -Match 'belongs to image'
        (Dry 2 (Good)).Code | Should -Be 200
    }
    It 'step 3 and 4 report their own sections only' {
        $b = Good; $b.GoldenImage.PowerOffTimeoutMin = 1; $b.Promotion = @{ AutoPromote = $false; MaintenanceWindow = @{ Days = @(); StartTime = '25:99' } }
        $s3 = Dry 3 $b; $s3.Code | Should -Be 400; $s3.Body.error | Should -Match 'GoldenImage\.PowerOffTimeoutMin'; $s3.Body.error | Should -Not -Match 'Promotion'
        $s4 = Dry 4 $b; $s4.Code | Should -Be 400; $s4.Body.error | Should -Match 'Promotion\.'; $s4.Body.error | Should -Not -Match 'PowerOffTimeoutMin'
        (Dry 2 $b).Code | Should -Be 200   # step 2 does not care about steps 3 and 4
        (Dry 0 $b).Body.error | Should -Match 'PowerOffTimeoutMin'   # the review step reports everything
        (Dry 0 $b).Body.error | Should -Match 'Promotion\.'
    }
    It 'refuses a step outside 1 to 4, saves nothing, and stays Admin only' {
        (Dry 9 (Good)).Code | Should -Be 400
        (Api POST '/api/images' (Good) -Query @{ dryRun = '1'; step = 'x' }).Code | Should -Be 400
        (Dry 2 (Good) 'Approver').Code | Should -Be 403
        (Dry 2 (Good) 'Viewer').Code | Should -Be 403
        @((Api GET '/api/images' -Role Viewer).Body.images).Count | Should -Be 1
    }
}

Describe 'Installer status for the wizard (gap 13)' {
    BeforeEach { $script:root = New-Root }
    AfterEach { Remove-Item $script:root -Recurse -Force -ErrorAction SilentlyContinue }
    It 'lists known packages for a folder on the pipeline host, Admin only, read only' {
        $dir = Join-Path $script:root 'inst'; New-Item -ItemType Directory $dir | Out-Null
        Set-Content (Join-Path $dir 'VMware-tools-12.5.0-x86_64.exe') 'x'
        $r = Api GET '/api/packages' -Query @{ folder = $dir }
        $r.Code | Should -Be 200
        $r.Body.folder | Should -Be $dir
        ($r.Body.packages | Where-Object id -eq 'VmTools').state | Should -Be 'Found'
        ($r.Body.packages | Where-Object id -eq 'VmTools').file | Should -Be 'VMware-tools-12.5.0-x86_64.exe'
        ($r.Body.packages | Where-Object id -eq 'Horizon').state | Should -Be 'Missing'
        ($r.Body.packages | Where-Object id -eq 'MsTeams').state | Should -Be 'Download'
        (Api GET '/api/packages' -Role Viewer -Query @{ folder = $dir }).Code | Should -Be 403
        (Api GET '/api/packages' -Role Approver -Query @{ folder = $dir }).Code | Should -Be 403
    }
    It 'says so when the folder is missing, and refuses control characters and very long paths' {
        $r = Api GET '/api/packages' -Query @{ folder = (Join-Path $script:root 'nope') }
        $r.Body.folderError | Should -Match 'not found on the pipeline host'
        ($r.Body.packages | Select-Object -First 1).state | Should -Be 'Missing'
        (Api GET '/api/packages' -Query @{ folder = "a`nb" }).Code | Should -Be 400
        (Api GET '/api/packages' -Query @{ folder = ('x' * 300) }).Code | Should -Be 400
        (Api GET '/api/packages' -Query @{ folder = '' }).Body.packages[0].state | Should -Be 'NoFolder'
    }
}

Describe 'Overview data: retention preview, last pushed, resumed steps (gaps 6 and 12)' {
    BeforeEach { $script:root = New-Root }
    AfterEach { Remove-Item $script:root -Recurse -Force -ErrorAction SilentlyContinue }
    It 'marks snapshots the next retention pass would remove, using the real decision function' {
        $ic = Get-GIImageConfig -Config (Cfg) -ImageId 'w11-gi-01'
        $ic.Snapshots.Keep = 1; $ic.Snapshots.Mode = 'Chain'
        $snaps = @(
            [pscustomobject]@{ name = 'Baseline 1'; created = '2026-10-01T00:00:00'; id = 's1'; parentId = '' }
            [pscustomobject]@{ name = 'Baseline 2'; created = '2026-10-08T00:00:00'; id = 's2'; parentId = 's1' }
            [pscustomobject]@{ name = 'Baseline 3'; created = '2026-10-15T00:00:00'; id = 's3'; parentId = 's2' }
            [pscustomobject]@{ name = 'Baseline 4'; created = '2026-10-22T00:00:00'; id = 's4'; parentId = 's3' }
            [pscustomobject]@{ name = 'Manual keep'; created = '2026-10-23T00:00:00'; id = 's5'; parentId = 's4' })
        $pools = @([pscustomobject]@{ pool = 'TST-W11'; snapshot = 'Baseline 4'; pending = '' }, [pscustomobject]@{ pool = 'PRD-W11'; snapshot = 'Baseline 2'; pending = '' })
        $out = InModuleScope VDI-GIPipeline -Parameters @{ ic = $ic; snaps = $snaps; pools = $pools } { param($ic, $snaps, $pools) Get-GILiveOutsideRetention -ImageConfig $ic -Snapshots $snaps -Pools $pools -LastKnownGood '' }
        # Keep 1: Baseline 4 is the newest and in use, Baseline 2 is in use, Baseline 1 is the root, 'Manual keep' is not a pipeline snapshot. Only Baseline 3 goes.
        @($out | ForEach-Object { $_.name }) | Should -Be @('Baseline 3')
        @($out)[0].reason | Should -Be 'Older than retention'
    }
    It 'adds outsideRetention to the live answer only when vCenter and Horizon both answered' {
        $vc = { param($n, $w, $a, $t) if ($n -eq 'vCenter') { @{ Ok = $true; Data = [pscustomobject]@{ power = 'PoweredOff'; snapshots = @([pscustomobject]@{ name = 'Baseline 1'; created = '2026-10-01T00:00:00'; isCurrent = $false; id = 's1'; parentId = '' }) } } } else { @{ Ok = $false; Error = 'Horizon down' } } }
        $b = (Api GET '/api/images/w11-gi-01/live' -Role Viewer -Options @{ LiveInvoker = $vc }).Body
        $b.vm.outsideRetention | Should -BeNullOrEmpty
        $b.vm.snapshots[0].Keys | Should -Not -Contain 'id'   # vCenter ids are not passed on to the page
        $both = { param($n, $w, $a, $t) if ($n -eq 'vCenter') { @{ Ok = $true; Data = [pscustomobject]@{ power = 'PoweredOff'; snapshots = @([pscustomobject]@{ name = 'Baseline 1'; created = '2026-10-01T00:00:00'; isCurrent = $false; id = 's1'; parentId = '' }) } } } else { @{ Ok = $true; Data = [pscustomobject]@{ pools = @() } } } }
        $c = (Api GET '/api/images/w11-gi-01/live' -Role Viewer -Options @{ LiveInvoker = $both }).Body
        $c.vm.Keys | Should -Contain 'outsideRetention'
    }
    It 'finds when each pool last received an image from the run history, newest first' {
        $ic = Get-GIImageConfig -Config (Cfg) -ImageId 'w11-gi-01'
        $old = New-GIRun -Config $ic -RunId '20261101-020000'
        $old.snapshot = [pscustomobject]@{ name = 'Baseline 1' }
        $old.stages.TestPush.status = 'Succeeded'; $old.stages.TestPush.endedAt = '2026-11-01T02:30:00'
        $old.promotion = [pscustomobject]@{ pools = @([pscustomobject]@{ poolName = 'PRD-W11'; status = 'Succeeded'; scheduledStart = '2026-11-03T22:00:00' }) }
        Save-GIRun -Config $ic -Run $old
        $new = New-GIRun -Config $ic -RunId '20261115-020000'
        $new.snapshot = [pscustomobject]@{ name = 'Baseline 2' }
        $new.stages.TestPush.status = 'Succeeded'; $new.stages.TestPush.endedAt = '2026-11-15T02:30:00'
        $new.promotion = [pscustomobject]@{ pools = @([pscustomobject]@{ poolName = 'PRD-W11'; status = 'Cancelled'; scheduledStart = '2026-11-17T22:00:00' }) }
        Save-GIRun -Config $ic -Run $new
        $lp = InModuleScope VDI-GIPipeline -Parameters @{ ic = $ic } { param($ic) Get-GIPoolLastPushed -ImageConfig $ic }
        $lp['TST-W11'].snapshot | Should -Be 'Baseline 2'; $lp['TST-W11'].runId | Should -Be '20261115-020000'
        $lp['PRD-W11'].snapshot | Should -Be 'Baseline 1'; ([datetime]$lp['PRD-W11'].at).Date | Should -Be ([datetime]'2026-11-03')   # the cancelled push does not count
        (InModuleScope VDI-GIPipeline -Parameters @{ ic = (Get-GIImageConfig -Config (Cfg) -ImageId 'w11-gi-01') } { param($ic) Get-GIPoolLastPushed -ImageConfig $ic -Last 1 })['PRD-W11'] | Should -BeNullOrEmpty
    }
    It 'tags steps kept from an earlier attempt as resumed in the run detail' {
        $ic = Get-GIImageConfig -Config (Cfg) -ImageId 'w11-gi-01'
        $run = New-GIRun -Config $ic -RunId '20261120-020000'
        Add-Member -InputObject $run.stages.Maintain -NotePropertyName steps -NotePropertyValue @(
            [pscustomobject]@{ id = 'SafetySnapshot'; label = 'Safety snapshot'; status = 'Succeeded'; startedAt = $null; endedAt = $null; message = 'taken (earlier attempt)'; resumed = $true }
            [pscustomobject]@{ id = 'PowerOn'; label = 'Power on'; status = 'Succeeded'; startedAt = $null; endedAt = $null; message = 'on' }
            [pscustomobject]@{ id = 'OldRun'; label = 'Old format'; status = 'Succeeded'; startedAt = $null; endedAt = $null; message = 'ok (earlier attempt)' }) -Force
        Save-GIRun -Config $ic -Run $run
        $s = (Api GET '/api/images/w11-gi-01/runs/20261120-020000' -Role Viewer).Body.steps
        ($s | Where-Object id -eq 'SafetySnapshot').resumed | Should -BeTrue
        ($s | Where-Object id -eq 'PowerOn').resumed | Should -BeFalse
        ($s | Where-Object id -eq 'OldRun').resumed | Should -BeTrue   # runs saved before the flag existed
    }
}
