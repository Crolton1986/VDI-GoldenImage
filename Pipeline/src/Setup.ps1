#----------------[ First-run setup: state machine, runner, vault, dashboard access, tasks ]----------------
# State lives in config/setup.json. One step runs at a time. Long steps run in a separate pwsh process
# (Invoke-GISetupStep.ps1) so module installs don't collide with modules loaded inside Pode.

$script:GISetupSteps = @('Mode', 'Prerequisites', 'Modules', 'PowerCLI', 'Vault', 'DashboardAccess', 'Tasks', 'Finish')
$script:GISetupBackgroundSteps = @('Prerequisites', 'Modules', 'PowerCLI', 'Vault')
$script:GISetupLabSkipped = @('DashboardAccess', 'Tasks')

#----- State -----

function Get-GISetupPath {
    param([Parameter(Mandatory)] [hashtable] $Config)
    Join-Path (Join-Path $Config.Root 'config') 'setup.json'
}

function New-GISetupState {
    param([switch] $ModeLocked)
    $steps = [ordered]@{}
    foreach ($s in $script:GISetupSteps) {
        $steps[$s] = [ordered]@{ status = 'pending'; message = ''; startedAt = $null; endedAt = $null; pid = $null; detail = @(); data = @{} }
    }
    [ordered]@{
        schemaVersion = 1; mode = $null; modeLocked = [bool]$ModeLocked
        startedAt = (Get-Date).ToString('o'); completedAt = $null; updatedAt = (Get-Date).ToString('o')
        options = @{ invalidCertAction = 'Warn' }; steps = $steps
    } | ConvertTo-Json -Depth 10 | ConvertFrom-Json
}

function Get-GISetupState {
    <#
    .SYNOPSIS
      Loads setup.json (or a fresh state if absent). A running step whose process is gone becomes failed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config, [switch] $ModeLocked)
    $path = Get-GISetupPath $Config
    if (-not (Test-Path -LiteralPath $path)) { return New-GISetupState -ModeLocked:$ModeLocked }
    $state = $null
    for ($i = 1; -not $state; $i++) {
        try { $state = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { if ($i -ge 5) { throw "Can't read $($path): $($_.Exception.Message)" }; Start-Sleep -Milliseconds (100 * $i) }
    }
    foreach ($s in $script:GISetupSteps) {
        $st = $state.steps.$s
        if ($st.status -eq 'running' -and $st.pid -and -not (Test-GIProcessAlive -ProcessId ([int]$st.pid))) {
            $st.status = 'failed'
            $st.message = 'Interrupted: the setup process stopped before the step finished. Retry it.'
            $st.endedAt = (Get-Date).ToString('o')
        }
    }
    if ($ModeLocked -and -not $state.modeLocked -and -not $state.mode) { $state.modeLocked = $true }
    return $state
}

function Initialize-GISetupState {
    <#
    .SYNOPSIS
      Called when the setup server starts: writes setup.json if missing and records the Lab lock
      (-LocalAdmin) on disk, so every later read sees it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config, [switch] $ModeLocked)
    $state = Get-GISetupState -Config $Config -ModeLocked:$ModeLocked
    if ($ModeLocked -and -not $state.mode) { $state.modeLocked = $true }
    Save-GISetupState -Config $Config -State $state
    return $state
}

function Save-GISetupState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config, [Parameter(Mandatory)] $State)
    $State.updatedAt = (Get-Date).ToString('o')
    $dir = Split-Path (Get-GISetupPath $Config) -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Write-GIJsonAtomic -Path (Get-GISetupPath $Config) -InputObject $State
}

function Test-GISetupComplete {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config)
    $path = Get-GISetupPath $Config
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    try { return [bool]((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).completedAt) } catch { return $false }
}

function Get-GISetupNextStep {
    # First step that isn't done or skipped; $null when all are
    param([Parameter(Mandatory)] $State)
    foreach ($s in $script:GISetupSteps) {
        if ($State.steps.$s.status -notin 'done', 'skipped') { return $s }
    }
    return $null
}

