BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'VDI-GIPipeline.psd1') -Force

    # Mock bodies run bound to the module, so test data is shared through one global hashtable
    $global:GIRunCtl = @{}

    function New-TestConfig {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $c = @{
            Root        = $root
            Paths       = @{ State = (Join-Path $root 'state'); Reports = (Join-Path $root 'reports'); Logs = (Join-Path $root 'logs') }
            vCenter     = @{ Server = 'vc'; CredentialSecret = 'GI-vCenter' }
            Horizon     = @{ Server = 'hz' }
            GoldenImage = @{ VmName = 'GI-VM' }
            Pools       = @{ Test = @{ Name = 'TST-W11' }; Production = @(@{ Name = 'PRD-A' }, @{ Name = 'PRD-B' }) }
        }
        New-Item -ItemType Directory -Path $c.Paths.State -Force | Out-Null
        $c
    }
    function Write-TestLock {
        param($Config, [int] $ProcId = 999999, [string] $HostName = [Environment]::MachineName, [string] $Stage = 'Snapshot')
        $body = @{ pid = $ProcId; host = $HostName; runId = $null; stage = $Stage; startedAt = (Get-Date).ToString('o'); requestedBy = 'someone' } | ConvertTo-Json -Compress
        Set-Content -LiteralPath (Join-Path $Config.Paths.State 'pipeline.lock') -Value $body
    }
    function New-TestRun {
        param($Config, $RunId = '20261124-020202')
        $r = New-GIRun -Config $Config -RunId $RunId
        Save-GIRun -Config $Config -Run $r
        $RunId
    }
}

AfterAll {
    Remove-Variable -Name GIRunCtl -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Pipeline lock' {
    BeforeEach {
        $cfg = New-TestConfig
        $lockPath = Join-Path $cfg.Paths.State 'pipeline.lock'
    }

    It 'Enter creates the lock with pid, host, stage and requestedBy' {
        Enter-GIPipelineLock -Config $cfg -Stage 'All' -RequestedBy 'DOM\alice'
        Test-Path $lockPath | Should -BeTrue
        $l = Get-Content $lockPath -Raw | ConvertFrom-Json
        $l.pid | Should -Be $PID
        $l.host | Should -Be ([Environment]::MachineName)
        $l.stage | Should -Be 'All'
        $l.requestedBy | Should -Be 'DOM\alice'
    }

    It 'a second Enter throws busy and names the stage' {
        Enter-GIPipelineLock -Config $cfg -Stage 'Snapshot' -RequestedBy 'a'
        { Enter-GIPipelineLock -Config $cfg -Stage 'Other' -RequestedBy 'b' } | Should -Throw 'Pipeline is busy*Snapshot*'
    }

    It 'Get returns stale = $false for our own pid' {
        Enter-GIPipelineLock -Config $cfg -Stage 'All' -RequestedBy 'a'
        (Get-GIPipelineLock -Config $cfg).stale | Should -BeFalse
    }

    It 'Get returns $null without a lock' {
        Get-GIPipelineLock -Config $cfg | Should -BeNullOrEmpty
    }

    It 'a lock of a dead pid on this host is stale, and Enter replaces it' {
        Write-TestLock -Config $cfg -ProcId 999999
        (Get-GIPipelineLock -Config $cfg).stale | Should -BeTrue
        Enter-GIPipelineLock -Config $cfg -Stage 'All' -RequestedBy 'a' -WarningAction SilentlyContinue
        (Get-Content $lockPath -Raw | ConvertFrom-Json).pid | Should -Be $PID
    }

    It 'a lock from another host is not stale and Enter throws' {
        Write-TestLock -Config $cfg -ProcId 999999 -HostName 'SOME-OTHER-HOST'
        (Get-GIPipelineLock -Config $cfg).stale | Should -BeFalse
        { Enter-GIPipelineLock -Config $cfg -Stage 'All' -RequestedBy 'a' } | Should -Throw 'Pipeline is busy*'
    }

    It 'a corrupt lock file reads as held (stale = $false)' {
        Set-Content -LiteralPath $lockPath -Value '{ not json'
        $l = Get-GIPipelineLock -Config $cfg
        $l | Should -Not -BeNullOrEmpty
        $l.stale | Should -BeFalse
    }

    It 'Set-GIPipelineLockInfo updates our own lock' {
        Enter-GIPipelineLock -Config $cfg -Stage 'Request' -RequestedBy 'a'
        Set-GIPipelineLockInfo -Config $cfg -Stage 'FromTestPush' -RunId '20261124-020202' -RequestedBy 'bob'
        $l = Get-Content $lockPath -Raw | ConvertFrom-Json
        $l.stage | Should -Be 'FromTestPush'
        $l.runId | Should -Be '20261124-020202'
        $l.requestedBy | Should -Be 'bob'
        $l.pid | Should -Be $PID
        $l.PSObject.Properties.Name | Should -Not -Contain 'stale'
    }

    It 'Set-GIPipelineLockInfo leaves a lock of another pid alone' {
        Write-TestLock -Config $cfg -ProcId 999999 -Stage 'Orig'
        Set-GIPipelineLockInfo -Config $cfg -Stage 'Changed' -RunId '20261124-020202'
        $l = Get-Content $lockPath -Raw | ConvertFrom-Json
        $l.stage | Should -Be 'Orig'
        $l.runId | Should -BeNullOrEmpty
    }

    It 'Exit removes our own lock' {
        Enter-GIPipelineLock -Config $cfg -Stage 'All' -RequestedBy 'a'
        Exit-GIPipelineLock -Config $cfg
        Test-Path $lockPath | Should -BeFalse
    }

    It 'Exit leaves a lock of another pid alone' {
        Write-TestLock -Config $cfg -ProcId 999999
        Exit-GIPipelineLock -Config $cfg
        Test-Path $lockPath | Should -BeTrue
    }
}

