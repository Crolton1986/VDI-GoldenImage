BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'VDI-GIPipeline.psd1') -Force
    . (Join-Path $PSScriptRoot '..' 'Web' 'DashboardViews.ps1')
    . (Join-Path $PSScriptRoot '..' 'Web' 'AuthSetup.ps1')
    . (Join-Path $PSScriptRoot '..' 'Web' 'Components.ps1')
    . (Join-Path $PSScriptRoot '..' 'Web' 'AdminViews.ps1')
    function script:New-AuthCfg {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("gi-auth-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $root | Out-Null
        Copy-Item (Join-Path $PSScriptRoot '..' 'pipeline.config.psd1') $root
        $script:authRoot = $root
        Get-GIConfig -Path (Join-Path $root 'pipeline.config.psd1')
    }
    function script:Basic([string]$u, [string]$p) { 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::GetEncoding('ISO-8859-1').GetBytes("${u}:${p}")) }
    function script:AuditText($cfg) { $f = Join-Path $cfg.Paths.State 'audit.jsonl'; if (Test-Path $f) { Get-Content $f -Raw } else { '' } }
}
AfterAll { if ($script:authRoot) { Remove-Item $script:authRoot -Recurse -Force -ErrorAction SilentlyContinue } }

Describe 'ConvertFrom-GIBasicAuthHeader' {
    It 'reads user and password, keeping colons and spaces in the password' {
        $r = ConvertFrom-GIBasicAuthHeader -Header (Basic 'LAB\alice' 'p:a ss:w0rd')
        $r.Ok | Should -BeTrue; $r.Username | Should -Be 'LAB\alice'; $r.Password | Should -Be 'p:a ss:w0rd'
        (ConvertFrom-GIBasicAuthHeader -Header (Basic 'alice' '')).Password | Should -Be ''
        (ConvertFrom-GIBasicAuthHeader -Header ((Basic 'alice' 'x').ToLower().Replace('basic', 'basic'))).Ok | Should -BeFalse   # lower-cased base64 no longer decodes to the same user, but must not throw
    }
    It 'asks for credentials (401) when there is no header, and refuses malformed ones (400)' {
        foreach ($h in $null, '', '   ') { $r = ConvertFrom-GIBasicAuthHeader -Header $h; $r.Ok | Should -BeFalse; $r.Code | Should -Be 401 }
        (ConvertFrom-GIBasicAuthHeader -Header 'Basic').Code | Should -Be 400
        (ConvertFrom-GIBasicAuthHeader -Header 'Bearer abc').Code | Should -Be 400
        (ConvertFrom-GIBasicAuthHeader -Header 'Basic !!!notbase64').Code | Should -Be 400
        (ConvertFrom-GIBasicAuthHeader -Header ('Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('nocolon')))).Code | Should -Be 400
        (ConvertFrom-GIBasicAuthHeader -Header ('Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':onlypassword')))).Code | Should -Be 400
        (ConvertFrom-GIBasicAuthHeader -Header (Basic 'a' 'b')).Message | Should -Not -Match 'b'   # nothing of the credentials in a message
    }
    It 'has a Pode parser that returns the pair for the validator, or a failing hashtable' {
        $parser = Get-GIBasicAuthParser
        $script:hdr = Basic 'alice' 'Secret-1'
        function global:Get-PodeHeader { param($Name) $script:hdr }
        try {
            $ok = & $parser @{}
            @($ok) | Should -Be @('alice', 'Secret-1')
            $script:hdr = $null
            $no = & $parser @{}
            $no.Code | Should -Be 401; $no.Message | Should -Be 'No Authorization header found'
            $script:hdr = 'Basic ???'
            (& $parser @{}).Code | Should -Be 400
        } finally { Remove-Item function:global:Get-PodeHeader -ErrorAction SilentlyContinue }
    }
}

Describe 'Write-GISignInFailed' {
    BeforeEach { $script:cfg = New-AuthCfg }
    It 'writes the attempted user, the reason and the source, as a failed auth.signin.failed entry' {
        (Write-GISignInFailed -Config $cfg -User 'LAB\alice' -Reason badCredentials -Source '10.1.2.3') | Should -BeTrue
        $e = @(Get-GIAudit -Config $cfg)[0]
        $e.action | Should -Be 'auth.signin.failed'; $e.user | Should -Be 'LAB\alice'; $e.result | Should -Be 'Failed'
        $e.detail.reason | Should -Be 'badCredentials'; $e.detail.source | Should -Be '10.1.2.3'
        (Get-GIAuditCategory 'auth.signin.failed') | Should -Be 'signin'
    }
    It 'cleans the typed name (control characters, length, empty) and the source' {
        $null = Write-GISignInFailed -Config $cfg -User ("evil`r`nname" + ('x' * 300)) -Reason badCredentials -Source "1.2.3.4`n<script>"
        $e = @(Get-GIAudit -Config $cfg)[0]
        $e.user.Length | Should -Be 128; $e.user | Should -Not -Match "[\r\n]"
        $e.detail.source | Should -Be '1.2.3.4script'
        (Get-GIAuditUserName -Name '') | Should -Be '(empty)'
        (Get-GIAuditUserName -Name $null) | Should -Be '(empty)'
    }
    It 'writes one entry per user and source per minute, but not for a different user or source' {
        (Write-GISignInFailed -Config $cfg -User 'a' -Reason badCredentials -Source '1.1.1.1') | Should -BeTrue
        (Write-GISignInFailed -Config $cfg -User 'a' -Reason badCredentials -Source '1.1.1.1') | Should -BeFalse
        (Write-GISignInFailed -Config $cfg -User 'a' -Reason badCredentials -Source '2.2.2.2') | Should -BeTrue
        (Write-GISignInFailed -Config $cfg -User 'b' -Reason badCredentials -Source '1.1.1.1') | Should -BeTrue
        (Write-GISignInFailed -Config $cfg -User 'a' -Reason badCredentials -Source '1.1.1.1' -ThrottleSeconds 0) | Should -BeTrue
        @(Get-GIAudit -Config $cfg).Count | Should -Be 4
    }
    It 'stops after 30 entries per source and minute even when every user name is different, but not for another source' {
        1..30 | ForEach-Object { Write-GISignInFailed -Config $cfg -User "user$_" -Reason badCredentials -Source '5.5.5.5' | Should -BeTrue }
        (Write-GISignInFailed -Config $cfg -User 'user31' -Reason badCredentials -Source '5.5.5.5') | Should -BeFalse
        (Write-GISignInFailed -Config $cfg -User 'user31' -Reason badCredentials -Source '6.6.6.6') | Should -BeTrue
        (Write-GISignInFailed -Config $cfg -User 'user31' -Reason badCredentials -Source '5.5.5.5' -MaxPerSource 100 -ThrottleSeconds 0) | Should -BeTrue
    }
    It 'has no parameter that could take a password' {
        (Get-Command Write-GISignInFailed).Parameters.Keys | Should -Not -Contain 'Password'
        (Get-Command Write-GISignInFailed).Parameters.Keys | Where-Object { $_ -match 'pass|secret|cred' } | Should -BeNullOrEmpty
    }
    It 'shows up on the audit page as a failed sign-in, in the sign-in filter and in the CSV' {
        $null = Write-GISignInFailed -Config $cfg -User 'LAB\mallory' -Reason notAuthorised -Source '10.9.9.9'
        $null = Write-GISignInFailed -Config $cfg -User '=cmd|x' -Reason badCredentials -Source '10.9.9.9'
        $s = Search-GIAudit -Config $cfg -Category signin
        $s.Total | Should -Be 2
        (ConvertTo-GIAuditCsv -Entries $s.Entries) | Should -Match '"\x27=cmd\|x"'   # formula guard
        (ConvertTo-GIAuditCsv -Entries $s.Entries) | Should -Match 'notAuthorised'
    }
}

Describe 'Failed sign-ins on the audit page' {
    It 'escapes a hostile user name and keeps the password out of the page' {
        $cfg = New-AuthCfg
        $null = Write-GISignInFailed -Config $cfg -User '<img src=x onerror=alert(1)>' -Reason badCredentials -Source '10.0.0.9'
        $s = Search-GIAudit -Config $cfg -Category signin
        $h = New-GIAuditLogPage -Entries @($s.Entries) -Total $s.Total
        $h | Should -Not -Match '<img src=x'
        $h | Should -Match '&lt;img src=x onerror=alert\(1\)&gt;'
        $h | Should -Match 'badCredentials'
        $h | Should -Match 'chip bad">Failed'
    }
}

Describe 'Test-GIAdSignIn' {
    BeforeEach {
        Mock -ModuleName VDI-GIPipeline Invoke-GIAdBind { @{ Username = 'alice'; Name = 'Alice A'; Email = 'a@lab.example.com'; DistinguishedName = 'CN=Alice'; Groups = @('VDI-Pipeline-Admins', 'Domain Users') } }
    }
    It 'returns a Pode-shaped user for a member of a dashboard group, whatever form the name has' {
        foreach ($n in 'alice', 'LAB\alice', 'alice@lab.example.com', ' alice ') {
            InModuleScope VDI-GIPipeline -Parameters @{ n = $n } { param($n)
                $r = Test-GIAdSignIn -Username $n -Password 'x' -Domain 'lab.example.com' -Groups @('vdi-pipeline-admins', 'VDI-Pipeline-Viewers')
                $r.Ok | Should -BeTrue
                $r.User.Username | Should -Be 'alice'; $r.User.Domain | Should -Be 'lab'; $r.User.Fqdn | Should -Be 'lab.example.com'
                $r.User.Groups | Should -Contain 'VDI-Pipeline-Admins'; $r.User.UserType | Should -Be 'Domain'
            }
        }
        Should -Invoke -ModuleName VDI-GIPipeline Invoke-GIAdBind -Times 4 -ParameterFilter { $SamAccountName -eq 'alice' -and $Domain -eq 'lab.example.com' }
    }
    It 'fails with notAuthorised when the account is in none of the dashboard groups' {
        $r = InModuleScope VDI-GIPipeline { Test-GIAdSignIn -Username 'alice' -Password 'x' -Domain 'd' -Groups @('Other-Group') }
        $r.Ok | Should -BeFalse; $r.Reason | Should -Be 'notAuthorised'; $r.Message | Should -Be 'You are not authorised to access this website'
    }
    It 'fails with badCredentials when the directory says no, or user or password are empty, without asking the directory for empty ones' {
        Mock -ModuleName VDI-GIPipeline Invoke-GIAdBind { $null }
        (InModuleScope VDI-GIPipeline { Test-GIAdSignIn -Username 'alice' -Password 'wrong' -Domain 'd' -Groups @('G') }).Reason | Should -Be 'badCredentials'
        (InModuleScope VDI-GIPipeline { Test-GIAdSignIn -Username '' -Password 'x' -Domain 'd' -Groups @('G') }).Reason | Should -Be 'badCredentials'
        (InModuleScope VDI-GIPipeline { Test-GIAdSignIn -Username 'alice' -Password '' -Domain 'd' -Groups @('G') }).Reason | Should -Be 'badCredentials'
        (InModuleScope VDI-GIPipeline { Test-GIAdSignIn -Username 'LAB\' -Password 'x' -Domain 'd' -Groups @('G') }).Reason | Should -Be 'badCredentials'
        Should -Invoke -ModuleName VDI-GIPipeline Invoke-GIAdBind -Times 1
    }
    It 'fails with directoryError (503) when the directory cannot be reached, and keeps the exception text out of the result' {
        Mock -ModuleName VDI-GIPipeline Invoke-GIAdBind { throw 'LDAP server down, bind as alice with Secret-Pass' }
        $r = InModuleScope VDI-GIPipeline { Test-GIAdSignIn -Username 'alice' -Password 'Secret-Pass' -Domain 'd' -Groups @('G') }
        $r.Reason | Should -Be 'directoryError'; $r.Code | Should -Be 503
        ($r | ConvertTo-Json) | Should -Not -Match 'Secret-Pass'
    }
}

Describe 'Invoke-GIAdBind' {
    It 'refuses to touch the directory off Windows' {
        Mock -ModuleName VDI-GIPipeline Test-GIIsWindows { $false }
        { InModuleScope VDI-GIPipeline { Invoke-GIAdBind -Domain 'd' -SamAccountName 'a' -Password 'p' } } | Should -Throw '*needs a Windows host*'
    }
}

Describe 'Invoke-GIDashboardSignIn' {
    BeforeEach { $script:cfg = New-AuthCfg; $c = $script:cfg; $script:getCfg = { $c }.GetNewClosure() }
    It 'success: returns the user, writes nothing, never reads the config' {
        Mock -ModuleName VDI-GIPipeline Invoke-GIAdBind { @{ Username = 'alice'; Name = 'A'; Email = ''; DistinguishedName = 'x'; Groups = @('G') } }
        $script:called = $false
        $r = Invoke-GIDashboardSignIn -Username 'alice' -Password 'Secret-Pass-1' -Domain 'lab.example.com' -Groups @('G') -Source '1.1.1.1' -GetConfig { $script:called = $true; $null }
        $r.User.Username | Should -Be 'alice'
        (AuditText $cfg) | Should -Be ''
        $script:called | Should -BeFalse
        ($r | ConvertTo-Json -Depth 5) | Should -Not -Match 'Secret-Pass-1'
    }
    It 'failure: 401 for a wrong password, an audit entry with the attempted name, and the password nowhere' {
        Mock -ModuleName VDI-GIPipeline Invoke-GIAdBind { $null }
        $r = Invoke-GIDashboardSignIn -Username 'LAB\alice' -Password 'Hunter2-Pass-xyz' -Domain 'lab.example.com' -Groups @('G') -Source '10.0.0.5' -GetConfig $getCfg
        $r.Code | Should -Be 401; $r.Message | Should -Be 'Invalid credentials supplied'; $r.ContainsKey('User') | Should -BeFalse
        $e = @(Get-GIAudit -Config $cfg)[0]
        $e.user | Should -Be 'LAB\alice'; $e.action | Should -Be 'auth.signin.failed'; $e.detail.reason | Should -Be 'badCredentials'; $e.detail.source | Should -Be '10.0.0.5'
        (AuditText $cfg) | Should -Not -Match 'Hunter2'
        ($r | ConvertTo-Json) | Should -Not -Match 'Hunter2'
    }
    It 'failure: the other reasons keep their codes and are audited too' {
        Mock -ModuleName VDI-GIPipeline Invoke-GIAdBind { @{ Username = 'bob'; Name = 'B'; Email = ''; DistinguishedName = 'x'; Groups = @('Other') } }
        $n = Invoke-GIDashboardSignIn -Username 'bob' -Password 'P-1' -Domain 'd' -Groups @('G') -GetConfig $getCfg
        $n.Code | Should -Be 401; $n.Message | Should -Match 'not authorised'
        Mock -ModuleName VDI-GIPipeline Invoke-GIAdBind { throw 'down' }
        $d = Invoke-GIDashboardSignIn -Username 'carol' -Password 'P-2' -Domain 'd' -Groups @('G') -GetConfig $getCfg
        $d.Code | Should -Be 503
        @(Get-GIAudit -Config $cfg | ForEach-Object { $_.detail.reason }) | Should -Be @('directoryError', 'notAuthorised')
        (AuditText $cfg) | Should -Not -Match 'P-1|P-2'
    }
}

Describe 'Get-GIAdDomainName' {
    It 'prefers Dashboard.AdDomain, then USERDNSDOMAIN' {
        $cfg = New-AuthCfg
        $cfg.Dashboard.AdDomain = ' corp.example.com '
        Get-GIAdDomainName -Config $cfg | Should -Be 'corp.example.com'
        $cfg.Dashboard.Remove('AdDomain')
        $old = $env:USERDNSDOMAIN
        try { $env:USERDNSDOMAIN = 'ENV.EXAMPLE.COM'; Get-GIAdDomainName -Config $cfg | Should -Be 'ENV.EXAMPLE.COM' } finally { $env:USERDNSDOMAIN = $old }
    }
}

Describe 'Add-GIDashboardAuth (Pode wiring, Pode cmdlets replaced by recorders)' {
    BeforeAll {
        $script:rec = @{}
        function global:New-PodeAuthCustomScheme { param($Name, $Realm, $ScriptBlock) $script:rec.scheme = @{ Name = $Name; Realm = $Realm; Script = $ScriptBlock }; $script:rec.scheme }
        function global:Add-PodeAuth { param([Parameter(ValueFromPipeline)]$Scheme, $Name, $ScriptBlock, [object[]]$ArgumentList, [switch]$Sessionless) process { $script:rec.auth = @{ Name = $Name; Script = $ScriptBlock; Args = $ArgumentList; Sessionless = [bool]$Sessionless; Scheme = $Scheme } } }
        function global:New-PodeAuthScheme { param([switch]$Basic, $Realm) $script:rec.legacyScheme = @{ Basic = [bool]$Basic; Realm = $Realm }; @{ Legacy = $true } }
        function global:Add-PodeAuthWindowsAd { param([Parameter(ValueFromPipeline)]$Scheme, $Name, $Groups, [switch]$Sessionless) process { $script:rec.ad = @{ Name = $Name; Groups = $Groups; Sessionless = [bool]$Sessionless } } }
        function global:Get-PodeState { param($Name) $script:ctxForState }
    }
    AfterAll { foreach ($f in 'New-PodeAuthCustomScheme', 'Add-PodeAuth', 'New-PodeAuthScheme', 'Add-PodeAuthWindowsAd', 'Get-PodeState') { Remove-Item "function:global:$f" -ErrorAction SilentlyContinue } }
    BeforeEach { $script:rec = @{}; $script:cfg = New-AuthCfg; $script:cfg.Dashboard.AdDomain = 'lab.example.com' }

    It 'registers method AD with a custom Basic scheme, sessionless, domain and groups as options' {
        (Add-GIDashboardAuth -Context @{ Config = $cfg } -Groups @('G1', 'G2') -Realm 'Realm X') | Should -Be 'custom'
        $rec.scheme.Name | Should -Be 'Basic'; $rec.scheme.Realm | Should -Be 'Realm X'
        $rec.auth.Name | Should -Be 'AD'; $rec.auth.Sessionless | Should -BeTrue
        $rec.auth.Args[0].Domain | Should -Be 'lab.example.com'; @($rec.auth.Args[0].Groups) | Should -Be @('G1', 'G2')
        $rec.ContainsKey('ad') | Should -BeFalse
    }
    It 'switches back to Pode''s own Windows AD with Dashboard.LegacyAdAuth' {
        $cfg.Dashboard.LegacyAdAuth = $true
        (Add-GIDashboardAuth -Context @{ Config = $cfg } -Groups @('G1')) | Should -Be 'legacy'
        $rec.legacyScheme.Basic | Should -BeTrue; $rec.ad.Name | Should -Be 'AD'; $rec.ad.Sessionless | Should -BeTrue
        $rec.ContainsKey('auth') | Should -BeFalse
    }
    It 'refuses to start without a domain' {
        $cfg.Dashboard.Remove('AdDomain'); $old = $env:USERDNSDOMAIN
        try { $env:USERDNSDOMAIN = ''; { Add-GIDashboardAuth -Context @{ Config = $cfg } -Groups @('G') } | Should -Throw '*No Active Directory domain*' } finally { $env:USERDNSDOMAIN = $old }
    }
    It 'the validator hands user, password, domain, groups and the client address to the module, and only reads the config on failure' {
        $null = Add-GIDashboardAuth -Context @{ Config = $cfg } -Groups @('G1')
        $script:ctxForState = @{ ConfigPath = (Join-Path $script:authRoot 'pipeline.config.psd1') }
        # Pode loads the view script into every runspace's global scope; do the same for the one function the closure calls
        function global:Get-GIDashboardConfig { param($Context) $script:cfg }
        $global:WebEvent = [pscustomobject]@{ Request = [pscustomobject]@{ RemoteEndPoint = [pscustomobject]@{ Address = '10.20.30.40' } } }
        try {
            Mock -ModuleName VDI-GIPipeline Invoke-GIAdBind { $null }
            $r = & $rec.auth.Script 'LAB\mallory' 'Pw-Never-Logged-1' $rec.auth.Args[0]
            $r.Code | Should -Be 401
            $e = @(Get-GIAudit -Config $cfg)[0]
            $e.user | Should -Be 'LAB\mallory'; $e.detail.source | Should -Be '10.20.30.40'
            (AuditText $cfg) | Should -Not -Match 'Pw-Never-Logged'
            Mock -ModuleName VDI-GIPipeline Invoke-GIAdBind { @{ Username = 'alice'; Name = 'A'; Email = ''; DistinguishedName = 'x'; Groups = @('G1') } }
            (& $rec.auth.Script 'alice' 'ok' $rec.auth.Args[0]).User.Username | Should -Be 'alice'
        } finally { Remove-Variable WebEvent -Scope Global -ErrorAction SilentlyContinue; Remove-Item function:global:Get-GIDashboardConfig -ErrorAction SilentlyContinue }
    }
}

Describe 'Dashboard script' {
    It 'registers its authentication through Add-GIDashboardAuth' {
        $t = Get-Content (Join-Path $PSScriptRoot '..' 'Web' 'Start-GIDashboard.ps1') -Raw
        $t | Should -Match 'Add-GIDashboardAuth -Context \$ctx -Groups \$groups'
        $t | Should -Not -Match 'New-PodeAuthScheme -Basic'
    }
}
