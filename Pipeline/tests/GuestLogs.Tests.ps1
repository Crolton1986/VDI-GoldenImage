BeforeAll {
    # Stand-ins for PowerCLI so the module's calls to them can be mocked
    foreach ($n in 'Get-VM', 'Copy-VMGuestFile') { Set-Item "function:global:$n" { } }
    Import-Module (Join-Path $PSScriptRoot '..' 'VDI-GIPipeline.psd1') -Force
    function script:New-Cfg {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("gi-gl-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $root | Out-Null
        Copy-Item (Join-Path $PSScriptRoot '..' 'pipeline.config.psd1') $root
        $c = Get-GIConfig -Path (Join-Path $root 'pipeline.config.psd1')
        $c.ImageName = 'Main desktop'
        $c
    }
}

AfterAll { Remove-Item function:global:Get-VM, function:global:Copy-VMGuestFile -ErrorAction SilentlyContinue }

Describe 'Guest log script' {
    BeforeAll { $script:cfg = New-Cfg }
    AfterAll { Remove-Item $script:cfg.Root -Recurse -Force -ErrorAction SilentlyContinue }
    It 'is valid PowerShell and covers every required source' {
        $t = Get-GIGuestLogScript -Config $script:cfg -WindowStart ([datetime]'2026-11-01T10:00:00')
        $err = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($t, [ref]$null, [ref]$err)
        $err | Should -BeNullOrEmpty
        foreach ($needle in 'watcher.log', "'steps'", 'Get-WindowsUpdateLog', 'C:\Windows\Logs\WindowsUpdate', 'CBS.log', 'dism.log', 'MSI*.LOG', 'VMware\VDM\logs', 'FSLogix', 'OneDrive', 'CloudVolumes', 'Dynamic Environment Manager', 'Get-WinEvent', 'MsiInstaller', 'GILOGZIP=') {
            $t | Should -Match ([regex]::Escape($needle)) -Because $needle
        }
        $t | Should -Match 'C:\\ProgramData\\VDI\\Pipeline'
    }
    It 'never collects credential-like files and caps file size' {
        $t = Get-GIGuestLogScript -Config $script:cfg -WindowStart (Get-Date) -MaxFileMB 5
        $t | Should -Match 'vault\|secret\|credential'
        $t | Should -Match '\$maxBytes = 5 \* 1MB'
        $t | Should -Match 'Truncated to the last'
    }
}

Describe 'Maintain step plan' {
    It 'has Collect guest logs right before CleanupGuest' {
        $cfg = New-Cfg
        $ids = @(Get-GIMaintainStepPlan -Config $cfg | ForEach-Object Id)
        $ids.IndexOf('CollectGuestLogs') | Should -Be ($ids.IndexOf('CleanupGuest') - 1)
    }
}

Describe 'Invoke-GIGuestLogCollection' {
    BeforeEach { $script:cfg = New-Cfg; $script:run = [pscustomobject]@{ runId = '20261101-010101'; createdAt = (Get-Date).ToString('o') }; $script:vm = [pscustomobject]@{ Id = 'vm-1' } }
    AfterEach { Remove-Item $script:cfg.Root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'skips (never throws) when the guest is off' {
        InModuleScope VDI-GIPipeline -Parameters @{ c = $script:cfg; r = $script:run; v = $script:vm } {
            param($c, $r, $v)
            Mock Get-VM { [pscustomobject]@{ PowerState = 'PoweredOff' } }
            Mock Write-GILog {}
            $res = Invoke-GIGuestLogCollection -Config $c -Run $r -VM $v -Credential ([pscredential]::new('a', (ConvertTo-SecureString 'x' -AsPlainText -Force)))
            $res.Skipped | Should -BeTrue
            $res.Message | Should -Match 'PoweredOff'
        }
    }
    It 'skips with the reason when the guest is unreachable' {
        InModuleScope VDI-GIPipeline -Parameters @{ c = $script:cfg; r = $script:run; v = $script:vm } {
            param($c, $r, $v)
            Mock Get-VM { [pscustomobject]@{ PowerState = 'PoweredOn' } }
            Mock Invoke-GIGuestScript { throw 'VMware Tools is not running' }
            Mock Write-GILog {}
            $res = Invoke-GIGuestLogCollection -Config $c -Run $r -VM $v -Credential ([pscredential]::new('a', (ConvertTo-SecureString 'x' -AsPlainText -Force)))
            $res.Skipped | Should -BeTrue; $res.Collected | Should -BeFalse
            $res.Message | Should -Match 'VMware Tools is not running'
        }
    }
    It 'copies the guest archive to <Logs>/<RunId>/guest and expands it' {
        InModuleScope VDI-GIPipeline -Parameters @{ c = $script:cfg; r = $script:run; v = $script:vm } {
            param($c, $r, $v)
            Mock Get-VM { [pscustomobject]@{ PowerState = 'PoweredOn' } }
            Mock Invoke-GIGuestScript { [pscustomobject]@{ ScriptOutput = "noise`r`nGILOGZIP=C:\ProgramData\VDI\Pipeline\guest-logs.zip`r`n" } }
            Mock Write-GILog {}
            Mock Copy-VMGuestFile {
                param($Source, $Destination)
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $d = Join-Path ([IO.Path]::GetTempPath()) "src-$([guid]::NewGuid().ToString('N'))"
                New-Item -ItemType Directory "$d/msi", "$d/watcher/steps" -Force | Out-Null
                'msi log' | Set-Content "$d/msi/MSI1.LOG"; '{}' | Set-Content "$d/watcher/steps/Pkg_Horizon.json"
                'Truncated to the last 20 MB (original 80 MB): C:\x.log' | Set-Content "$d/_collection-notes.txt"
                [IO.Compression.ZipFile]::CreateFromDirectory($d, $Destination); Remove-Item $d -Recurse -Force
            }
            $res = Invoke-GIGuestLogCollection -Config $c -Run $r -VM $v -Credential ([pscredential]::new('a', (ConvertTo-SecureString 'x' -AsPlainText -Force))) -Reason 'after a failure'
            $res.Collected | Should -BeTrue; $res.Files | Should -Be 3
            $dir = Get-GIRunGuestLogDir -Config $c -RunId '20261101-010101'
            Test-Path (Join-Path $dir 'msi' 'MSI1.LOG') | Should -BeTrue
            Test-Path (Join-Path $dir 'watcher' 'steps' 'Pkg_Horizon.json') | Should -BeTrue
        }
    }
    It 'refuses zip entries that escape the destination' {
        InModuleScope VDI-GIPipeline {
            Add-Type -AssemblyName System.IO.Compression
            $zipPath = Join-Path ([IO.Path]::GetTempPath()) "evil-$([guid]::NewGuid().ToString('N')).zip"
            $fs = [IO.File]::Create($zipPath); $z = [IO.Compression.ZipArchive]::new($fs, 'Create')
            $w = [IO.StreamWriter]::new($z.CreateEntry('../escaped.txt').Open()); $w.Write('x'); $w.Dispose(); $z.Dispose(); $fs.Dispose()
            $dest = Join-Path ([IO.Path]::GetTempPath()) "dest-$([guid]::NewGuid().ToString('N'))"
            Expand-GILogZip -ZipPath $zipPath -Destination $dest
            Test-Path (Join-Path (Split-Path $dest) 'escaped.txt') | Should -BeFalse
            Remove-Item $zipPath, $dest -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Log bundle' {
    BeforeEach { $script:cfg = New-Cfg }
    AfterEach { Remove-Item $script:cfg.Root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'zips host logs, run json, report and guest logs with a README that lists truncations and gaps' {
        $c = $script:cfg; $id = '20261101-010101'
        Set-Content (Join-Path $c.Paths.Logs "$id.log") 'host'
        Set-Content (Join-Path $c.Paths.Logs "$id.watcher.log") 'watcher'
        Set-Content (Join-Path $c.Paths.State "$id.json") '{}'
        $g = Get-GIRunGuestLogDir -Config $c -RunId $id
        New-Item -ItemType Directory (Join-Path $g 'msi') -Force | Out-Null
        Set-Content (Join-Path $g 'msi' 'MSI1.LOG') 'installer'
        Set-Content (Join-Path $g '_collection-notes.txt') 'Truncated to the last 20 MB (original 80 MB): C:\big.log'
        $b = New-GILogBundle -Config $c -RunId $id
        try {
            $b.Name | Should -Be "Main-desktop-$id-logs.zip"
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $z = [IO.Compression.ZipFile]::OpenRead($b.Path)
            $names = @($z.Entries.FullName); $z.Dispose()
            foreach ($n in "host/$id.log", "host/$id.watcher.log", 'run.json', 'guest/msi/MSI1.LOG', 'guest/_collection-notes.txt', 'README.txt') { $names | Should -Contain $n }
            $z = [IO.Compression.ZipFile]::OpenRead($b.Path)
            $sr = [IO.StreamReader]::new($z.GetEntry('README.txt').Open()); $readme = $sr.ReadToEnd(); $sr.Dispose(); $z.Dispose()
            $readme | Should -Match 'Truncated to the last 20 MB'
            $readme | Should -Match 'HTML report'
            $readme | Should -Match 'not redacted'
        } finally { Remove-Item $b.Path -Force }
    }
    It 'says so in the README when the guest logs are missing, and rejects a bad run id' {
        $c = $script:cfg; $id = '20261102-010101'
        Set-Content (Join-Path $c.Paths.Logs "$id.log") 'host'
        $b = New-GILogBundle -Config $c -RunId $id
        try {
            $b.Included | Should -Not -Contain 'guest'
            ($b.Missing -join ' ') | Should -Match 'Guest logs were not collected'
        } finally { Remove-Item $b.Path -Force }
        { New-GILogBundle -Config $c -RunId '../evil' } | Should -Throw
    }
}

Describe 'Fix catalog view' {
    It 'lists the catalog read only, with metadata, and never runs a fix' {
        $cfg = New-Cfg
        Copy-Item (Join-Path $PSScriptRoot '..' 'guest') (Join-Path $cfg.Root 'guest') -Recurse
        $f = @(Get-GIFixCatalogView -Config $cfg)
        $f.id | Should -Contain 'InstallerBusy1618'
        $x = $f | Where-Object id -eq 'InstallerBusy1618'
        $x.priority | Should -Be 90
        $x.maxAttempts | Should -Be 3
        $x.match.ExitCodes | Should -Contain 1
        $x.lastUsedRunId | Should -Be ''
    }
}