Describe 'New-GIRunRequest' {
    BeforeEach {
        $cfg = New-TestConfig
        $reqPath = Join-Path $cfg.Paths.State 'run-request.json'
        $runId = New-TestRun -Config $cfg
        Mock -ModuleName VDI-GIPipeline Write-GIAudit {}
    }

    It 'All writes run-request.json and audits run.request' {
        $r = New-GIRunRequest -Config $cfg -Action All -RequestedBy 'DOM\alice'
        Test-Path $reqPath | Should -BeTrue
        $j = Get-Content $reqPath -Raw | ConvertFrom-Json
        $j.action | Should -Be 'All'
        $j.id | Should -Match '^[0-9a-f-]{36}$'
        $j.requestedBy | Should -Be 'DOM\alice'
        $j.requestedAt | Should -Not -BeNullOrEmpty
        $r.id | Should -Be $j.id
        Should -Invoke -ModuleName VDI-GIPipeline Write-GIAudit -Times 1 -Exactly -ParameterFilter { $Action -eq 'run.request' -and $User -eq 'DOM\alice' }
    }

    It 'Rollback audits rollback.request with the pool as target' {
        New-GIRunRequest -Config $cfg -Action Rollback -Pool 'PRD-A' -RequestedBy 'a' | Out-Null
        Should -Invoke -ModuleName VDI-GIPipeline Write-GIAudit -Times 1 -Exactly -ParameterFilter { $Action -eq 'rollback.request' -and $Target -eq 'PRD-A' }
    }

    It 'rejects an unknown action (ValidateSet)' {
        { New-GIRunRequest -Config $cfg -Action Bogus -RequestedBy 'a' } | Should -Throw
        Test-Path $reqPath | Should -BeFalse
    }

    It 'accepts FromStage/Stage for runnable stages' {
        { New-GIRunRequest -Config $cfg -Action FromStage -Stage TestPush -RunId $runId -RequestedBy 'a' } | Should -Not -Throw
    }

    It 'rejects stage <s>' -ForEach @(@{ s = 'Approval' }, @{ s = 'Promote' }, @{ s = 'Bogus' }) {
        { New-GIRunRequest -Config $cfg -Action FromStage -Stage $s -RunId $runId -RequestedBy 'a' } | Should -Throw "*can't be started*"
        { New-GIRunRequest -Config $cfg -Action Stage -Stage $s -RunId $runId -RequestedBy 'a' } | Should -Throw "*can't be started*"
        Test-Path $reqPath | Should -BeFalse
    }

    It 'rejects a bad run id pattern' {
        { New-GIRunRequest -Config $cfg -Action Stage -Stage Validate -RunId '../x' -RequestedBy 'a' } | Should -Throw 'Invalid run id*'
    }

    It 'rejects a run that does not exist' {
        { New-GIRunRequest -Config $cfg -Action Stage -Stage Validate -RunId '20200101-000000' -RequestedBy 'a' } | Should -Throw '*not found*'
    }

    It 'Rollback rejects a pool that is not configured' {
        { New-GIRunRequest -Config $cfg -Action Rollback -Pool 'NOPE' -RequestedBy 'a' } | Should -Throw '*not configured*'
    }

    It 'Rollback accepts the test pool and production pools' -ForEach @(@{ p = 'TST-W11' }, @{ p = 'PRD-A' }, @{ p = 'PRD-B' }) {
        { New-GIRunRequest -Config $cfg -Action Rollback -Pool $p -RequestedBy 'a' } | Should -Not -Throw
    }

    It 'rejects snapshot name <n>' -ForEach @(@{ n = 'a/b' }, @{ n = 'x;y' }) {
        { New-GIRunRequest -Config $cfg -Action Rollback -Pool 'PRD-A' -SnapshotName $n -RequestedBy 'a' } | Should -Throw 'Invalid snapshot name*'
    }

    It 'refuses while a live lock exists' {
        Enter-GIPipelineLock -Config $cfg -Stage 'Snapshot' -RequestedBy 'a'
        { New-GIRunRequest -Config $cfg -Action All -RequestedBy 'a' } | Should -Throw 'Pipeline is busy*'
        Test-Path $reqPath | Should -BeFalse
    }

    It 'is allowed with a stale lock' {
        Write-TestLock -Config $cfg -ProcId 999999
        { New-GIRunRequest -Config $cfg -Action All -RequestedBy 'a' } | Should -Not -Throw
        Test-Path $reqPath | Should -BeTrue
    }

    It 'refuses when a request is already queued' {
        New-GIRunRequest -Config $cfg -Action All -RequestedBy 'a' | Out-Null
        { New-GIRunRequest -Config $cfg -Action PostCheck -RequestedBy 'b' } | Should -Throw 'A request is already queued*'
    }

    It '-WhatIf writes nothing' {
        New-GIRunRequest -Config $cfg -Action All -RequestedBy 'a' -WhatIf
        Test-Path $reqPath | Should -BeFalse
        Should -Invoke -ModuleName VDI-GIPipeline Write-GIAudit -Times 0 -Exactly
    }
}

