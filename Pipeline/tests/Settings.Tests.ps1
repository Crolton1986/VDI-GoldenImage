BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'VDI-GIPipeline.psd1') -Force
    $script:shipped = (Resolve-Path (Join-Path $PSScriptRoot '..' 'pipeline.config.psd1')).ProviderPath
    InModuleScope VDI-GIPipeline {
        # Get-GISecretStatus lives in Config.ps1 once the secret work lands; stub if absent so Mock works
        if (-not (Get-Command Get-GISecretStatus -ErrorAction SilentlyContinue)) {
            function script:Get-GISecretStatus { param($Name) }
        }
    }
    function script:New-SettingsConfig {
        # Fresh Root inside TestDrive so Root/config/settings.json is isolated per test
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir
        Copy-Item -LiteralPath $script:shipped -Destination (Join-Path $dir 'pipeline.config.psd1')
        Join-Path $dir 'pipeline.config.psd1'
    }
    function script:Write-Overlay($ConfigPath, $Json) {
        $d = Join-Path (Split-Path $ConfigPath) 'config'
        $null = New-Item -ItemType Directory -Path $d -Force
        Set-Content -LiteralPath (Join-Path $d 'settings.json') -Value $Json
    }
}

Describe 'Merge-GIHashtable / Get-GIConfig overlay' {
    It 'merges nested dictionaries and replaces arrays' {
        $r = InModuleScope VDI-GIPipeline {
            $base = @{ A = @{ B = 1; C = @{ D = 'x'; E = 'y' } }; L = @(1, 2, 3); S = 's' }
            $over = @{ A = @{ C = @{ D = 'z' } }; L = @(9) }
            $m = Merge-GIHashtable -Base $base -Overlay $over
            @{ merged = $m; base = $base }
        }
        $r.merged.A.B | Should -Be 1
        $r.merged.A.C.D | Should -Be 'z'
        $r.merged.A.C.E | Should -Be 'y'
        $r.merged.L | Should -Be @(9)
        $r.merged.S | Should -Be 's'
        $r.base.A.C.D | Should -Be 'x'
        $r.base.L.Count | Should -Be 3
    }

    It 'overrides nested values from settings.json' {
        $p = New-SettingsConfig
        Write-Overlay $p '{ "vCenter": { "Server": "vcsa02" }, "Pools": { "Production": [ { "Name": "P1", "LogoffPolicy": "FORCE_LOGOFF" }, { "Name": "P2", "LogoffPolicy": "FORCE_LOGOFF" } ] } }'
        $c = Get-GIConfig -Path $p
        $c.vCenter.Server | Should -Be 'vcsa02'
        $c.vCenter.CredentialSecret | Should -Be 'GI-vCenter'
        @($c.Pools.Production).Count | Should -Be 2
        $c.Pools.Test.Name | Should -Be 'TST-W11'
        $c.SettingsPath | Should -Be (Join-Path (Split-Path $p) 'config' 'settings.json')
    }

    It 'uses the psd1 only when settings.json is absent' {
        $c = Get-GIConfig -Path (New-SettingsConfig)
        $c.vCenter.Server | Should -Be 'vcsa01.domain.local'
        $c.SettingsPath | Should -Not -BeNullOrEmpty
    }

    It 'throws a clear error naming the file for invalid JSON' {
        $p = New-SettingsConfig
        Write-Overlay $p '{ "vCenter": '
        { Get-GIConfig -Path $p } | Should -Throw '*settings.json*not valid JSON*'
    }
}

