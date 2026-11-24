BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'VDI-GIPipeline.psd1') -Force
    . (Join-Path $PSScriptRoot '..' 'Web' 'DashboardViews.ps1')
    $script:secret = [byte[]](1..32)
    function New-Event($Groups, $User = 'jdoe', $Domain = 'DOMAIN') {
        [pscustomobject]@{ Auth = [pscustomobject]@{ User = [pscustomobject]@{ Username = $User; Domain = $Domain; Groups = $Groups } } }
    }
}

Describe 'Form tokens' {
    It 'round-trips for the same user and run' {
        $t = Get-GIFormToken -Secret $secret -User 'DOMAIN\jdoe' -RunId '20261124-120000'
        Test-GIFormToken -Secret $secret -User 'DOMAIN\jdoe' -RunId '20261124-120000' -Token $t | Should -BeTrue
    }
    It 'is case-insensitive on the user name' {
        $t = Get-GIFormToken -Secret $secret -User 'DOMAIN\JDoe' -RunId '20261124-120000'
        Test-GIFormToken -Secret $secret -User 'domain\jdoe' -RunId '20261124-120000' -Token $t | Should -BeTrue
    }
    It 'rejects another user, another run, another secret, or no token' {
        $t = Get-GIFormToken -Secret $secret -User 'DOMAIN\jdoe' -RunId '20261124-120000'
        Test-GIFormToken -Secret $secret -User 'DOMAIN\other' -RunId '20261124-120000' -Token $t | Should -BeFalse
        Test-GIFormToken -Secret $secret -User 'DOMAIN\jdoe' -RunId '20261124-120001' -Token $t | Should -BeFalse
        Test-GIFormToken -Secret ([byte[]](2..33)) -User 'DOMAIN\jdoe' -RunId '20261124-120000' -Token $t | Should -BeFalse
        Test-GIFormToken -Secret $secret -User 'DOMAIN\jdoe' -RunId '20261124-120000' -Token '' | Should -BeFalse
    }
}

Describe 'Approver checks' {
    BeforeAll { $ctx = @{ NoAuth = $false; ApproverShort = 'VDI-Pipeline-Approvers' } }
    It 'allows members of the approver group' {
        Test-GIDashboardApprover -Context $ctx -WebEvent (New-Event @('VDI-Pipeline-Viewers', 'VDI-Pipeline-Approvers')) | Should -BeTrue
    }
    It 'refuses viewers, unauthenticated callers, and everyone in NoAuth mode' {
        Test-GIDashboardApprover -Context $ctx -WebEvent (New-Event @('VDI-Pipeline-Viewers')) | Should -BeFalse
        Test-GIDashboardApprover -Context $ctx -WebEvent ([pscustomobject]@{ Auth = $null }) | Should -BeFalse
        Test-GIDashboardApprover -Context @{ NoAuth = $true; ApproverShort = 'VDI-Pipeline-Approvers' } -WebEvent (New-Event @('VDI-Pipeline-Approvers')) | Should -BeFalse
    }
    It 'reports DOMAIN\user, or anonymous in NoAuth mode' {
        Get-GIDashboardUser -Context $ctx -WebEvent (New-Event @()) | Should -Be 'DOMAIN\jdoe'
        Get-GIDashboardUser -Context @{ NoAuth = $true } -WebEvent (New-Event @()) | Should -Be 'anonymous'
    }
}

Describe 'Approval form' {
    It 'encodes values and posts to the decision route' {
        $html = New-GIApprovalForm -RunId '20261124-120000' -Token 'a"b' -DefaultStart ([datetime]'2026-11-28 22:00')
        $html | Should -Match 'action="/runs/20261124-120000/decision"'
        $html | Should -Match 'value="2026-11-28T22:00"'
        $html | Should -Match 'a&quot;b'
    }
    It 'detail page shows the form only when passed in' {
        $run = '{"runId":"20261124-120000","status":"AwaitingApproval","stages":{},"approval":{"decision":null}}' | ConvertFrom-Json
        New-GIRunDetailPage -Run $run | Should -Not -Match '<form'
        New-GIRunDetailPage -Run $run -ApprovalFormHtml '<form id="x"></form>' | Should -Match '<form id="x">'
    }
}
