# First-run setup steps: Prerequisites, Modules, PowerCLI (see docs/CONTRACT.md "First-run setup").
# Progress lines go through Write-GISetupProgress / Set-GISetupStepData (src/Setup.ps1).

$script:GIRequiredModules = @(
    @{ Name = 'Pode';                                   MinimumVersion = '2.10.0'; MaximumVersion = '2.99.99'; Required = $true;  Note = 'Dashboard web server (2.x only)' }
    @{ Name = 'VMware.PowerCLI';                        MinimumVersion = '13.0.0';                              Required = $true;  Note = 'large; first install takes several minutes' }
    @{ Name = 'Microsoft.PowerShell.SecretManagement';  MinimumVersion = '1.1.2';                               Required = $true;  Note = 'Secret vault API' }
    @{ Name = 'Microsoft.PowerShell.SecretStore';       MinimumVersion = '1.0.6';                               Required = $true;  Note = 'Local encrypted vault' }
    @{ Name = 'Pester';                                 MinimumVersion = '5.5.0';                               Required = $false; Note = 'Tests' }
    @{ Name = 'PSScriptAnalyzer';                       MinimumVersion = '1.21.0';                              Required = $false; Note = 'Lint' }
)

function Get-GIRequiredModule {
    [CmdletBinding()]
    param()
    return , $script:GIRequiredModules
}

function Get-GISetupObjectValue {
    # Optional-key read that works for hashtables and PSCustomObjects under strict mode
    param($Object, [string]$Key, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Key)) { return $Object[$Key] }
        return $Default
    }
    if ($Object.PSObject.Properties[$Key]) { return $Object.PSObject.Properties[$Key].Value }
    return $Default
}

function Get-GIModuleStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Module)

    $min = [version]$Module['MinimumVersion']
    $maxText = if ($Module.Contains('MaximumVersion') -and $Module['MaximumVersion']) { [string]$Module['MaximumVersion'] } else { $null }
    $max = if ($maxText) { [version]$maxText } else { $null }

    $found = @(Get-Module -ListAvailable -Name $Module['Name'] -ErrorAction SilentlyContinue |
            Sort-Object -Property Version -Descending)
    $inRange = @($found | Where-Object { $_.Version -ge $min -and ($null -eq $max -or $_.Version -le $max) })

    $installed = $null
    if ($inRange.Count -gt 0) { $installed = $inRange[0].Version.ToString(); $status = 'ok' }
    elseif ($found.Count -eq 0) { $status = 'missing' }
    else {
        $installed = $found[0].Version.ToString()
        $status = if ($null -ne $max -and $found[0].Version -gt $max) { 'too-new' } else { 'outdated' }
    }

    $required = [string]$Module['MinimumVersion']
    if ($maxText) { $required += " - $maxText" }
    return @{ name = $Module['Name']; required = $required; installed = $installed; status = $status }
}

function Invoke-GISetupModules {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)]$State)

    $mode = Get-GISetupObjectValue $State 'mode'
    $scope = if ($mode -eq 'Production') { 'AllUsers' } else { 'CurrentUser' }
    $step = 'Modules'

    # NuGet provider (not meaningful on non-Windows; skip quietly if it errors there)
    try {
        $nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
            Where-Object { $_.Version -ge [version]'2.8.5.201' } | Select-Object -First 1
        if (-not $nuget) {
            Write-GISetupProgress -Config $Config -Step $step -Line "Installing NuGet package provider ($scope)..."
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope $scope -Force -ErrorAction Stop | Out-Null
        }
    }
    catch {
        if ($IsWindows) { throw "NuGet package provider install failed: $($_.Exception.Message)" }
        Write-GISetupProgress -Config $Config -Step $step -Line "NuGet provider step skipped on this platform: $($_.Exception.Message)"
    }

    # PSGallery trusted for this session's installs
    $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if ($repo -and $repo.InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
        Write-GISetupProgress -Config $Config -Step $step -Line 'PSGallery set to Trusted'
    }
    elseif ($repo) {
        Write-GISetupProgress -Config $Config -Step $step -Line 'PSGallery already trusted'
    }

    $items = [System.Collections.Generic.List[object]]::new()
    $installedCount = 0; $presentCount = 0; $optFailed = 0

    foreach ($mod in $script:GIRequiredModules) {
        $name = $mod['Name']
        $st = Get-GIModuleStatus -Module $mod
        if ($st.status -eq 'ok') {
            Write-GISetupProgress -Config $Config -Step $step -Line "$name $($st.installed) already installed"
            $presentCount++
        }
        else {
            $note = if ($mod['Note'] -and $mod['Note'] -match 'large|several') { " $($mod['Note'])" } else { '' }
            Write-GISetupProgress -Config $Config -Step $step -Line "Installing $name ($scope)...$note"
            $inst = @{
                Name = $name; MinimumVersion = $mod['MinimumVersion']; Scope = $scope
                Force = $true; AllowClobber = $true; ErrorAction = 'Stop'
            }
            if ($mod.Contains('MaximumVersion') -and $mod['MaximumVersion']) { $inst['MaximumVersion'] = $mod['MaximumVersion'] }
            if ($name -eq 'Pester') { $inst['SkipPublisherCheck'] = $true }
            try {
                Install-Module @inst
                $st = Get-GIModuleStatus -Module $mod
                if ($st.status -ne 'ok') { throw "installed but status is '$($st.status)' (found $($st.installed))" }
                Write-GISetupProgress -Config $Config -Step $step -Line "Installed $name $($st.installed)"
                $installedCount++
            }
            catch {
                $err = $_.Exception.Message
                if ($mod['Required']) {
                    $items.Add(@{ name = $name; required = $st.required; installed = $st.installed; status = 'failed'; error = $err })
                    Set-GISetupStepData -Config $Config -Step $step -Data @{ items = @($items) }
                    throw "Required module $name could not be installed: $err"
                }
                Write-GISetupProgress -Config $Config -Step $step -Line "Optional module $name failed: $err"
                $st = @{ name = $name; required = $st.required; installed = $st.installed; status = 'failed'; error = $err }
                $optFailed++
            }
        }
        $items.Add($st)
        Set-GISetupStepData -Config $Config -Step $step -Data @{ items = @($items) }
    }

    $msg = "$installedCount installed, $presentCount already present"
    if ($optFailed -gt 0) { $msg += ", $optFailed optional failed" }
    return @{ Message = $msg; Data = @{ items = @($items) } }
}

