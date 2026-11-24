BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'src' 'Report.ps1')

    $script:RunJson = @'
{
  "schemaVersion": 1,
  "runId": "20261124-213005",
  "goldenVm": "W11-GI-01",
  "createdAt": "2026-11-24T21:30:05.0000000-05:00",
  "updatedAt": "2026-11-24T22:10:05.0000000-05:00",
  "status": "AwaitingApproval",
  "currentStage": "Approval",
  "progress": "",
  "stages": {
    "Preflight": { "status": "Succeeded", "startedAt": "2026-11-24T21:30:05.0000000-05:00", "endedAt": "2026-11-24T21:31:35.0000000-05:00", "message": "", "data": {} },
    "Maintain":  { "status": "Failed", "startedAt": "2026-11-24T21:31:35.0000000-05:00", "endedAt": null, "message": "bad <script>alert(1)</script> & more", "data": {} },
    "Approval":  { "status": "Running", "startedAt": null, "endedAt": null, "message": "", "data": {} }
  },
  "safetySnapshot": { "id": "s1", "name": "pre-maint-20261124-213005" },
  "snapshot": {
    "id": "VirtualMachineSnapshot-snapshot-124",
    "name": "GI-20261124-213005",
    "createdAt": "2026-11-24T21:50:00.0000000-05:00",
    "manifest": { "VmTools": "12.5.0", "Horizon": "2512.0.0" }
  },
  "validation": {
    "passed": false,
    "checks": [
      { "category": "Horizon", "name": "MachineState", "target": "TST-W11-001", "passed": true, "detail": "AVAILABLE" },
      { "category": "Guest", "name": "ServiceRunning", "target": "frxsvc", "passed": false, "detail": "Stopped" }
    ]
  },
  "approval": { "decision": "Approved", "by": "DOMAIN\\alice", "at": "2026-11-24T22:00:00.0000000-05:00", "startTime": "2026-11-28T22:00:00.0000000-05:00", "comment": "ship it" },
  "promotion": {
    "pools": [ { "poolName": "PRD-W11", "poolId": "p1", "scheduledStart": "2026-11-28T22:00:00.0000000-05:00", "status": "Scheduled", "message": "" } ]
  },
  "error": "Maintain exploded"
}
'@
    $script:Run = $script:RunJson | ConvertFrom-Json
}

Describe 'ConvertTo-GIReportHtml' {
    It 'contains run id, vm, status and stage names' {
        $html = ConvertTo-GIReportHtml -Run $script:Run
        $html | Should -Match '20261124-213005'
        $html | Should -Match 'W11-GI-01'
        $html | Should -Match 'AwaitingApproval'
        foreach ($s in 'Preflight', 'Maintain', 'Approval') { $html | Should -Match $s }
    }
    It 'contains snapshot, manifest, check rows, approval, promotion and error' {
        $html = ConvertTo-GIReportHtml -Run $script:Run
        $html | Should -Match 'GI-20261124-213005'
        $html | Should -Match '12\.5\.0'
        $html | Should -Match 'MachineState'
        $html | Should -Match 'ServiceRunning'
        $html | Should -Match 'Overall: FAILED'
        $html | Should -Match 'ship it'
        $html | Should -Match 'PRD-W11'
        $html | Should -Match 'Maintain exploded'
    }
    It 'computes stage duration' {
        (ConvertTo-GIReportHtml -Run $script:Run) | Should -Match '00:01:30'
    }
    It 'HTML-encodes values' {
        $html = ConvertTo-GIReportHtml -Run $script:Run
        $html | Should -Not -Match '<script>'
        $html | Should -Match '&lt;script&gt;alert\(1\)&lt;/script&gt; &amp; more'
    }
    It 'handles null validation, approval, promotion, snapshot and error' {
        $r = $script:RunJson | ConvertFrom-Json
        $r.validation = $null; $r.approval = $null; $r.promotion = $null; $r.snapshot = $null; $r.error = $null
        $html = ConvertTo-GIReportHtml -Run $r
        $html | Should -Match '20261124-213005'
        $html | Should -Not -Match 'Overall:'
    }
    It 'handles a minimal run' {
        $r = [pscustomobject]@{ runId = 'x'; goldenVm = 'vm'; status = 'Running' }
        { ConvertTo-GIReportHtml -Run $r } | Should -Not -Throw
    }
    It 'shows PASSED when all checks pass' {
        $r = $script:RunJson | ConvertFrom-Json
        $r.validation.passed = $true
        $r.validation.checks[1].passed = $true
        (ConvertTo-GIReportHtml -Run $r) | Should -Match 'Overall: PASSED'
    }
}

Describe 'Save-GIReport' {
    It 'writes <runId>.html under Paths.Reports' {
        $cfg = @{ Paths = @{ Reports = (Join-Path $TestDrive 'reports') } }
        $path = Save-GIReport -Config $cfg -Run $script:Run
        $path | Should -Be (Join-Path $cfg.Paths.Reports '20261124-213005.html')
        Test-Path $path | Should -BeTrue
        (Get-Content -Raw $path) | Should -Match 'W11-GI-01'
    }
}

Describe 'Send-GIReport' {
    It 'returns without error when email is disabled' {
        $cfg = @{ Email = @{ Enabled = $false } }
        { Send-GIReport -Config $cfg -Run $script:Run } | Should -Not -Throw
    }
    It 'warns instead of throwing on send failure' {
        $cfg = @{ Email = @{ Enabled = $true; SmtpServer = '127.0.0.1'; Port = 1; From = 'a@b.c'; To = @('d@e.f'); UseSsl = $false } }
        { Send-GIReport -Config $cfg -Run $script:Run -WarningAction SilentlyContinue } | Should -Not -Throw
    }
}