Describe 'Read-GIRunRequest' {
    BeforeEach {
        $cfg = New-TestConfig
        $reqPath = Join-Path $cfg.Paths.State 'run-request.json'
        Mock -ModuleName VDI-GIPipeline Write-GIAudit {}
    }

    It 'returns the request and deletes the file' {
        New-GIRunRequest -Config $cfg -Action PostCheck -RequestedBy 'a' | Out-Null
        $r = Read-GIRunRequest -Config $cfg
        $r.action | Should -Be 'PostCheck'
        Test-Path $reqPath | Should -BeFalse
        Get-ChildItem $cfg.Paths.State -Filter '*.claimed*' | Should -BeNullOrEmpty
    }

    It 'returns $null when nothing is queued' {
        Read-GIRunRequest -Config $cfg | Should -BeNullOrEmpty
    }

    It 'a tampered request throws and leaves no file behind' {
        New-GIRunRequest -Config $cfg -Action Rollback -Pool 'PRD-A' -RequestedBy 'a' | Out-Null
        $j = Get-Content $reqPath -Raw | ConvertFrom-Json
        $j.pool = 'EVIL-POOL'
        $j | ConvertTo-Json | Set-Content $reqPath
        { Read-GIRunRequest -Config $cfg } | Should -Throw '*not configured*'
        Test-Path $reqPath | Should -BeFalse
        Get-ChildItem $cfg.Paths.State -Filter '*claimed*' | Should -BeNullOrEmpty
    }
}