Describe 'ConvertFrom-GISettingsForm' {
    It 'reports an int parse error' {
        $r = ConvertFrom-GISettingsForm -Section Snapshots -Form @{ Keep = 'abc'; MaxChainDepth = '10' }
        $r.Errors.Keep | Should -BeLike '*whole number*'
        $r.Values.MaxChainDepth | Should -Be 10
        $r.Values.Keep | Should -BeNullOrEmpty
    }

    It 'treats an absent checkbox as false and a present one as true' {
        $r = ConvertFrom-GISettingsForm -Section Snapshots -Form @{ Keep = '3'; MaxChainDepth = '10'; Prune = 'on' }
        $r.Values.Prune | Should -BeTrue
        $r.Values.ProtectAncestors | Should -BeFalse
    }

    It 'splits lists on newlines, trims and drops empty lines' {
        $r = ConvertFrom-GISettingsForm -Section Validation -Form @{ RequiredServices = "wsnm`r`n  svservice  `n`n frxsvc`n" }
        $r.Values.RequiredServices | Should -Be @('wsnm', 'svservice', 'frxsvc')
    }

    It 'accepts days as a string or a string array' {
        (ConvertFrom-GISettingsForm -Section Promotion -Form @{ 'MaintenanceWindow.Days' = 'Saturday' }).Values['MaintenanceWindow.Days'] | Should -Be @('Saturday')
        (ConvertFrom-GISettingsForm -Section Promotion -Form @{ 'MaintenanceWindow.Days' = @('Friday', 'Saturday') }).Values['MaintenanceWindow.Days'] | Should -Be @('Friday', 'Saturday')
        @((ConvertFrom-GISettingsForm -Section Promotion -Form @{}).Values['MaintenanceWindow.Days']).Count | Should -Be 0
    }

    It 'builds table rows from indexed keys with gaps and skips blank rows' {
        $form = @{
            'Production[0].Name' = 'PRD-A'; 'Production[0].LogoffPolicy' = 'FORCE_LOGOFF'
            'Production[2].Name' = 'PRD-C'; 'Production[2].LogoffPolicy' = 'WAIT_FOR_LOGOFF'
            'Production[5].Name' = '';      'Production[5].LogoffPolicy' = ''
        }
        $r = ConvertFrom-GISettingsForm -Section Pools -Form $form
        $rows = @($r.Values.Production)
        $rows.Count | Should -Be 2
        $rows[0].Name | Should -Be 'PRD-A'
        $rows[1].Name | Should -Be 'PRD-C'
        $rows[1].LogoffPolicy | Should -Be 'WAIT_FOR_LOGOFF'
    }

    It 'drops spare rows whose only value is the dropdown default (what a browser actually posts)' {
        $form = @{
            'Production[0].Name' = 'JWPRDTest'; 'Production[0].LogoffPolicy' = 'WAIT_FOR_LOGOFF'
            'Production[1].Name' = '';          'Production[1].LogoffPolicy' = 'WAIT_FOR_LOGOFF'
            'Production[2].Name' = ' ';         'Production[2].LogoffPolicy' = 'FORCE_LOGOFF'
        }
        $r = ConvertFrom-GISettingsForm -Section Pools -Form $form
        @($r.Values.Production).Count | Should -Be 1
        $r.Values.Production[0].Name | Should -Be 'JWPRDTest'
        $r.Errors.Count | Should -Be 0
    }

    It 'drops rows with remove checked' {
        $form = @{
            'Production[0].Name' = 'PRD-A'; 'Production[0].LogoffPolicy' = 'WAIT_FOR_LOGOFF'
            'Production[1].Name' = 'PRD-B'; 'Production[1].LogoffPolicy' = 'WAIT_FOR_LOGOFF'; 'Production[1]._remove' = 'on'
        }
        $r = ConvertFrom-GISettingsForm -Section Pools -Form $form
        @($r.Values.Production).Name | Should -Be @('PRD-A')
    }

    It 'excludes secret fields' {
        $r = ConvertFrom-GISettingsForm -Section vCenter -Form @{ Server = 'vc'; CredentialSecret = 'x'; Password = 'secret' }
        $r.Values.Keys | Should -Not -Contain 'CredentialSecret'
        $r.Values.Server | Should -Be 'vc'
    }
}

