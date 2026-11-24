<#
.SYNOPSIS
  Start here. Prepares this machine and starts the golden image pipeline dashboard.
.DESCRIPTION
  Runs in Windows PowerShell 5.1 or PowerShell 7.
  1. If PowerShell 7.2+ isn't available, offers to install it (winget, or the MSI from GitHub) and relaunches in it.
  2. Production setup needs an elevated session; it relaunches elevated (skip with -LocalAdmin for a lab/test run).
  3. Installs the Pode module if missing (the only module installed before the web server starts).
  4. Until setup is complete, starts the dashboard in setup mode on http://127.0.0.1:<Port> and opens /setup,
     where the remaining modules, the secret vault, the dashboard certificate and the scheduled tasks are set up
     with live status. After setup, starts (or points you to) the normal dashboard.
.PARAMETER LocalAdmin
  Lab/test run: no elevation, modules for the current user only, no scheduled tasks, and the dashboard stays on
  127.0.0.1 without sign-in. Still goes through /setup on first run.
.PARAMETER Port
  Port for the setup page and for -LocalAdmin (default 8080). The production dashboard uses the port chosen in setup.
.PARAMETER ResetSetup
  Moves config/setup.json aside so setup runs again.
.PARAMETER NoBrowser
  Don't open a browser; just print the address.
.EXAMPLE
  PS> .\Start-GIPipeline.ps1
.EXAMPLE
  PS> .\Start-GIPipeline.ps1 -LocalAdmin
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [ValidateRange(1, 65535)] [int] $Port = 8080,
    [switch] $LocalAdmin,
    [switch] $NoBrowser,
    [switch] $ResetSetup
)
$ErrorActionPreference = 'Stop'

function Get-GILauncherArgs {
    # Rebuilds this script's arguments for a relaunch
    param([hashtable] $Bound)
    $list = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($k in $Bound.Keys) {
        $v = $Bound[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { $list += "-$k" } }
        else { $list += "-$k"; $list += "`"$v`"" }
    }
    return $list
}

function Find-GIPwsh {
    # Path of a PowerShell 7.2+ executable, or $null
    $candidates = @()
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe') }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) {
            try {
                $v = & $c -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
                if ([version]$v -ge [version]'7.2') { return $c }
            } catch { Write-Verbose "Can't run ${c}: $($_.Exception.Message)" }
        }
    }
    return $null
}

function Install-GIPwsh {
    # winget first, then the MSI from the PowerShell GitHub releases
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host 'Installing PowerShell 7 with winget...'
        & winget install --id Microsoft.PowerShell -e --source winget --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -eq 0) { return }
        Write-Warning "winget exited with $LASTEXITCODE; trying the MSI instead."
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -UseBasicParsing
    $asset = $rel.assets | Where-Object { $_.name -like 'PowerShell-*-win-x64.msi' } | Select-Object -First 1
    if (-not $asset) { throw 'Could not find the PowerShell 7 MSI in the latest GitHub release.' }
    $msi = Join-Path $env:TEMP $asset.name
    Write-Host "Downloading $($asset.name)..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msi -UseBasicParsing
    Write-Host 'Installing (an installer window shows progress)...'
    $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$msi`"", '/qb', 'ADD_PATH=1', 'REGISTER_MANIFEST=1') -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "The PowerShell 7 installer exited with $($p.ExitCode)." }
}

#----- 1. PowerShell 7 -----
$isCore = $PSVersionTable.PSEdition -eq 'Core'
if (-not $isCore -or $PSVersionTable.PSVersion -lt [version]'7.2') {
    $pwsh = Find-GIPwsh
    if (-not $pwsh) {
        Write-Host 'This pipeline needs PowerShell 7.2 or later, which is not installed.' -ForegroundColor Yellow
        $answer = Read-Host 'Install PowerShell 7 now? [Y/N]'
        if ($answer -notmatch '^(y|yes)$') {
            Write-Host 'Install it yourself with:  winget install --id Microsoft.PowerShell -e'
            Write-Host 'Then run this script again.'
            exit 1
        }
        Install-GIPwsh
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
        $pwsh = Find-GIPwsh
        if (-not $pwsh) { throw 'PowerShell 7 was installed but pwsh.exe was not found. Open a new console and run this script again.' }
    }
    Write-Host "Relaunching in PowerShell 7 ($pwsh)..."
    $p = Start-Process -FilePath $pwsh -ArgumentList (Get-GILauncherArgs -Bound $PSBoundParameters) -NoNewWindow -Wait -PassThru
    exit $p.ExitCode
}