Describe 'Remove-GIRunRequest' {
    BeforeEach {
        $cfg = New-TestConfig
        $reqPath = Join-Path $cfg.Paths.State 'run-request.json'
        Mock -ModuleName VDI-GIPipeline Write-GIAudit {}
    }

    It 'removes a queued request and audits run.request.cancel' {
        New-GIRunRequest -Config $cfg -Action All -RequestedBy 'a' | Out-Null
        Remove-GIRunRequest -Config $cfg -By 'admin' | Should -BeTrue
        Test-Path $reqPath | Should -BeFalse
        Should -Invoke -ModuleName VDI-GIPipeline Write-GIAudit -Times 1 -Exactly -ParameterFilter { $Action -eq 'run.request.cancel' -and $User -eq 'admin' }
    }

    It 'returns $false when nothing is queued' {
        Remove-GIRunRequest -Config $cfg -By 'admin' | Should -BeFalse
        Should -Invoke -ModuleName VDI-GIPipeline Write-GIAudit -Times 0 -Exactly -ParameterFilter { $Action -eq 'run.request.cancel' }
    }
}

Describe 'Secrets' {
    BeforeAll {
        # SecretManagement isn't installed in the test environment: define stubs so Mock has something to replace
        function global:Get-SecretInfo { param($Name, $ErrorAction) }
        function global:Get-Secret { param($Name, $ErrorAction, [switch] $AsPlainText) }
        $global:GIRunCtl.Pw = 'Sup3r-S3cret-Pw!'
    }
    AfterAll {
        Remove-Item Function:\global:Get-SecretInfo, Function:\global:Get-Secret -ErrorAction SilentlyContinue
    }

    Context 'Get-GISecretStatus' {
        It 'returns IsSet $false without a name' {
            $s = Get-GISecretStatus
            $s.IsSet | Should -BeFalse
        }

        It 'reports the error when SecretManagement is missing' {
            Mock -ModuleName VDI-GIPipeline Assert-GISecretModule { throw 'missing' }
            $s = Get-GISecretStatus -Name 'GI-x'
            $s.IsSet | Should -BeFalse
            $s.Error | Should -Be 'missing'
        }

        It 'returns IsSet $false when the secret does not exist' {
            Mock -ModuleName VDI-GIPipeline Assert-GISecretModule {}
            Mock -ModuleName VDI-GIPipeline Get-SecretInfo { $null }
            (Get-GISecretStatus -Name 'GI-x').IsSet | Should -BeFalse
        }

        It 'returns IsSet and UserName but never the password' {
            Mock -ModuleName VDI-GIPipeline Assert-GISecretModule {}
            Mock -ModuleName VDI-GIPipeline Get-SecretInfo { [pscustomobject]@{ Name = 'GI-x' } }
            Mock -ModuleName VDI-GIPipeline Get-Secret {
                [pscredential]::new('svc-gi', (ConvertTo-SecureString $global:GIRunCtl.Pw -AsPlainText -Force))
            }
            $s = Get-GISecretStatus -Name 'GI-x'
            $s.IsSet | Should -BeTrue
            $s.UserName | Should -Be 'svc-gi'
            $s.ContainsKey('Password') | Should -BeFalse
            ($s | ConvertTo-Json -Depth 5) | Should -Not -Match ([regex]::Escape($global:GIRunCtl.Pw))
        }
    }

    Context 'Set-GISecretFromForm' {
        BeforeEach {
            Mock -ModuleName VDI-GIPipeline Assert-GISecretModule {}
            Mock -ModuleName VDI-GIPipeline Set-GISecretCredential { $global:GIRunCtl.Cred = $Credential }
            $global:GIRunCtl.Cred = $null
        }

        It 'throws on a blank user name' {
            { Set-GISecretFromForm -Name 'GI-x' -UserName '   ' -Password 'p' } | Should -Throw 'User name is required*'
            Should -Invoke -ModuleName VDI-GIPipeline Set-GISecretCredential -Times 0 -Exactly
        }

        It 'stores a credential with a trimmed user name when a password is given' {
            Set-GISecretFromForm -Name 'GI-x' -UserName '  DOM\svc  ' -Password 'pw1'
            Should -Invoke -ModuleName VDI-GIPipeline Set-GISecretCredential -Times 1 -Exactly -ParameterFilter { $Name -eq 'GI-x' }
            $global:GIRunCtl.Cred.UserName | Should -Be 'DOM\svc'
            $global:GIRunCtl.Cred.GetNetworkCredential().Password | Should -Be 'pw1'
        }

        It 'a blank password reuses the stored password' {
            Mock -ModuleName VDI-GIPipeline Get-Secret {
                [pscredential]::new('old', (ConvertTo-SecureString 'stored-pw' -AsPlainText -Force))
            }
            Set-GISecretFromForm -Name 'GI-x' -UserName 'newuser' -Password ''
            $global:GIRunCtl.Cred.UserName | Should -Be 'newuser'
            $global:GIRunCtl.Cred.GetNetworkCredential().Password | Should -Be 'stored-pw'
        }

        It 'a blank password with nothing stored throws' {
            Mock -ModuleName VDI-GIPipeline Get-Secret { $null }
            { Set-GISecretFromForm -Name 'GI-x' -UserName 'u' -Password '' } | Should -Throw 'No stored password yet*'
            Should -Invoke -ModuleName VDI-GIPipeline Set-GISecretCredential -Times 0 -Exactly
        }
    }
}