Describe 'Test-GISettingsSection' {
    BeforeAll {
        function script:Valid-Pools { @{ 'Test.Name' = 'T'; 'Test.LogoffPolicy' = 'FORCE_LOGOFF'; Production = @(@{ Name = 'P'; LogoffPolicy = 'WAIT_FOR_LOGOFF' }); PushTimeoutMin = 120 } }
    }
    It 'accepts the shipped values for every editable section' {
        $c = Get-GIConfig -Path (New-SettingsConfig)
        foreach ($s in (Get-GISettingsSchema).Keys) {
            Mock -ModuleName VDI-GIPipeline Get-GISecretStatus { @{ Name = $Name; IsSet = $true; UserName = 'svc' } }
            $v = (Get-GISettingsSection -Config $c -Section $s).Values
            (Test-GISettingsSection -Section $s -Values $v).Count | Should -Be 0 -Because "section $s"
        }
    }
    It 'flags required strings' {
        (Test-GISettingsSection -Section vCenter -Values @{ Server = ' ' }).Server | Should -Be 'Required.'
    }
    It 'flags int range' {
        $e = Test-GISettingsSection -Section Snapshots -Values @{ Keep = 0; MaxChainDepth = 40; Prune = $false; ProtectAncestors = $true }
        $e.Keep | Should -BeLike 'Must be between 1 and 50*'
        $e.MaxChainDepth | Should -BeLike 'Must be between 2 and 31*'
    }
    It 'flags enum values' {
        $v = Valid-Pools; $v['Test.LogoffPolicy'] = 'NOPE'
        (Test-GISettingsSection -Section Pools -Values $v)['Test.LogoffPolicy'] | Should -BeLike 'Must be one of*'
    }
    It 'flags time format' {
        $e = Test-GISettingsSection -Section Promotion -Values @{ 'MaintenanceWindow.Days' = @('Saturday'); 'MaintenanceWindow.StartTime' = '25:00'; 'PipelineSchedule.Day' = 'Tuesday'; 'PipelineSchedule.Time' = '8pm' }
        $e['MaintenanceWindow.StartTime'] | Should -BeLike 'Use 24-hour*'
        $e['PipelineSchedule.Time'] | Should -BeLike 'Use 24-hour*'
    }
    It 'requires at least one maintenance day and rejects bad day names' {
        $v = @{ 'MaintenanceWindow.Days' = @(); 'MaintenanceWindow.StartTime' = '22:00'; 'PipelineSchedule.Day' = 'Tuesday'; 'PipelineSchedule.Time' = '20:00' }
        (Test-GISettingsSection -Section Promotion -Values $v)['MaintenanceWindow.Days'] | Should -BeLike 'Select at least one*'
        $v['MaintenanceWindow.Days'] = @('Funday')
        (Test-GISettingsSection -Section Promotion -Values $v)['MaintenanceWindow.Days'] | Should -BeLike 'Invalid day*'
    }
    It 'applies the endpoint Pattern' {
        $e = Test-GISettingsSection -Section AppVolumes -Values @{ Server = 'a'; TestPackages = @(); 'Endpoints.Session' = 'sessions'; 'Endpoints.OnlineEntities' = '/ok'; 'Endpoints.Attachments' = '/ok' }
        $e.ContainsKey('Endpoints.Session') | Should -BeTrue
        $e.ContainsKey('Endpoints.OnlineEntities') | Should -BeFalse
    }
    It 'whitelists guest actions' {
        $v = @{ InstallerSourceDir = ''; Actions = @('VmTools', 'Bogus'); ActionTimeoutMin = 60 }
        (Test-GISettingsSection -Section Packages -Values $v).Actions | Should -BeLike '*Bogus*'
        $v.Actions = @('VmTools', 'OneDrive', 'GoogleDrive', 'HorizonRec')
        (Test-GISettingsSection -Section Packages -Values $v).Count | Should -Be 0
    }
    It 'rejects duplicate production pools' {
        $v = Valid-Pools
        $v.Production = @(@{ Name = 'P'; LogoffPolicy = 'FORCE_LOGOFF' }, @{ Name = 'p'; LogoffPolicy = 'FORCE_LOGOFF' })
        (Test-GISettingsSection -Section Pools -Values $v)['Production[1].Name'] | Should -BeLike 'Duplicate*'
    }
    It 'rejects a production pool equal to the test pool' {
        $v = Valid-Pools
        $v.Production = @(@{ Name = 'T'; LogoffPolicy = 'FORCE_LOGOFF' })
        (Test-GISettingsSection -Section Pools -Values $v)['Production[0].Name'] | Should -BeLike '*test pool*'
    }
    It 'requires a production row and validates cells' {
        $v = Valid-Pools; $v.Production = @()
        (Test-GISettingsSection -Section Pools -Values $v).Production | Should -BeLike 'Add at least*'
        $v.Production = @(@{ Name = ''; LogoffPolicy = 'X' })
        $e = Test-GISettingsSection -Section Pools -Values $v
        $e['Production[0].Name'] | Should -Be 'Required.'
        $e['Production[0].LogoffPolicy'] | Should -BeLike 'Must be one of*'
    }
    It 'validates email addresses and requires settings when enabled' {
        $v = @{ Enabled = $true; SmtpServer = 'smtp'; Port = 25; UseSsl = $false; From = 'a@b.c'; To = @('ok@x.y', 'not-an-email') }
        (Test-GISettingsSection -Section Email -Values $v).To | Should -BeLike '*not-an-email*'
        $v = @{ Enabled = $true; SmtpServer = ''; Port = 25; UseSsl = $false; From = ''; To = @() }
        $e = Test-GISettingsSection -Section Email -Values $v
        $e.SmtpServer | Should -Not -BeNullOrEmpty
        $e.From | Should -Not -BeNullOrEmpty
        $e.To | Should -Not -BeNullOrEmpty
        $v.Enabled = $false
        (Test-GISettingsSection -Section Email -Values $v).Count | Should -Be 0
    }
}