function Test-GIIsAdministrator {
    if ($IsWindows) {
        return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
    }
    return ((& id -u) -eq '0')
}

function Get-GIFreeDiskGB {
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $drive = [System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($full))
    return [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
}

function Invoke-GISetupPrerequisites {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)]$State)

    $step = 'Prerequisites'
    $production = (Get-GISetupObjectValue $State 'mode') -eq 'Production'
    $checks = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([string]$Name, [bool]$Ok, [string]$Detail, [bool]$Blocking)
        $checks.Add(@{ name = $Name; ok = $Ok; detail = $Detail; blocking = $Blocking })
        $flag = if ($Ok) { 'OK' } elseif ($Blocking) { 'FAIL' } else { 'WARN' }
        Write-GISetupProgress -Config $Config -Step $step -Line "[$flag] ${Name}: $Detail"
    }

    $win = [bool]$IsWindows
    & $add 'Operating system' $win $(if ($win) { 'Windows' } else { 'Not Windows (Lab only; Production needs Windows)' }) $production

    $psv = $PSVersionTable.PSVersion
    & $add 'PowerShell version' ($psv -ge [version]'7.2') "PowerShell $psv (need 7.2 or newer)" $true

    $admin = [bool](Test-GIIsAdministrator)
    & $add 'Administrator' $admin $(if ($admin) { 'Running elevated' } else { 'Not elevated' + $(if ($production) { ' (required for Production)' } else { ' (informational in Lab)' }) }) $production

    try {
        # Any HTTP answer below 500 means the network path works (the gallery rejects HEAD with 405)
        $r = Invoke-WebRequest -Method Get -Uri 'https://www.powershellgallery.com/api/v2/' -TimeoutSec 15 -UseBasicParsing -SkipHttpErrorCheck -ErrorAction Stop
        $code = [int]$r.StatusCode
        if ($code -ge 500) { throw "the gallery answered HTTP $code" }
        & $add 'PSGallery reachable' $true "powershellgallery.com responded (HTTP $code)" $true
    }
    catch {
        & $add 'PSGallery reachable' $false "Cannot reach powershellgallery.com: $($_.Exception.Message)" $true
    }

    $root = [string](Get-GISetupObjectValue $Config 'Root' (Get-Location).Path)
    try {
        $freeGB = [double](Get-GIFreeDiskGB -Path $root)
        & $add 'Free disk space' ($freeGB -ge 2) "$freeGB GB free for $root (need 2 GB)" $true
    }
    catch {
        & $add 'Free disk space' $false "Could not determine free space for ${root}: $($_.Exception.Message)" $true
    }

    if ($win) {
        $ep = [string](Get-ExecutionPolicy)
        $bad = $ep -in @('Restricted', 'AllSigned')
        $detail = "Execution policy $ep"
        if ($bad) { $detail += '. Run: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned' }
        & $add 'Execution policy' (-not $bad) $detail $bad

        $blocked = @()
        if (Test-Path -LiteralPath $root) {
            $blocked = @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { Get-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue })
        }
        if ($blocked.Count -gt 0) {
            & $add 'Downloaded-file block' $false "$($blocked.Count) script(s) marked as downloaded. Run: Get-ChildItem '$root' -Recurse | Unblock-File" $true
        }
        else {
            & $add 'Downloaded-file block' $true 'No blocked scripts' $true
        }
    }

    $failed = @($checks | Where-Object { -not $_.ok -and $_.blocking })
    if ($failed.Count -gt 0) {
        throw "$($failed.Count) prerequisite(s) failed: " + (($failed | ForEach-Object { "$($_.name) - $($_.detail)" }) -join '; ')
    }
    return @{ Message = "$($checks.Count) checks passed"; Data = @{ checks = @($checks) } }
}

function Invoke-GISetupPowerCLI {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)]$State)

    $options = Get-GISetupObjectValue $State 'options'
    $action = [string](Get-GISetupObjectValue $options 'invalidCertAction' 'Warn')
    if ([string]::IsNullOrWhiteSpace($action)) { $action = 'Warn' }
    if ($action -notin @('Warn', 'Ignore', 'Fail')) {
        throw "Invalid certificate action '$action'. Use Warn, Ignore or Fail."
    }

    try { Import-Module -Name VMware.VimAutomation.Core -ErrorAction Stop }
    catch { throw "VMware.PowerCLI is not installed or failed to load (run the Modules step first): $($_.Exception.Message)" }

    Write-GISetupProgress -Config $Config -Step 'PowerCLI' -Line "Configuring PowerCLI (CEIP off, invalid certificates: $action)..."
    Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -InvalidCertificateAction $action -Confirm:$false | Out-Null
    return @{ Message = "PowerCLI configured (invalid certificates: $action)"; Data = @{ invalidCertAction = $action } }
}