function Get-GISetupRunningStep {
    param([Parameter(Mandatory)] $State)
    foreach ($s in $script:GISetupSteps) { if ($State.steps.$s.status -eq 'running') { return $s } }
    return $null
}

function Set-GISetupStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [ValidateScript({ $script:GISetupSteps -contains $_ })] [string] $Step,
        [Parameter(Mandatory)] [ValidateSet('pending', 'running', 'done', 'failed', 'skipped')] [string] $Status,
        [AllowEmptyString()] [string] $Message = '',
        [hashtable] $Data,
        [int] $ProcessId = 0
    )
    $state = Get-GISetupState -Config $Config
    $st = $state.steps.$Step
    $now = (Get-Date).ToString('o')
    $st.status = $Status
    $st.message = $Message
    if ($Status -eq 'running') { $st.startedAt = $now; $st.endedAt = $null; $st.detail = @(); $st.pid = if ($ProcessId) { $ProcessId } else { $null } }
    else { $st.endedAt = $now; if ($Status -ne 'pending') { $st.pid = $null } }
    if ($Data) {
        foreach ($k in $Data.Keys) { Add-Member -InputObject $st.data -NotePropertyName $k -NotePropertyValue $Data[$k] -Force }
    }
    Save-GISetupState -Config $Config -State $state
}

function Set-GISetupStepData {
    # Merges live data into a running step (e.g. module rows) without changing its status
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config, [Parameter(Mandatory)] [string] $Step, [Parameter(Mandatory)] [hashtable] $Data)
    $state = Get-GISetupState -Config $Config
    foreach ($k in $Data.Keys) { Add-Member -InputObject $state.steps.$Step.data -NotePropertyName $k -NotePropertyValue $Data[$k] -Force }
    Save-GISetupState -Config $Config -State $state
}

function Write-GISetupProgress {
    # Appends a progress line to the step (keeps the last 50) and echoes it to the console
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config, [Parameter(Mandatory)] [string] $Step, [Parameter(Mandatory)] [AllowEmptyString()] [string] $Line)
    Write-Information "[$Step] $Line" -InformationAction Continue
    try {
        $state = Get-GISetupState -Config $Config
        $lines = @($state.steps.$Step.detail) + @("$((Get-Date).ToString('HH:mm:ss')) $Line")
        $state.steps.$Step.detail = @($lines | Select-Object -Last 50)
        Save-GISetupState -Config $Config -State $state
    } catch {
        Write-Warning "Could not record setup progress: $($_.Exception.Message)"
    }
}

function Assert-GISetupCanStart {
    # Throws unless $Step is the next step (or a failed step being retried) and nothing is running
    param([Parameter(Mandatory)] $State, [Parameter(Mandatory)] [string] $Step)
    if ($State.completedAt) { throw 'Setup is already complete. Run Start-GIPipeline.ps1 -ResetSetup to run it again.' }
    $running = Get-GISetupRunningStep -State $State
    if ($running) { throw "Step '$running' is still running." }
    $next = Get-GISetupNextStep -State $State
    if ($next -ne $Step) { throw "Step '$Step' can't run now; the next step is '$next'." }
}

#----- Running steps -----

function Invoke-GISetupStepCore {
    <#
    .SYNOPSIS
      Runs one step's function and records the result. Used by the background runner and in-request steps.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config, [Parameter(Mandatory)] [string] $Step, [hashtable] $Arguments = @{})
    $state = Get-GISetupState -Config $Config
    try {
        $fn = "Invoke-GISetup$Step"
        $out = & $fn -Config $Config -State $state @Arguments
        $msg  = if ($out -is [hashtable] -and $out['Message']) { [string]$out['Message'] } else { 'Done.' }
        $data = if ($out -is [hashtable] -and $out['Data']) { $out['Data'] } else { @{} }
        $status = if ($out -is [hashtable] -and $out['Skipped']) { 'skipped' } else { 'done' }
        Set-GISetupStep -Config $Config -Step $Step -Status $status -Message $msg -Data $data
        Write-GIAudit -Config $Config -User (Get-GICurrentUserName) -Action 'setup.step' -Target $Step -Detail @{ status = $status; message = $msg }
        return $true
    } catch {
        $err = $_.Exception.Message
        Write-GISetupProgress -Config $Config -Step $Step -Line "Error: $err"
        Set-GISetupStep -Config $Config -Step $Step -Status failed -Message $err
        Write-GIAudit -Config $Config -User (Get-GICurrentUserName) -Action 'setup.step' -Target $Step -Detail @{ status = 'failed'; message = $err }
        return $false
    }
}