Describe 'Get-GISettingsSection' {
    It 'returns effective values, defaults for absent keys, and secret status' {
        Mock -ModuleName VDI-GIPipeline Get-GISecretStatus { @{ Name = $Name; IsSet = $true; UserName = 'svc' } }
        $c = Get-GIConfig -Path (New-SettingsConfig)
        $g = (Get-GISettingsSection -Config $c -Section GoldenImage).Values
        $g.GuestWorkDir | Should -Be 'C:\ProgramData\VDI\Pipeline'
        $g.CopyScript | Should -BeTrue
        $g.GuestCredentialSecret.Name | Should -Be 'GI-GuestAdmin'
        $g.GuestCredentialSecret.IsSet | Should -BeTrue
        $g.GuestCredentialSecret.UserName | Should -Be 'svc'
        $e = (Get-GISettingsSection -Config $c -Section Email).Values
        $e.CredentialSecret.Configured | Should -BeFalse
        $e.CredentialSecret.Name | Should -Be 'GI-Smtp'
        $e.CredentialSecret.IsSet | Should -BeFalse
        (Get-GISettingsSection -Config $c -Section Promotion).Values['PipelineSchedule.Day'] | Should -Be 'Tuesday'
    }
}

Describe 'Save-GISettingsSection' {
    BeforeEach {
        $script:p = New-SettingsConfig
        $script:cfg = Get-GIConfig -Path $p
        $script:settingsFile = Join-Path (Split-Path $p) 'config' 'settings.json'
        function script:Pools-Values($name = 'TST-W11') {
            @{ 'Test.Name' = $name; 'Test.LogoffPolicy' = 'FORCE_LOGOFF'; Production = @(@{ Name = 'PRD-W11'; LogoffPolicy = 'WAIT_FOR_LOGOFF' }); PushTimeoutMin = 120 }
        }
    }

    It 'writes only changed keys to settings.json and Get-GIConfig reflects them' {
        $null = Save-GISettingsSection -Config $cfg -Section vCenter -Values @{ Server = 'vcsa02.domain.local' } -By 'DOMAIN\admin'
        $json = Get-Content $settingsFile -Raw | ConvertFrom-Json -AsHashtable
        $json.vCenter.Server | Should -Be 'vcsa02.domain.local'
        $json.Keys | Should -Be @('vCenter')
        (Get-GIConfig -Path $p).vCenter.Server | Should -Be 'vcsa02.domain.local'
    }

    It 'creates settings.json.bak on the second save and preserves other sections' {
        $null = Save-GISettingsSection -Config $cfg -Section vCenter -Values @{ Server = 'vc2' }
        Test-Path "$settingsFile.bak" | Should -BeFalse
        $null = Save-GISettingsSection -Config (Get-GIConfig -Path $p) -Section Snapshots -Values @{ Keep = 5; MaxChainDepth = 10; Prune = $false; ProtectAncestors = $true }
        Test-Path "$settingsFile.bak" | Should -BeTrue
        (Get-Content "$settingsFile.bak" -Raw | ConvertFrom-Json -AsHashtable).Keys | Should -Not -Contain 'Snapshots'
        $json = Get-Content $settingsFile -Raw | ConvertFrom-Json -AsHashtable
        $json.vCenter.Server | Should -Be 'vc2'
        $json.Snapshots.Keep | Should -Be 5
        $json.Snapshots.ContainsKey('Prune') | Should -BeFalse
    }

    It 'writes dotted keys, tables and lists at their config path' {
        $null = Save-GISettingsSection -Config $cfg -Section WindowsUpdate -Values @{ Enabled = $true; MaxPasses = 7; PassTimeoutMin = 90 }
        $v = Pools-Values; $v.Production = @(@{ Name = 'A'; LogoffPolicy = 'FORCE_LOGOFF' }, @{ Name = 'B'; LogoffPolicy = 'WAIT_FOR_LOGOFF' })
        $null = Save-GISettingsSection -Config $cfg -Section Pools -Values $v
        $c = Get-GIConfig -Path $p
        $c.GoldenImage.WindowsUpdate.MaxPasses | Should -Be 7
        $c.GoldenImage.WindowsUpdate.PassTimeoutMin | Should -Be 90
        $c.GoldenImage.WindowsUpdate.Enabled | Should -BeTrue
        @($c.Pools.Production).Count | Should -Be 2
        $c.Pools.Production[1].Name | Should -Be 'B'
        $c.GoldenImage.VmName | Should -Be 'W11-GI-01'
    }

    It 'audits a field-level diff for changed keys only' {
        $null = Save-GISettingsSection -Config $cfg -Section Snapshots -Values @{ Keep = 4; MaxChainDepth = 10; Prune = $false; ProtectAncestors = $true } -By 'DOMAIN\bob'
        $a = @(Get-GIAudit -Config $cfg)
        $a.Count | Should -Be 1
        $a[0].action | Should -Be 'settings.save'
        $a[0].target | Should -Be 'Snapshots'
        $a[0].user | Should -Be 'DOMAIN\bob'
        @($a[0].detail.changes).Count | Should -Be 1
        $a[0].detail.changes[0].key | Should -Be 'Keep'
        $a[0].detail.changes[0].old | Should -Be 2
        $a[0].detail.changes[0].new | Should -Be 4
    }

    It 'never writes secret material and ignores secret keys in Values' {
        $null = Save-GISettingsSection -Config $cfg -Section vCenter -Values @{ Server = 'vc3'; CredentialSecret = 'Hunter2-Password'; Password = 'Hunter2-Password' }
        (Get-Content $settingsFile -Raw) | Should -Not -BeLike '*Hunter2*'
        (Get-Content (Join-Path $cfg.Paths.State 'audit.jsonl') -Raw) | Should -Not -BeLike '*Hunter2*'
        (Get-Content $settingsFile -Raw | ConvertFrom-Json -AsHashtable).vCenter.Keys | Should -Not -Contain 'CredentialSecret'
    }

    It 'refuses the read-only Dashboard section' {
        { Save-GISettingsSection -Config $cfg -Section Dashboard -Values @{ Port = 9999 } } | Should -Throw '*read only*'
        Test-Path $settingsFile | Should -BeFalse
    }

    It 'throws listing all errors and writes nothing when invalid' {
        $bad = @{ Keep = 0; MaxChainDepth = 99; Prune = $false; ProtectAncestors = $true }
        { Save-GISettingsSection -Config $cfg -Section Snapshots -Values $bad } | Should -Throw '*2 error(s)*Keep*MaxChainDepth*'
        Test-Path $settingsFile | Should -BeFalse
        @(Get-GIAudit -Config $cfg).Count | Should -Be 0
    }

    It 'does nothing (no write, no audit) when nothing changed' {
        $v = (ConvertFrom-GISettingsForm -Section Snapshots -Form @{ NamePrefix = 'Baseline'; Mode = 'Chain'; Keep = '2'; MaxChainDepth = '10'; ProtectAncestors = 'on'; ConsolidateTimeoutMin = '60'; MinFreeSpacePercent = '15'; CleanupFailedRuns = 'on' }).Values
        (Save-GISettingsSection -Config $cfg -Section Snapshots -Values $v).Changed.Count | Should -Be 0
        Test-Path $settingsFile | Should -BeFalse
    }

    It 'throws a clear error when the existing settings.json is invalid' {
        Write-Overlay $p '{ nope'
        { Save-GISettingsSection -Config $cfg -Section vCenter -Values @{ Server = 'x' } } | Should -Throw '*not valid JSON*'
    }
}