Describe 'Test-GIConnection' {
    BeforeEach {
        $cfg = New-TestConfig
        Mock -ModuleName VDI-GIPipeline Disconnect-GIHorizon {}
    }

    It 'never throws: a failing Horizon login returns ok = $false with the message' {
        Mock -ModuleName VDI-GIPipeline Connect-GIHorizon { throw 'login refused' }
        $r = Test-GIConnection -Config $cfg -System Horizon
        $r.ok | Should -BeFalse
        $r.detail | Should -Be 'login refused'
        Should -Invoke -ModuleName VDI-GIPipeline Disconnect-GIHorizon -Times 1 -Exactly
    }

    It 'Horizon success returns ok and the pool count, and disconnects' {
        Mock -ModuleName VDI-GIPipeline Connect-GIHorizon {}
        Mock -ModuleName VDI-GIPipeline Get-GIHorizonPools { @([pscustomobject]@{ name = 'a' }, [pscustomobject]@{ name = 'b' }, [pscustomobject]@{ name = 'c' }) }
        $r = Test-GIConnection -Config $cfg -System Horizon
        $r.ok | Should -BeTrue
        $r.detail | Should -Match '3 desktop pool'
        Should -Invoke -ModuleName VDI-GIPipeline Disconnect-GIHorizon -Times 1 -Exactly
    }

    It 'Email with Email.Enabled false returns ok = $false' {
        $cfg.Email = @{ Enabled = $false }
        $r = Test-GIConnection -Config $cfg -System Email
        $r.ok | Should -BeFalse
        $r.detail | Should -Match 'disabled'
    }

    It 'vCenter without SecretManagement returns ok = $false instead of throwing' {
        Mock -ModuleName VDI-GIPipeline Get-GISecretCredential { throw 'no secret module' }
        $r = Test-GIConnection -Config $cfg -System vCenter
        $r.ok | Should -BeFalse
        $r.detail | Should -Be 'no secret module'
    }
}