function Get-GICurrentUserName {
    if ($IsWindows) { return "$env:USERDOMAIN\$env:USERNAME" }
    return [Environment]::UserName
}

function Start-GISetupStep {
    <#
    .SYNOPSIS
      Starts a background step (separate pwsh process running Invoke-GISetupStep.ps1). Returns the process id.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [hashtable] $Config, [Parameter(Mandatory)] [string] $Step, [string] $ConfigPath)
    if ($script:GISetupBackgroundSteps -notcontains $Step) { throw "Step '$Step' doesn't run in the background." }
    $state = Get-GISetupState -Config $Config
    Assert-GISetupCanStart -State $state -Step $Step
    $runner = Join-Path $Config.Root 'Invoke-GISetupStep.ps1'
    if (-not (Test-Path -LiteralPath $runner)) { $runner = Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-GISetupStep.ps1' }
    $pwsh = (Get-Process -Id $PID).Path
    # Start-Process joins arguments with spaces, so paths must be quoted
    # (e.g. 'C:\Users\me\OneDrive - Contoso\...' would split at the first space)
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-GIProcessArgument $runner), '-Step', $Step)
    if ($ConfigPath) { $argList += @('-ConfigPath', (ConvertTo-GIProcessArgument $ConfigPath)) }
    if (-not $PSCmdlet.ShouldProcess($Step, 'Start setup step')) { return }

    # Mark running first, so a double click can't start it twice; the runner fills in its pid
    Set-GISetupStep -Config $Config -Step $Step -Status running -Message 'Starting...'
    $log = Join-Path (Join-Path $Config.Root 'config') "setup-$Step.log"
    $sp = @{ FilePath = $pwsh; ArgumentList = $argList; PassThru = $true; RedirectStandardOutput = $log; RedirectStandardError = "$log.err" }
    if ($IsWindows) { $sp.WindowStyle = 'Hidden' }
    try {
        $proc = Start-Process @sp
    } catch {
        Set-GISetupStep -Config $Config -Step $Step -Status failed -Message "Could not start the setup process: $($_.Exception.Message)"
        throw
    }
    $s2 = Get-GISetupState -Config $Config
    if ($s2.steps.$Step.status -eq 'running' -and -not $s2.steps.$Step.pid) {
        $s2.steps.$Step.pid = $proc.Id
        Save-GISetupState -Config $Config -State $s2
    }

    # A runner that dies right away (bad arguments, can't load the module) never reports back; catch it here
    if ($proc.WaitForExit(3000)) {
        $s3 = Get-GISetupState -Config $Config
        if ($s3.steps.$Step.status -eq 'running') {
            $err = ''
            foreach ($f in "$log.err", $log) {
                if (Test-Path -LiteralPath $f) { $err = ((Get-Content -LiteralPath $f -Tail 5 -ErrorAction SilentlyContinue) -join ' ').Trim(); if ($err) { break } }
            }
            if (-not $err) { $err = "exit code $($proc.ExitCode)" }
            Set-GISetupStep -Config $Config -Step $Step -Status failed -Message "The setup process stopped right away: $err (log: $log.err)"
        }
    }
    return $proc.Id
}