Describe 'Connection test results' {
    BeforeEach { $script:cp = New-SettingsConfig; $script:cc = Get-GIConfig -Path $script:cp }
    It 'reads Not tested before anything was recorded' {
        (Get-GIConnectionStatus -Config $cc -Section vCenter).State | Should -Be 'NotTested'
    }
    It 'records ok and failed per section with a time, and forgets one section' {
        Set-GIConnectionStatus -Config $cc -Section vCenter -Ok $true
        Set-GIConnectionStatus -Config $cc -Section Horizon -Ok $false
        $v = Get-GIConnectionStatus -Config $cc -Section vCenter
        $v.State | Should -Be 'Connected'; ([datetimeoffset]::Parse($v.At)) | Should -BeOfType [datetimeoffset]
        (Get-GIConnectionStatus -Config $cc -Section Horizon).State | Should -Be 'Failed'
        Set-GIConnectionStatus -Config $cc -Section vCenter -Clear
        (Get-GIConnectionStatus -Config $cc -Section vCenter).State | Should -Be 'NotTested'
        (Get-GIConnectionStatus -Config $cc -Section Horizon).State | Should -Be 'Failed'
    }
    It 'treats a damaged file as Not tested and recovers on the next write' {
        Set-Content -LiteralPath (Get-GIConnectionStatePath -Config $cc) -Value '{ nope'
        (Get-GIConnectionStatus -Config $cc -Section vCenter).State | Should -Be 'NotTested'
        Set-GIConnectionStatus -Config $cc -Section vCenter -Ok $true
        (Get-GIConnectionStatus -Config $cc -Section vCenter).State | Should -Be 'Connected'
    }
    It 'is cleared when a section changes, and kept when nothing changed' {
        Set-GIConnectionStatus -Config $cc -Section vCenter -Ok $true
        $null = Save-GISettingsSection -Config $cc -Section vCenter -Values @{ Server = (Get-GIConfig -Path $cp).vCenter.Server }
        (Get-GIConnectionStatus -Config (Get-GIConfig -Path $cp) -Section vCenter).State | Should -Be 'Connected'
        $null = Save-GISettingsSection -Config $cc -Section vCenter -Values @{ Server = 'changed.example.com' }
        (Get-GIConnectionStatus -Config (Get-GIConfig -Path $cp) -Section vCenter).State | Should -Be 'NotTested'
    }
}

