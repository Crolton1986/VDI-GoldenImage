BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'VDI-GIPipeline.psd1') -Force
    . (Join-Path $PSScriptRoot '..' 'Web' 'DashboardViews.ps1')
    . (Join-Path $PSScriptRoot '..' 'Web' 'Components.ps1')
}

Describe 'Shared components' {
    It 'button: variants, small, disabled keeps label and explains why' {
        New-GIButton -Label 'Start run' -Variant pri | Should -Match '<button type="button" class="btn pri">Start run</button>'
        New-GIButton -Label 'Roll back pool' -Variant danger -Small | Should -Match 'class="btn danger small"'
        $h = New-GIButton -Label 'Start run' -Disabled -Reason 'Only admins can start runs' -Id 'go'
        $h | Should -Match ' disabled'
        $h | Should -Match 'title="Only admins can start runs"'
        $h | Should -Match 'aria-describedby="go-why"'
        $h | Should -Match '>Start run</button>'
        $h | Should -Match 'id="go-why"'
    }
    It 'button: encodes the label and renders links as anchors' {
        New-GIButton -Label '<b>x</b>' | Should -Not -Match '<b>'
        New-GIButton -Label 'Open' -Href '/images/a b' | Should -Match '<a class="btn" href="/images/a b">Open</a>'
    }
    It 'chip always carries text and a variant' {
        New-GIChip -Text 'Failed' -Variant bad | Should -Be '<span class="chip bad">Failed</span>'
    }
    It 'tabs are real links and mark the selected one' {
        $h = New-GITabs -Tabs @(@{ Label = 'Overview'; Href = '/images/a'; Key = 'overview' }, @{ Label = 'Runs'; Href = '/images/a/runs'; Key = 'runs' }) -Selected 'runs'
        $h | Should -Match 'role="tablist"'
        $h | Should -Match '<a role="tab" aria-selected="true" href="/images/a/runs" aria-current="page">Runs</a>'
        $h | Should -Match '<a role="tab" aria-selected="false" href="/images/a">Overview</a>'
    }
    It 'table has scoped headers and an empty row' {
        $h = New-GITable -Columns 'A', 'B' -Rows @() -EmptyText 'Nothing here'
        $h | Should -Match '<th scope="col">A</th>'
        $h | Should -Match 'Nothing here'
    }
    It 'field wires label, help and error, and marks required' {
        $h = New-GIField -Name 'vm' -Label 'VM name' -Help 'As in vCenter' -Error 'Required' -Required
        $h | Should -Match '<label for="vm">VM name'
        $h | Should -Match 'aria-describedby="vm-help vm-err"'
        $h | Should -Match 'aria-invalid="true"'
        $h | Should -Match '\(required\)'
        $h | Should -Match 'id="vm-err"'
    }
    It 'field: select marks the current value and textarea encodes' {
        New-GIField -Name 'p' -Label 'P' -Type select -Options 'a', 'b' -Value 'b' | Should -Match '<option value="b" selected>'
        New-GIField -Name 't' -Label 'T' -Type textarea -Value '<x>' | Should -Match '&lt;x&gt;'
    }
    It 'save bar starts clean with disabled buttons' {
        $h = New-GISaveBar -FormId 'f1'
        $h | Should -Match 'No unsaved changes'
        $h | Should -Match 'form="f1" class="btn pri" data-savebar-save disabled>Save changes'
        $h | Should -Match 'data-savebar-discard disabled>Discard'
    }
    It 'sub-nav and stepper mark the current entry' {
        New-GISubNav -Items @(@{ Label = 'vCenter'; Href = '/settings/vCenter'; Key = 'vCenter' }) -Selected 'vCenter' | Should -Match 'aria-current="page">vCenter'
        $h = New-GIStepper -Steps 'One', 'Two', 'Three' -Current 2
        $h | Should -Match '<li class="done"'
        $h | Should -Match '<li class="current" aria-current="step">'
        $h | Should -Match '<li class="todo">'
    }
    It 'modal is a labelled, hidden aria-modal dialog with Cancel' {
        $h = New-GIModal -Id 'rm' -Title 'Remove image' -BodyHtml '<p>Sure?</p>' -ConfirmLabel 'Remove image' -ConfirmVariant danger -FormAction '/x'
        $h | Should -Match 'id="rm" hidden'
        $h | Should -Match 'role="dialog" aria-modal="true" aria-labelledby="rm-title"'
        $h | Should -Match 'id="rm-title"'
        $h | Should -Match 'data-close>Cancel'
        $h | Should -Match '<form method="post" action="/x">'
    }
    It 'banner uses alert for errors and status for warnings; skeleton has a name' {
        New-GIBanner -Text 'Careful' | Should -Match 'role="status"'
        New-GIBanner -Text 'Broken' -Variant error -LinkText 'Fix' -LinkHref '/x' | Should -Match 'role="alert".*<a href="/x">Fix</a>'
        New-GISkeleton -Label 'Power state' | Should -Match 'aria-label="Power state"'
    }
    It 'ui script has dialog focus handling, polling and the 15 second timeout' {
        $js = Get-GIUiScript
        $js | Should -Match "Escape"
        $js | Should -Match 'visibilitychange'
        $js | Should -Match '15000'
        $js | Should -Match 'beforeunload'
    }
    It 'every page includes the ui script' {
        New-GIPage -Title 't' -BodyHtml '<p>x</p>' | Should -Match 'GI\.poll'
    }
}

Describe 'Denied POST is audited' {
    It 'writes an auth.denied entry for a role failure' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("gi-" + [guid]::NewGuid())
        New-Item -ItemType Directory $tmp | Out-Null
        try {
            $cfgPath = Join-Path $tmp 'c.psd1'
            $ctx = @{ NoAuth = $false; LocalAdmin = $false; AdminShort = 'Admins'; ApproverShort = 'Apprs'; ViewerShort = 'Views'; FormSecret = [byte[]](1..32); ConfigPath = $cfgPath }
            Mock Get-GIDashboardConfig { @{ Paths = @{ State = $tmp } } }
            $ev = [pscustomobject]@{ Path = '/run/start'; Data = @{}; Auth = [pscustomobject]@{ User = [pscustomobject]@{ Username = 'v1'; Domain = 'LAB'; Groups = @('Views') } } }
            $r = Get-GIPostRejection -Context $ctx -WebEvent $ev -Role Admin -FormId 'run' -Headers @{}
            $r.Code | Should -Be 403
            $e = @(Get-GIAudit -Config @{ Paths = @{ State = $tmp } })
            $e[0].action | Should -Be 'auth.denied'
            $e[0].user | Should -Be 'LAB\v1'
            $e[0].detail.role | Should -Be 'Viewer'
        } finally { Remove-Item $tmp -Recurse -Force }
    }
}