function ConvertTo-GIProcessArgument {
    # Quotes one command-line argument for Start-Process / CreateProcess when it has spaces or quotes
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Value)
    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    # CreateProcess rules: double the backslashes that precede a quote, escape the quote
    $escaped = [regex]::Replace($Value, '(\\*)"', { param($m) ($m.Groups[1].Value * 2) + '\"' })
    $escaped = [regex]::Replace($escaped, '(\\+)$', { param($m) $m.Groups[1].Value * 2 })
    return '"' + $escaped + '"'
}

function Set-GISetupMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [ValidateSet('Lab', 'Production')] [string] $Mode,
        [ValidateSet('Warn', 'Ignore', 'Fail')] [string] $InvalidCertAction = 'Warn',
        [string] $By = (Get-GICurrentUserName),
        [switch] $ModeLocked
    )
    $state = Get-GISetupState -Config $Config -ModeLocked:$ModeLocked
    Assert-GISetupCanStart -State $state -Step 'Mode'
    if (($state.modeLocked -or $ModeLocked) -and $Mode -ne 'Lab') { throw 'Started with -LocalAdmin, so setup runs in Lab mode.' }
    $state.mode = $Mode
    $state.options.invalidCertAction = $InvalidCertAction
    $state.steps.Mode.status = 'done'
    $state.steps.Mode.message = $Mode
    $state.steps.Mode.startedAt = (Get-Date).ToString('o')
    $state.steps.Mode.endedAt = $state.steps.Mode.startedAt
    if ($Mode -eq 'Lab') {
        foreach ($s in $script:GISetupLabSkipped) {
            $state.steps.$s.status = 'skipped'
            $state.steps.$s.message = 'Not used in Lab mode.'
        }
    }
    Save-GISetupState -Config $Config -State $state
    Write-GIAudit -Config $Config -User $By -Action 'setup.step' -Target 'Mode' -Detail @{ status = 'done'; mode = $Mode; invalidCertAction = $InvalidCertAction }
}

#----- Step: Vault -----

function Invoke-GISetupVault {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config, [Parameter(Mandatory)] $State)
    Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction Stop
    Import-Module Microsoft.PowerShell.SecretStore -ErrorAction Stop

    $default = Get-SecretVault -ErrorAction SilentlyContinue | Where-Object IsDefault | Select-Object -First 1
    if ($default) {
        Write-GISetupProgress -Config $Config -Step Vault -Line "Default vault '$($default.Name)' ($($default.ModuleName)) already registered."
        if ($default.ModuleName -eq 'Microsoft.PowerShell.SecretStore') {
            $cfg = Get-SecretStoreConfiguration -ErrorAction SilentlyContinue
            if ($cfg -and ([string]$cfg.Authentication -ne 'None' -or [string]$cfg.Interaction -ne 'None')) {
                throw "The SecretStore vault asks for a password (Authentication=$($cfg.Authentication), Interaction=$($cfg.Interaction)), so scheduled tasks couldn't read it. Run 'Set-SecretStoreConfiguration -Authentication None -Interaction None' as $(Get-GICurrentUserName), then retry."
            }
        }
        if (-not (Test-SecretVault -Name $default.Name -ErrorAction SilentlyContinue)) {
            throw "Vault '$($default.Name)' is registered but not usable (Test-SecretVault failed)."
        }
        return @{ Message = "Using existing vault '$($default.Name)'."; Data = @{ vault = $default.Name; created = $false } }
    }

    $name = 'VDIPipeline'
    Write-GISetupProgress -Config $Config -Step Vault -Line "Registering SecretStore vault '$name' for $(Get-GICurrentUserName)..."
    if (-not (Get-SecretVault -Name $name -ErrorAction SilentlyContinue)) {
        Register-SecretVault -Name $name -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault -ErrorAction Stop
    } else {
        Set-SecretVaultDefault -Name $name -ErrorAction Stop
    }
    # The store's own password is random and thrown away: with Authentication None it's never asked for again
    $bytes = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(24)
    $pw = [System.Net.NetworkCredential]::new('', [Convert]::ToBase64String($bytes)).SecurePassword
    Set-SecretStoreConfiguration -Scope CurrentUser -Authentication None -Interaction None -Password $pw -Confirm:$false -ErrorAction Stop
    Write-GISetupProgress -Config $Config -Step Vault -Line 'Vault set to open without a password for this Windows user.'
    if (-not (Test-SecretVault -Name $name -ErrorAction SilentlyContinue)) { throw "Vault '$name' was registered but Test-SecretVault failed." }
    @{ Message = "Created vault '$name' for $(Get-GICurrentUserName)."; Data = @{ vault = $name; created = $true } }
}