Describe 'Set-GISettingsSecretName' {
    It 'writes the DefaultName once when the key is absent, and keeps an existing name' {
        $p = New-SettingsConfig
        $cfg = Get-GIConfig -Path $p
        Set-GISettingsSecretName -Config $cfg -Section Email -Key CredentialSecret -By 'DOMAIN\a' | Should -Be 'GI-Smtp'
        (Get-GIConfig -Path $p).Email.CredentialSecret | Should -Be 'GI-Smtp'
        Set-GISettingsSecretName -Config (Get-GIConfig -Path $p) -Section Validation -Key GuestCredentialSecret | Should -Be 'GI-CloneGuestAdmin'
        # configured in psd1: untouched, no file change
        Set-GISettingsSecretName -Config (Get-GIConfig -Path $p) -Section vCenter -Key CredentialSecret | Should -Be 'GI-vCenter'
        (Get-Content (Join-Path (Split-Path $p) 'config' 'settings.json') -Raw | ConvertFrom-Json -AsHashtable).Keys | Should -Not -Contain 'vCenter'
    }
    It 'rejects non-secret fields' {
        $cfg = Get-GIConfig -Path (New-SettingsConfig)
        { Set-GISettingsSecretName -Config $cfg -Section vCenter -Key Server } | Should -Throw '*no secret field*'
    }
}