#----- 2. Elevation (production only) -----
if ($IsWindows -and -not $LocalAdmin) {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host 'Production setup installs modules for all users, a certificate and scheduled tasks, so it needs to run as administrator.'
        Write-Host 'Relaunching elevated (for a lab/test run without admin, use -LocalAdmin)...'
        Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList (Get-GILauncherArgs -Bound $PSBoundParameters) -Verb RunAs
        exit 0
    }
}

#----- 3. Pode -----
$scope = if ($LocalAdmin) { 'CurrentUser' } else { 'AllUsers' }
$pode = Get-Module -ListAvailable -Name Pode | Where-Object { $_.Version -ge [version]'2.10.0' -and $_.Version.Major -eq 2 } | Select-Object -First 1
if (-not $pode) {
    Write-Host "Installing the Pode web server module ($scope)..."
    if ($IsWindows -and -not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope $scope -Force | Out-Null
    }
    Install-Module -Name Pode -MinimumVersion 2.10.0 -MaximumVersion 2.99.99 -Repository PSGallery -Scope $scope -Force -AllowClobber
    Write-Host 'Pode installed.'
}

#----- 4. Start -----
Import-Module (Join-Path $PSScriptRoot 'VDI-GIPipeline.psd1') -Force
$config = if ($ConfigPath) { Get-GIConfig -Path $ConfigPath } else { Get-GIConfig }
if ($ResetSetup) {
    $moved = Reset-GISetup -Config $config
    if ($moved) { Write-Host "Previous setup state moved to $moved; setup will run again." }
}

$dashboard = Join-Path $PSScriptRoot 'Web\Start-GIDashboard.ps1'
$dashArgs = @{ Port = $Port }
if ($ConfigPath) { $dashArgs.ConfigPath = $ConfigPath }

function Open-GIBrowserLater {
    param([string] $Url)
    if ($NoBrowser -or -not $IsWindows) { Write-Host "Open $Url in a browser."; return }
    # The server starts in this console, so open the browser once it's listening
    Start-ThreadJob -ScriptBlock {
        $u = $using:Url
        for ($i = 0; $i -lt 30; $i++) {
            try { Invoke-WebRequest -Uri $u -Method Head -TimeoutSec 2 -SkipHttpErrorCheck | Out-Null; break } catch { Start-Sleep -Seconds 1 }
        }
        Start-Process $u
    } | Out-Null
    Write-Host "Opening $Url ..."
}

if (-not (Test-GISetupComplete -Config $config)) {
    Open-GIBrowserLater -Url "http://127.0.0.1:$Port/setup"
    & $dashboard @dashArgs -Setup -LocalAdmin:$LocalAdmin
    # The setup server stops itself after a production setup finishes; hand over to the dashboard task
    if (-not (Test-GISetupComplete -Config $config)) { exit 0 }
    $config = if ($ConfigPath) { Get-GIConfig -Path $ConfigPath } else { Get-GIConfig }
    if ($LocalAdmin) { exit 0 }
}

if ($LocalAdmin) {
    Open-GIBrowserLater -Url "http://127.0.0.1:$Port/"
    & $dashboard @dashArgs -LocalAdmin
    exit 0
}

$prodPort = [int](Get-GIConfigValue $config 'Dashboard.Port' 8443)
$url = "https://$([System.Net.Dns]::GetHostName()):$prodPort/"
$task = if ($IsWindows) { Get-ScheduledTask -TaskName 'VDI-GI-Dashboard' -ErrorAction SilentlyContinue }
if ($task) {
    if ($task.State -ne 'Running') { Start-ScheduledTask -TaskName 'VDI-GI-Dashboard'; Write-Host 'Started the VDI-GI-Dashboard task.' }
    else { Write-Host 'The VDI-GI-Dashboard task is already running.' }
    Write-Host "Dashboard: $url"
    if (-not $NoBrowser -and $IsWindows) { Start-Process $url }
    exit 0
}
Write-Host 'No VDI-GI-Dashboard task registered; running the dashboard in this console (Ctrl+C to stop).'
$prodArgs = @{}
if ($ConfigPath) { $prodArgs.ConfigPath = $ConfigPath }
Open-GIBrowserLater -Url $url
& $dashboard @prodArgs