#----- Step: DashboardAccess (in request) -----

function Get-GIServerCertificate {
    <#
    .SYNOPSIS
      Server-auth certificates with a private key in LocalMachine\My, not expired. Empty off Windows.
    #>
    [CmdletBinding()]
    param()
    if (-not $IsWindows) { return @() }
    $serverAuth = '1.3.6.1.5.5.7.3.1'
    @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object {
            $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) -and $_.NotBefore -le (Get-Date) -and
            (-not $_.EnhancedKeyUsageList -or @($_.EnhancedKeyUsageList.ObjectId) -contains $serverAuth)
        } | Sort-Object NotAfter -Descending |
        ForEach-Object { [pscustomobject]@{ Thumbprint = $_.Thumbprint; Subject = $_.Subject; NotAfter = $_.NotAfter } })
}

function Test-GIAdGroup {
    # $true when DOMAIN\Name (or Name) resolves to a group in AD; throws when AD can't be queried
    param([Parameter(Mandatory)] [string] $Group)
    $name = ($Group -split '\\')[-1]
    if ($name -notmatch '^[\w .()-]{1,64}$') { return $false }
    $searcher = [adsisearcher]"(&(objectCategory=group)(sAMAccountName=$name))"
    return [bool]$searcher.FindOne()
}

function Invoke-GISetupDashboardAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [hashtable] $Options
    )
    if ($State.mode -ne 'Production') { return @{ Message = 'Not used in Lab mode.'; Skipped = $true } }
    $errors = [System.Collections.Generic.List[string]]::new()

    $port = 0
    if (-not [int]::TryParse([string]$Options['Port'], [ref]$port) -or $port -lt 1 -or $port -gt 65535) { $errors.Add('Port must be 1-65535.') }
    $groups = [ordered]@{}
    foreach ($g in 'ViewerGroup', 'ApproverGroup', 'AdminGroup') {
        $v = ([string]$Options[$g]).Trim()
        if (-not $v) { $errors.Add("$g is required."); continue }
        try {
            if (-not (Test-GIAdGroup -Group $v)) { $errors.Add("$g '$v' wasn't found in Active Directory.") }
        } catch {
            $errors.Add("Couldn't check $g in Active Directory: $($_.Exception.Message)")
        }
        $groups[$g] = $v
    }
    $thumb = ([string]$Options['CertThumbprint']).Trim()
    $selfSigned = $thumb -eq '__selfsigned__'
    if (-not $selfSigned) {
        if ($thumb -notmatch '^[0-9A-Fa-f]{40}$') { $errors.Add('Pick a certificate.') }
        elseif (-not (Get-GIServerCertificate | Where-Object Thumbprint -eq $thumb.ToUpper())) { $errors.Add('That certificate is not a valid server certificate in LocalMachine\My.') }
    }
    if ($errors.Count) { throw ($errors -join ' ') }

    if ($selfSigned) {
        $dns = @([System.Net.Dns]::GetHostName())
        try { $fqdn = [System.Net.Dns]::GetHostEntry($dns[0]).HostName; if ($fqdn -and $fqdn -ne $dns[0]) { $dns += $fqdn } } catch { Write-Verbose $_.Exception.Message }
        Write-GISetupProgress -Config $Config -Step DashboardAccess -Line "Creating self-signed certificate for $($dns -join ', ')..."
        $cert = New-SelfSignedCertificate -DnsName $dns -CertStoreLocation Cert:\LocalMachine\My -FriendlyName 'VDI Pipeline dashboard' `
            -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddYears(2) -ErrorAction Stop
        $thumb = $cert.Thumbprint
    }

    $ruleName = "VDI Pipeline dashboard ($port)"
    if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
        Write-GISetupProgress -Config $Config -Step DashboardAccess -Line "Opening inbound TCP $port in Windows Firewall..."
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $port -Action Allow -Profile Domain -ErrorAction Stop | Out-Null
    }

    $set = @(
        @{ Path = 'Dashboard.Port'; Value = $port }
        @{ Path = 'Dashboard.CertificateThumbprint'; Value = $thumb.ToUpper() }
        @{ Path = 'Dashboard.ViewerGroup'; Value = $groups.ViewerGroup }
        @{ Path = 'Dashboard.ApproverGroup'; Value = $groups.ApproverGroup }
        @{ Path = 'Dashboard.AdminGroup'; Value = $groups.AdminGroup }
    )
    Update-GISettingsOverlay -Config $Config -Set $set | Out-Null
    $how = if ($selfSigned) { 'new self-signed certificate' } else { 'existing certificate' }
    @{ Message = "Dashboard on https port $port with $how; groups saved."; Data = @{ port = $port; thumbprint = $thumb.ToUpper(); selfSigned = $selfSigned } }
}

#----- Step: Tasks (in request; the password never leaves memory) -----

function Invoke-GISetupTasks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] $State,
        [pscredential] $Credential,
        [switch] $Skip,
        [string] $ConfigPath
    )
    if ($State.mode -ne 'Production') { return @{ Message = 'Not used in Lab mode.'; Skipped = $true } }
    if ($Skip) { return @{ Message = 'Skipped: Task Scheduler left untouched. Register later with Register-GIPipelineTasks.ps1.'; Skipped = $true } }
    if (-not $Credential) { throw 'Enter your Windows password.' }
    $me = Get-GICurrentUserName
    if ($Credential.UserName -ne $me) { throw "Tasks run as the user who runs setup ($me)." }
    if (-not (Test-GIWindowsCredential -Credential $Credential)) { throw 'That password was not accepted by Windows.' }

    $defArgs = @{ Root = $Config.Root; Config = $Config }
    if ($ConfigPath) { $defArgs.ConfigPath = $ConfigPath }
    $defs = Get-GIPipelineTaskDefinition @defArgs
    $result = @(Register-GIPipelineTask -Definitions $defs -Credential $Credential)
    @{ Message = "Registered $($result.Count) scheduled tasks as $me."; Data = @{ tasks = @($result | ForEach-Object { $_.Name }) } }
}

#----- Step: Finish (in request) -----

function Complete-GISetup {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config, [string] $By = (Get-GICurrentUserName))
    $state = Get-GISetupState -Config $Config
    Assert-GISetupCanStart -State $state -Step 'Finish'
    $handoff = $null
    if ($state.mode -eq 'Production' -and $state.steps.Tasks.status -eq 'done') {
        $handoff = 'Starting the VDI-GI-Dashboard task; this setup page will stop in a few seconds.'
    }
    $state.steps.Finish.status = 'done'
    $state.steps.Finish.message = if ($handoff) { $handoff } else { 'Setup complete.' }
    $state.steps.Finish.endedAt = (Get-Date).ToString('o')
    $state.completedAt = $state.steps.Finish.endedAt
    Save-GISetupState -Config $Config -State $state
    Write-GIAudit -Config $Config -User $By -Action 'setup.step' -Target 'Finish' -Detail @{ status = 'done'; mode = $state.mode }
    return [pscustomobject]@{ Mode = $state.mode; StartDashboardTask = [bool]$handoff }
}

function Reset-GISetup {
    # Moves setup.json aside so the next launch runs setup again
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [hashtable] $Config)
    $path = Get-GISetupPath $Config
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $dest = $path -replace '\.json$', ".$((Get-Date).ToString('yyyyMMdd-HHmmss')).json"
    if ($PSCmdlet.ShouldProcess($path, "Move to $dest")) { Move-Item -LiteralPath $path -Destination $dest -Force }
    return $dest
}