Describe 'Connect-GITestVIServer' {
    BeforeAll {
        # PowerCLI isn't installed where the tests run; define stand-ins so they can be mocked
        if (-not (Get-Command Connect-VIServer -ErrorAction SilentlyContinue)) { function global:Connect-VIServer { param($Server, $Credential) } }
        if (-not (Get-Command Set-PowerCLIConfiguration -ErrorAction SilentlyContinue)) { function global:Set-PowerCLIConfiguration { param($Scope, $WebOperationTimeoutSeconds, [switch]$Confirm) } }
    }
    BeforeEach {
        $cfg = New-TestConfig
        Mock -ModuleName VDI-GIPipeline Get-GISecretCredential { [pscredential]::new('svc-vc', (ConvertTo-SecureString 'x' -AsPlainText -Force)) }
        Mock -ModuleName VDI-GIPipeline Set-PowerCLIConfiguration {}
    }

    It 'fails fast without calling Connect-VIServer when port 443 is unreachable' {
        Mock -ModuleName VDI-GIPipeline Test-GITcpPort { $false }
        Mock -ModuleName VDI-GIPipeline Connect-VIServer {}
        { Connect-GITestVIServer -Config $cfg } | Should -Throw "*Can't reach vc on port 443*"
        Should -Invoke -ModuleName VDI-GIPipeline Connect-VIServer -Times 0 -Exactly
    }

    It 'turns a denied or unanswered MFA login into a message that names MFA' {
        Mock -ModuleName VDI-GIPipeline Test-GITcpPort { $true }
        Mock -ModuleName VDI-GIPipeline Connect-VIServer { throw 'Cannot complete login due to an incorrect user name or password.' }
        { Connect-GITestVIServer -Config $cfg } | Should -Throw '*svc-vc*Duo*'
    }

    It 'Test-GIConnection returns ok = $false (not a hang or throw) when the MFA push is denied' {
        Mock -ModuleName VDI-GIPipeline Test-GITcpPort { $true }
        Mock -ModuleName VDI-GIPipeline Connect-VIServer { throw 'Cannot complete login due to an incorrect user name or password.' }
        $r = Test-GIConnection -Config $cfg -System vCenter
        $r.ok | Should -BeFalse
        $r.detail | Should -Match 'MFA'
    }
}

Describe 'Test-GITcpPort' {
    It 'returns $false for a closed port instead of throwing' {
        Test-GITcpPort -Server '127.0.0.1' -Port 1 -TimeoutMs 1000 | Should -BeFalse
    }
}

