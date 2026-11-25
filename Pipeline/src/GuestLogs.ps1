# Guest log collection and the per-run log bundle. See docs/CONTRACT.md "Guest logs".
# Collected into <Paths.Logs>/<RunId>/guest/ on the host before CleanupGuest deletes anything in the guest.

function Get-GIGuestLogScript {
    <#
    .SYNOPSIS
      (pure) PowerShell 5.1 text that runs inside the guest. It copies logs into a staging folder (each file capped,
      very large logs reduced to their last part with a note), exports a bounded event log extract, and zips the folder.
      Prints one line 'GILOGZIP=<path>' on success. Never includes credential or vault files.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][datetime]$WindowStart,
        [int]$MaxFileMB = 20
    )
    $p = Get-GIWatcherPaths -Config $Config
    $L = { param($s) ConvertTo-GIPsLiteral $s }
    $text = @'
$ErrorActionPreference = 'Continue'
$work = '{WORK}'; $logDir = '{LOGDIR}'; $installDir = '{INSTALLDIR}'
$start = [datetime]::Parse('{START}', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
$maxBytes = {MAXMB} * 1MB
$stage = Join-Path $work 'logcollect'
$zip = Join-Path $work 'guest-logs.zip'
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$notes = New-Object System.Collections.Generic.List[string]
$deny = '(?i)(vault|secret|credential|\.cred|\.key|\.pfx|password|\.clixml)'
function Add-GIFiles([string]$Group, [string[]]$Paths, [string[]]$Patterns, [switch]$Recurse) {
    $dest = Join-Path $stage $Group
    foreach ($dir in $Paths) {
        if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($pat in $Patterns) {
            $items = @(Get-ChildItem -LiteralPath $dir -Filter $pat -File -Recurse:$Recurse -ErrorAction SilentlyContinue)
            foreach ($f in $items) {
                if ($f.Name -match $deny) { $notes.Add("Skipped (credential-like name): $($f.FullName)"); continue }
                try {
                    New-Item -ItemType Directory -Path $dest -Force | Out-Null
                    $name = $f.Name
                    $target = Join-Path $dest $name
                    $i = 1; while (Test-Path -LiteralPath $target) { $target = Join-Path $dest ('{0}-{1}{2}' -f $f.BaseName, $i, $f.Extension); $i++ }
                    if ($f.Length -gt $maxBytes) {
                        $fs = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
                        try {
                            $null = $fs.Seek(-$maxBytes, 'End'); $buf = New-Object byte[] $maxBytes; $n = $fs.Read($buf, 0, $maxBytes)
                            [System.IO.File]::WriteAllBytes($target, $buf[0..($n - 1)])
                        } finally { $fs.Dispose() }
                        $notes.Add("Truncated to the last $([int]($maxBytes / 1MB)) MB (original $([math]::Round($f.Length / 1MB, 1)) MB): $($f.FullName)")
                    } else {
                        $fs = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
                        try { $out = [System.IO.File]::Create($target); try { $fs.CopyTo($out) } finally { $out.Dispose() } } finally { $fs.Dispose() }
                    }
                } catch { $notes.Add("Could not read $($f.FullName): $($_.Exception.Message)") }
            }
        }
    }
}
# Pipeline watcher
Add-GIFiles 'watcher' @($work) @('watcher.log', '*.log', '*.txt')
Add-GIFiles 'watcher\steps' @((Join-Path $work 'steps')) @('*.json', '*.log', '*.txt', '*.out')
# Guest script logs and installer folder logs
Add-GIFiles 'script-logs' @($logDir) @('*.log', '*.txt')
Add-GIFiles 'install-dir' @($installDir) @('*.log', '*.txt')
# Windows servicing and update
Add-GIFiles 'windows-update' @('C:\Windows\Logs\WindowsUpdate') @('*.etl', '*.log')
Add-GIFiles 'windows' @('C:\Windows\Logs\CBS') @('CBS.log')
Add-GIFiles 'windows' @('C:\Windows\Logs\DISM') @('dism.log')
try {
    $wul = Join-Path $stage 'windows-update\WindowsUpdate-merged.txt'
    New-Item -ItemType Directory -Path (Split-Path $wul) -Force | Out-Null
    Get-WindowsUpdateLog -LogPath $wul -ErrorAction Stop | Out-Null
} catch { $notes.Add("Get-WindowsUpdateLog did not run: $($_.Exception.Message)") }
# Windows Installer logs (system temp and the temp folder of the account that ran the installers)
Add-GIFiles 'msi' @('C:\Windows\Temp', $env:TEMP) @('MSI*.LOG', 'MSI*.log')
# Product installers
$products = @{
    'horizon'     = @('C:\ProgramData\VMware\VDM\logs', 'C:\ProgramData\VMware\VDM\logs\Debug')
    'dem'         = @('C:\ProgramData\VMware\Dynamic Environment Manager\Logs', 'C:\ProgramData\VMware\FlexEngine\Logs', (Join-Path $env:LOCALAPPDATA 'VMware\Dynamic Environment Manager\Logs'))
    'appvolumes'  = @('C:\Program Files (x86)\CloudVolumes\Agent\Logs', 'C:\ProgramData\CloudVolumes\Agent\Logs')
    'fslogix'     = @('C:\ProgramData\FSLogix\Logs', 'C:\ProgramData\FSLogix\Logs\Install')
    'teams'       = @((Join-Path $env:TEMP 'teams*'), (Join-Path $env:LOCALAPPDATA 'Temp\TeamsBootstrapper'))
    'onedrive'    = @((Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\setup\logs'), 'C:\ProgramData\Microsoft OneDrive\setup\logs')
    'vmtools'     = @('C:\ProgramData\VMware\VMware Tools')
}
foreach ($k in $products.Keys) {
    foreach ($d in $products[$k]) {
        foreach ($real in @(Resolve-Path -Path $d -ErrorAction SilentlyContinue)) { Add-GIFiles $k @($real.ProviderPath) @('*.log', '*.txt') }
    }
}
# Event logs: errors and warnings from the installer and Windows Update providers, limited to this run
try {
    $ev = New-Object System.Collections.Generic.List[string]
    foreach ($log in 'Application', 'System') {
        $rows = @(Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $start; Level = 1, 2, 3 } -MaxEvents 5000 -ErrorAction SilentlyContinue |
            Where-Object { $_.ProviderName -match 'MsiInstaller|WindowsUpdate|Windows Update|Servicing|Horizon|VMware|FSLogix|CloudVolumes' })
        foreach ($r in $rows) { $ev.Add(('{0:o} [{1}] {2} {3}: {4}' -f $r.TimeCreated, $log, $r.LevelDisplayName, $r.ProviderName, (($r.Message -replace '\s+', ' ').Trim()))) }
    }
    New-Item -ItemType Directory -Path (Join-Path $stage 'eventlog') -Force | Out-Null
    [System.IO.File]::WriteAllLines((Join-Path $stage 'eventlog\events.txt'), $ev.ToArray())
} catch { $notes.Add("Event log export failed: $($_.Exception.Message)") }
[System.IO.File]::WriteAllLines((Join-Path $stage '_collection-notes.txt'), $notes.ToArray())
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
'GILOGZIP=' + $zip
'@
    return $text.Replace('{WORK}', (& $L $p.WorkDir)).Replace('{LOGDIR}', (& $L $p.LogDir)).Replace('{INSTALLDIR}', (& $L $p.InstallDir)).Replace('{START}', $WindowStart.ToString('o')).Replace('{MAXMB}', [string][int]$MaxFileMB)
}

function Get-GIRunGuestLogDir {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$RunId)
    Join-Path (Join-Path $Config.Paths.Logs $RunId) 'guest'
}