Describe 'Schema vs pipeline.config.psd1' {
    It 'every field key resolves in the psd1 or has a default' {
        $raw = Import-PowerShellDataFile -LiteralPath $script:shipped
        $problems = foreach ($sec in (Get-GISettingsSchema).GetEnumerator()) {
            $def = $sec.Value
            foreach ($f in $def.Fields) {
                $node = $raw
                $found = $true
                foreach ($part in (@($def.ConfigPath.Split('.')) + @($f.Key.Split('.')))) {
                    if ($node -is [System.Collections.IDictionary] -and $node.Contains($part)) { $node = $node[$part] } else { $found = $false; break }
                }
                $hasDefault = $f.Contains('Default') -or $f.Contains('DefaultName') -or $f.Type -in 'bool', 'list', 'days', 'table', 'packages'
                if (-not $found -and -not $hasDefault) { "$($sec.Key).$($f.Key)" }
            }
        }
        @($problems) | Should -BeNullOrEmpty
    }
    It 'defines the documented sections and read-only Dashboard' {
        (Get-GISettingsSchema).Keys | Should -Be @('vCenter', 'Horizon', 'AppVolumes', 'GoldenImage', 'Packages', 'GuestScript', 'WindowsUpdate', 'Pools', 'Validation', 'Snapshots', 'Promotion', 'Email', 'Dashboard')
        (Get-GISettingsSchema).Dashboard.ReadOnly | Should -BeTrue
        (Get-GISettingsSchema).Promotion.Title | Should -Be 'Schedule & promotion'
    }
}

Describe 'Production pool safety default' {
    It 'lists WAIT_FOR_LOGOFF first so new blank rows never default to forcing logoff' {
        Import-Module (Join-Path $PSScriptRoot '..' 'VDI-GIPipeline.psd1') -Force
        $prod = (Get-GISettingsSchema)['Pools'].Fields | Where-Object Key -eq 'Production'
        ($prod.Columns | Where-Object Key -eq 'LogoffPolicy').Values[0] | Should -Be 'WAIT_FOR_LOGOFF'
    }
}