Describe 'Test-GIConnection AppVolumes' {
    BeforeAll {
        # A web exception with a status code, shaped like what Invoke-RestMethod throws
        function global:New-GIHttpError([int]$Code, [string]$Reason) {
            $resp = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]$Code)
            $resp.ReasonPhrase = $Reason
            $ex = [Microsoft.PowerShell.Commands.HttpResponseException]::new("Response status code does not indicate success: $Code ($Reason).", $resp)
            return $ex
        }
    }
    BeforeEach {
        $cfg = New-TestConfig
        $cfg.AppVolumes = @{ Server = 'avm.test'; CredentialSecret = 'GI-av'; Endpoints = @{ Session = '/app_volumes/sessions'; OnlineEntities = '/app_volumes/online_entities' } }
        Mock -ModuleName VDI-GIPipeline Get-GISecretCredential { [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force)) }
        $global:GIAvCalls = [System.Collections.Generic.List[string]]::new()
    }
    AfterAll { Remove-Item function:global:New-GIHttpError -ErrorAction SilentlyContinue; Remove-Variable GIAvCalls -Scope Global -ErrorAction SilentlyContinue }

    It 'falls back to /cv_api paths on 404 and says which paths worked' {
        Mock -ModuleName VDI-GIPipeline Invoke-RestMethod {
            $global:GIAvCalls.Add("$Method $Uri")
            if ($Uri -like '*/app_volumes/*') { throw (New-GIHttpError 404 'Not Found') }
            if ($Uri -like '*online_entities') { return ('{"online":{"records":[{"name":"a"},{"name":"b"}]}}' | ConvertFrom-Json) }
            return @{}
        }
        $r = Test-GIConnection -Config $cfg -System AppVolumes
        $r.ok | Should -BeTrue
        $r.detail | Should -Match '2 online entities'
        $r.detail | Should -Match 'Login worked at /cv_api/sessions'
        $r.detail | Should -Match 'POST https://avm.test/app_volumes/sessions -> 404 Not Found'
        $r.detail | Should -Match 'Online entities worked at /cv_api/online_entities'
    }

    It 'stops on a non-404 and reports the URL and status' {
        Mock -ModuleName VDI-GIPipeline Invoke-RestMethod { $global:GIAvCalls.Add("$Uri"); throw (New-GIHttpError 401 'Unauthorized') }
        $r = Test-GIConnection -Config $cfg -System AppVolumes
        $r.ok | Should -BeFalse
        $r.detail | Should -Match 'POST https://avm.test/app_volumes/sessions -> 401 Unauthorized'
        $global:GIAvCalls.Count | Should -Be 1
    }

    It 'lists every path tried when all of them 404' {
        Mock -ModuleName VDI-GIPipeline Invoke-RestMethod { throw (New-GIHttpError 404 'Not Found') }
        $r = Test-GIConnection -Config $cfg -System AppVolumes
        $r.ok | Should -BeFalse
        $r.detail | Should -Match '/app_volumes/sessions -> 404'
        $r.detail | Should -Match '/cv_api/sessions -> 404'
    }
}

Describe 'Set-GIPipelineScheduleTask' {
    It 'reports ok = $false off Windows' -Skip:$IsWindows {
        $cfg = New-TestConfig
        $r = Set-GIPipelineScheduleTask -Config $cfg
        $r.ok | Should -BeFalse
        $r.detail | Should -Match 'only available on Windows'
    }
}

Describe 'Start-GIQueuedRun' {
    BeforeEach { $cfg = New-TestConfig }

    It 'starts a local process and never touches the scheduled task with -Local' {
        Mock -ModuleName VDI-GIPipeline Start-GIRunnerProcess { @{ Pid = 1234; Log = 'x.log'; Error = $null } }
        Mock -ModuleName VDI-GIPipeline Start-GIRunnerTask {}
        Start-GIQueuedRun -Config $cfg -Local | Should -Be 'started'
        Should -Invoke -ModuleName VDI-GIPipeline Start-GIRunnerTask -Times 0 -Exactly
    }

    It 'reports runfailed when the local process dies right away' {
        Mock -ModuleName VDI-GIPipeline Start-GIRunnerProcess { @{ Pid = 1234; Log = 'x.log'; Error = 'module not found' } }
        Start-GIQueuedRun -Config $cfg -Local -WarningAction SilentlyContinue | Should -Be 'runfailed'
    }

    It 'uses the scheduled task without -Local and reports norunner when it is missing' {
        Mock -ModuleName VDI-GIPipeline Start-GIRunnerTask { throw 'task not found' }
        Mock -ModuleName VDI-GIPipeline Start-GIRunnerProcess {}
        Start-GIQueuedRun -Config $cfg | Should -Be 'norunner'
        Should -Invoke -ModuleName VDI-GIPipeline Start-GIRunnerProcess -Times 0 -Exactly
    }
}