function Invoke-GIGuestLogCollection {
    <#
    .SYNOPSIS
      Pulls the guest logs to <Logs>/<RunId>/guest/. Never throws. Returns @{ Collected; Skipped; Message; Files }.
      Skipped when the guest is off or can't be reached (the reason is in Message).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)] $Run,
        [Parameter(Mandatory)] $VM,
        [Parameter(Mandatory)][pscredential]$Credential,
        [string]$Reason = 'step'
    )
    $runId = [string]$Run.runId
    $result = @{ Collected = $false; Skipped = $false; Message = ''; Files = 0 }
    try {
        $vmNow = Get-VM -Id $VM.Id -ErrorAction Stop
        if ($vmNow.PowerState -ne 'PoweredOn') {
            $result.Skipped = $true; $result.Message = "Guest is $($vmNow.PowerState); nothing to collect"
            return $result
        }
        $start = (Get-Date).AddHours(-12)
        try { $start = [datetime]::Parse([string]$Run.createdAt, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { Write-Verbose 'Using the last 12 hours for the event log window' }
        $script = Get-GIGuestLogScript -Config $Config -WindowStart $start
        $out = Invoke-GIGuestScript -VM $VM -Credential $Credential -ScriptText $script
        $line = @(([string]$out.ScriptOutput) -split "`r?`n" | Where-Object { $_ -like 'GILOGZIP=*' }) | Select-Object -Last 1
        if (-not $line) { throw 'The guest did not report a log archive.' }
        $guestZip = $line.Substring('GILOGZIP='.Length).Trim()
        $dir = Get-GIRunGuestLogDir -Config $Config -RunId $runId
        $tmpZip = Join-Path ([System.IO.Path]::GetTempPath()) "gi-guestlogs-$([guid]::NewGuid().ToString('N')).zip"
        try {
            Copy-VMGuestFile -Source $guestZip -Destination $tmpZip -VM $VM -GuestToLocal -GuestCredential $Credential -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Expand-GILogZip -ZipPath $tmpZip -Destination $dir
        } finally { Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue }
        $result.Files = @(Get-ChildItem -LiteralPath $dir -File -Recurse).Count
        $result.Collected = $true
        $result.Message = "Collected $($result.Files) guest log file(s) ($Reason)"
        Write-GILog -Config $Config -RunId $runId -Message $result.Message
    } catch {
        $result.Skipped = $true
        $result.Message = "Guest logs not collected: $($_.Exception.Message)"
        Write-GILog -Config $Config -RunId $runId -Level Warn -Message $result.Message
    }
    return $result
}

function Expand-GILogZip {
    # Extracts a zip, refusing entries that would land outside the destination.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ZipPath, [Parameter(Mandatory)][string]$Destination)
    Add-Type -AssemblyName System.IO.Compression
    $root = [System.IO.Path]::GetFullPath($Destination).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($e in $zip.Entries) {
            $rel = $e.FullName.Replace('\', '/')
            $full = [System.IO.Path]::GetFullPath((Join-Path $Destination $rel))
            if (-not $full.StartsWith($root, [StringComparison]::Ordinal)) { continue }
            if ($rel.EndsWith('/')) { $null = New-Item -ItemType Directory -Path $full -Force; continue }
            $null = New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $full, $true)
        }
    } finally { $zip.Dispose() }
}