Describe 'Packages section' {
    It 'owns Actions and InstallerSourceDir; Golden image no longer lists them' {
        $s = Get-GISettingsSchema
        $s.Packages.ConfigPath | Should -Be 'GoldenImage'
        @($s.Packages.Fields.Key) | Should -Be @('InstallerSourceDir', 'Actions', 'ActionTimeoutMin')
        @($s.GoldenImage.Fields.Key) | Should -Not -Contain 'Actions'
        @($s.GoldenImage.Fields.Key) | Should -Not -Contain 'InstallerSourceDir'
    }
    It 'parses ticked boxes into catalog order and keeps unknown names for validation' {
        $r = ConvertFrom-GISettingsForm -Section Packages -Form @{ Actions = @('MsTeams', 'VmTools', 'Bogus'); InstallerSourceDir = ' D:\Inst ' }
        $r.Values.Actions | Should -Be @('VmTools', 'MsTeams', 'Bogus')
        $r.Values.InstallerSourceDir | Should -Be 'D:\Inst'
        (Test-GISettingsSection -Section Packages -Values $r.Values).Actions | Should -BeLike '*Bogus*'
    }
    It 'treats no ticked boxes as an empty selection' {
        (ConvertFrom-GISettingsForm -Section Packages -Form @{ InstallerSourceDir = '' }).Values.Actions.Count | Should -Be 0
    }
    It 'saves to GoldenImage.Actions and GoldenImage.InstallerSourceDir' {
        $p = New-SettingsConfig
        $null = Save-GISettingsSection -Config (Get-GIConfig -Path $p) -Section Packages -Values @{ Actions = @('VmTools', 'Horizon'); InstallerSourceDir = 'D:\Inst'; ActionTimeoutMin = 60 }
        $c = Get-GIConfig -Path $p
        $c.GoldenImage.Actions | Should -Be @('VmTools', 'Horizon')
        $c.GoldenImage.InstallerSourceDir | Should -Be 'D:\Inst'
        $c.GoldenImage.VmName | Should -Be 'W11-GI-01'
    }
    It 'requires a package timeout between 5 and 600 minutes' {
        (Test-GISettingsSection -Section Packages -Values @{ Actions = @(); InstallerSourceDir = ''; ActionTimeoutMin = 2 }).ActionTimeoutMin | Should -BeLike 'Must be between 5 and 600*'
    }
    It 'returns installer status with the section values' {
        $d = (Get-GISettingsSection -Config (Get-GIConfig -Path (New-SettingsConfig)) -Section Packages)
        $d.Installers | Should -Not -BeNullOrEmpty
        @($d.Installers.Packages).Count | Should -Be 9
        (Get-GISettingsSection -Config (Get-GIConfig -Path (New-SettingsConfig)) -Section vCenter).ContainsKey('Installers') | Should -BeFalse
    }
}

Describe 'Guest script settings' {
    It 'writes nothing when no guest script settings are set' {
        @(Get-GIGuestScriptConfigLines -Config @{ GoldenImage = @{ VmName = 'x' } }).Count | Should -Be 0
    }
    It 'builds config lines in the format the guest script parses' {
        $c = @{ GoldenImage = @{ GuestScript = @{
            AppVolManager = @('avm1.example.com', ' avm2.example.com ')
            AppVolEnforceSSLVal = $false
            AppVolMaxDelayTimeOutS = 30
            DemConfigPath = '\\fs.example.com\dem$\general'
        } } }
        $l = @(Get-GIGuestScriptConfigLines -Config $c)
        $l | Should -Contain 'AppVolManager = @("avm1.example.com", "avm2.example.com")'
        $l | Should -Contain 'AppVolEnforceSSLVal = $false'
        $l | Should -Contain 'AppVolMaxDelayTimeOutS = 30'
        $l | Should -Contain 'DemConfigPath = "\\fs.example.com\dem$\general"'
    }
    It 'skips empty lists and blank strings so script defaults apply' {
        $c = @{ GoldenImage = @{ GuestScript = @{ AppVolManager = @(); DemConfigPath = '  ' } } }
        @(Get-GIGuestScriptConfigLines -Config $c).Count | Should -Be 0
    }
    It 'only emits keys the guest script knows' {
        $script = Get-Content -Raw (Join-Path $PSScriptRoot '..' '..' 'VDI-GoldenImage.ps1')
        foreach ($f in (Get-GISettingsSchema).GuestScript.Fields) { $script | Should -Match "(?m)^\s*$([regex]::Escape($f.Key))\s*=" }
    }
}