#----- Bundle -----

function Get-GILogBundleName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$RunId)
    $n = if ($Config.ContainsKey('ImageName') -and $Config.ImageName) { [string]$Config.ImageName } else { [string]$Config.GoldenImage.VmName }
    $safe = ($n -replace '[^A-Za-z0-9._-]+', '-').Trim('-')
    if (-not $safe) { $safe = 'image' }
    "$safe-$RunId-logs.zip"
}

function New-GILogBundle {
    <#
    .SYNOPSIS
      Builds the log bundle zip for a run into a temp file (streamed from disk, never held in memory) and returns
      @{ Path; Name; Included; Missing }. The caller deletes the file after sending it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$RunId, [string]$OutPath)
    if (-not (Test-GIRunId $RunId)) { throw 'Invalid run id.' }
    if (-not $OutPath) { $OutPath = Join-Path ([System.IO.Path]::GetTempPath()) "gi-bundle-$([guid]::NewGuid().ToString('N')).zip" }
    $logs = $Config.Paths.Logs
    $files = [System.Collections.Generic.List[object]]::new()   # @{ Source; Entry }
    $missing = [System.Collections.Generic.List[string]]::new()
    $want = @(
        @{ Source = Join-Path $logs "$RunId.log"; Entry = "host/$RunId.log"; Label = 'host run log' }
        @{ Source = Join-Path $logs "$RunId.watcher.log"; Entry = "host/$RunId.watcher.log"; Label = 'watcher log' }
        @{ Source = Join-Path $logs "$RunId.watcher.guest.log"; Entry = "host/$RunId.watcher.guest.log"; Label = 'guest watcher log' }
        @{ Source = Join-Path $Config.Paths.State "$RunId.json"; Entry = 'run.json'; Label = 'run state' }
        @{ Source = Join-Path $Config.Paths.Reports "$RunId.html"; Entry = 'report.html'; Label = 'HTML report' }
    )
    foreach ($w in $want) {
        if (Test-Path -LiteralPath $w.Source -PathType Leaf) { $files.Add($w) } else { $missing.Add("$($w.Label) ($($w.Entry)) was not found") }
    }
    $guestDir = Get-GIRunGuestLogDir -Config $Config -RunId $RunId
    $guestNotes = @()
    if (Test-Path -LiteralPath $guestDir) {
        $gRoot = (Resolve-Path -LiteralPath $guestDir).ProviderPath.TrimEnd('/', '\')
        foreach ($f in Get-ChildItem -LiteralPath $guestDir -File -Recurse) {
            $rel = $f.FullName.Substring($gRoot.Length).TrimStart('/', '\').Replace('\', '/')
            $files.Add(@{ Source = $f.FullName; Entry = "guest/$rel"; Label = 'guest log' })
        }
        $notePath = Join-Path $guestDir '_collection-notes.txt'
        if (Test-Path -LiteralPath $notePath) { $guestNotes = @(Get-Content -LiteralPath $notePath -Encoding UTF8 | Where-Object { $_ }) }
    } else {
        $missing.Add('Guest logs were not collected for this run (the guest was off, unreachable, or the run is older than this feature).')
    }
    $readme = [System.Collections.Generic.List[string]]::new()
    $readme.Add("Log bundle for run $RunId"); $readme.Add("Created $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"); $readme.Add('')
    $readme.Add('Contents'); foreach ($f in $files) { $readme.Add("  $($f.Entry)  ($($f.Label))") }
    $readme.Add('  README.txt  (this file)'); $readme.Add('')
    if ($missing.Count) { $readme.Add('Missing or skipped'); foreach ($m in $missing) { $readme.Add("  $m") }; $readme.Add('') }
    if ($guestNotes.Count) { $readme.Add('Guest collection notes (truncated or skipped files)'); foreach ($n in $guestNotes) { $readme.Add("  $n") }; $readme.Add('') }
    $readme.Add('Logs are not redacted. Credential and vault files are never collected.')

    Add-Type -AssemblyName System.IO.Compression
    if (Test-Path -LiteralPath $OutPath) { Remove-Item -LiteralPath $OutPath -Force }
    $fs = [System.IO.File]::Create($OutPath)
    try {
        $zip = [System.IO.Compression.ZipArchive]::new($fs, [System.IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $re = $zip.CreateEntry('README.txt')
            $sw = [System.IO.StreamWriter]::new($re.Open(), [System.Text.UTF8Encoding]::new($false))
            try { $sw.Write(($readme -join [Environment]::NewLine)) } finally { $sw.Dispose() }
            foreach ($f in $files) {
                try {
                    $in = [System.IO.File]::Open($f.Source, 'Open', 'Read', 'ReadWrite')
                } catch { $missing.Add("$($f.Entry) could not be read: $($_.Exception.Message)"); continue }
                try {
                    $e = $zip.CreateEntry($f.Entry, [System.IO.Compression.CompressionLevel]::Optimal)
                    $o = $e.Open()
                    try { $in.CopyTo($o) } finally { $o.Dispose() }
                } finally { $in.Dispose() }
            }
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }
    return @{ Path = $OutPath; Name = (Get-GILogBundleName -Config $Config -RunId $RunId); Included = @($files | ForEach-Object { $_.Entry }); Missing = @($missing) }
}

#----- Fix catalog (read only) -----

function Get-GIFixCatalogView {
    <# Read-only view of guest/fixes/*.ps1 for the dashboard, plus the last run id that used each fix. Never runs a fix. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)
    $guestDir = Join-Path $Config.Root 'guest'
    $core = Join-Path $guestDir 'GIWatcher.Core.ps1'
    if (-not (Test-Path -LiteralPath $core)) { return @() }
    if (-not (Get-Command Read-GIFixCatalog -ErrorAction SilentlyContinue)) { . $core }
    $catalog = @(Read-GIFixCatalog -Path (Join-Path $guestDir 'fixes'))
    $used = @{}
    foreach ($ic in @(Get-GIImageConfigs -Config $Config)) {
        foreach ($r in @(Get-GIRunList -Config $ic)) {
            try {
                foreach ($s in @(Get-GIStepList -Run $r)) {
                    foreach ($fx in @($s.PSObject.Properties['fixes'] ? $s.fixes : @())) {
                        $fid = [string](Get-GIWatcherProp $fx 'id' (Get-GIWatcherProp $fx 'fixId' ''))
                        if ($fid -and (-not $used.ContainsKey($fid) -or [string]$r.runId -gt $used[$fid])) { $used[$fid] = [string]$r.runId }
                    }
                }
            } catch { Write-Verbose "Skipping run $($r.runId) for fix usage: $($_.Exception.Message)" }
        }
    }
    foreach ($c in $catalog) {
        $m = Get-GIWatcherProp $c 'Meta' $c
        $id = [string](Get-GIWatcherProp $m 'Id' (Get-GIWatcherProp $c 'Id' ''))
        [ordered]@{
            id = $id; file = [string](Get-GIWatcherProp $c 'File' (Get-GIWatcherProp $c 'Path' ''))
            valid = [bool](Get-GIWatcherProp $c 'Valid' $true); errors = @(Get-GIWatcherProp $c 'Errors' @())
            description = [string](Get-GIWatcherProp $m 'Description' ''); priority = [int](Get-GIWatcherProp $m 'Priority' 0)
            actions = @(Get-GIWatcherProp $m 'Actions' @()); maxAttempts = [int](Get-GIWatcherProp $m 'MaxAttempts' 0)
            rebootFromAttempt = [int](Get-GIWatcherProp $m 'RebootFromAttempt' 0)
            match = Get-GIWatcherProp $m 'Match' @{}
            lastUsedRunId = if ($used.ContainsKey($id)) { $used[$id] } else { '' }
        }
    }
}
