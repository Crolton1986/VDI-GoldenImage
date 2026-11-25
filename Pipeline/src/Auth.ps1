# Dashboard sign-in: Basic header parsing, the Active Directory check and the audit entry for a failed sign-in.
#
# Why this exists: Pode's built-in Windows AD authentication rejects a bad password before any dashboard code runs,
# so a failed sign-in could not be audited. The dashboard now uses a custom Pode scheme (see Web/AuthSetup.ps1) that
# parses the Basic header with ConvertFrom-GIBasicAuthHeader and a validator that calls Invoke-GIDashboardSignIn.
# The password lives only in the variables handed from the scheme to the validator to the AD call. It is never put in
# an audit entry, a log line, an exception message or a return value.

function ConvertFrom-GIBasicAuthHeader {
    <#
    .SYNOPSIS
      Parses an 'Authorization: Basic ...' header. Returns @{ Ok; Username; Password } or @{ Ok = $false; Code; Message }.
      No header is a 401 (the browser then asks for credentials); anything malformed is a 400. Pure.
    .DESCRIPTION
      Same decoding as Pode's own Basic scheme (ISO-8859-1), so existing passwords keep working. The username is
      everything before the first colon, the password everything after it.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Header)
    if ([string]::IsNullOrWhiteSpace($Header)) { return @{ Ok = $false; Code = 401; Message = 'No Authorization header found' } }
    $atoms = $Header.Trim() -isplit '\s+'
    if ($atoms.Length -lt 2) { return @{ Ok = $false; Code = 400; Message = 'Invalid Authorization header' } }
    if ($atoms[0] -ine 'Basic') { return @{ Ok = $false; Code = 400; Message = 'Header is not for Basic Authorization' } }
    try { $decoded = [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetString([System.Convert]::FromBase64String($atoms[1])) }
    catch { return @{ Ok = $false; Code = 400; Message = 'Invalid Base64 string found in Authorization header' } }
    $i = $decoded.IndexOf(':')
    if ($i -lt 1) { return @{ Ok = $false; Code = 400; Message = 'Invalid credentials in Authorization header' } }
    return @{ Ok = $true; Username = $decoded.Substring(0, $i); Password = $decoded.Substring($i + 1) }
}

function Get-GIBasicAuthParser {
    <# The scriptblock for the custom Pode scheme: returns @(user, password) for the validator, or a hashtable that fails the request. #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param()
    return {
        param($options)
        $r = ConvertFrom-GIBasicAuthHeader -Header ([string](Get-PodeHeader -Name 'Authorization'))
        if (-not $r.Ok) { return @{ Message = $r.Message; Code = $r.Code } }
        return @($r.Username, $r.Password)
    }
}

function Get-GIAuditUserName {
    <# A typed user name made safe for the audit log: control characters removed, at most 128 characters. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Name)
    $n = ([string]$Name) -replace '[\x00-\x1f\x7f]', ''
    $n = $n.Trim()
    if ($n.Length -gt 128) { $n = $n.Substring(0, 128) }
    if (-not $n) { return '(empty)' }
    return $n
}

function Write-GISignInFailed {
    <#
    .SYNOPSIS
      Records auth.signin.failed with the attempted user name, the reason and where the request came from. Never takes a
      password. At most one entry per user and source per minute, so a script hammering the dashboard can't flood the log.
      Returns $true when written.
    .PARAMETER Reason
      badCredentials (wrong user or password, locked or disabled account), notAuthorised (right password, no dashboard
      group) or directoryError (Active Directory could not be asked).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][AllowEmptyString()][string]$User,
        [Parameter(Mandatory)][ValidateSet('badCredentials', 'notAuthorised', 'directoryError')][string]$Reason,
        [string]$Source = '',
        [int]$ThrottleSeconds = 60
    )
    $name = Get-GIAuditUserName -Name $User
    $src = (([string]$Source) -replace '[^0-9A-Za-z:.%\-]', '')
    if ($src.Length -gt 64) { $src = $src.Substring(0, 64) }
    $recent = @(Get-GIAudit -Config $Config -Last 50 | Where-Object {
            $_.action -eq 'auth.signin.failed' -and $_.user -ceq $name -and $_.detail -and ([string]$_.detail.source) -ceq $src -and (((Get-Date) - [datetime]$_.at).TotalSeconds -lt $ThrottleSeconds)
        } | Select-Object -First 1)
    if ($recent.Count) { return $false }
    Write-GIAudit -Config $Config -User $name -Action 'auth.signin.failed' -Target '' -Detail @{ reason = $Reason; source = $src } -Result 'Failed'
    return $true
}

function Get-GIAdDomainName {
    <# The domain to sign in against: Dashboard.AdDomain when set, else the machine's domain (same lookup Pode uses on Windows). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([hashtable]$Config = @{})
    $d = [string](Get-GIConfigValue $Config 'Dashboard.AdDomain' '')
    if (-not $d.Trim()) { $d = [string]$env:USERDNSDOMAIN }
    if (-not $d.Trim() -and (Test-GIIsWindows)) { try { $d = [string](Get-CimInstance -ClassName Win32_ComputerSystem -Verbose:$false).Domain } catch { $d = '' } }
    return $d.Trim()
}

function Invoke-GIAdBind {
    <#
    .SYNOPSIS
      Windows only, and the only place the directory is touched. Checks the credentials against the domain and returns the
      account (Username, Name, Email, DistinguishedName, Groups = nested group names), or $null when they are wrong (wrong
      password, unknown, locked or disabled account). Throws when the directory can't be reached. Tests mock this function.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password', Justification = 'Pode hands the Basic credentials over as strings and PrincipalContext.ValidateCredentials takes a string. The value is never stored, logged or returned.')]
    param([Parameter(Mandatory)][string]$Domain, [Parameter(Mandatory)][string]$SamAccountName, [Parameter(Mandatory)][string]$Password)
    if (-not (Test-GIIsWindows)) { throw 'Active Directory sign-in needs a Windows host.' }
    Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction Stop
    $ctx = [System.DirectoryServices.AccountManagement.PrincipalContext]::new([System.DirectoryServices.AccountManagement.ContextType]::Domain, $Domain)
    try {
        if (-not $ctx.ValidateCredentials($SamAccountName, $Password)) { return $null }
        $u = [System.DirectoryServices.AccountManagement.UserPrincipal]::FindByIdentity($ctx, [System.DirectoryServices.AccountManagement.IdentityType]::SamAccountName, $SamAccountName)
        if (-not $u) { return $null }
        $groups = @($u.GetAuthorizationGroups() | ForEach-Object { [string]$_.SamAccountName } | Where-Object { $_ })
        return @{ Username = [string]$u.SamAccountName; Name = [string]$u.DisplayName; Email = [string]$u.EmailAddress; DistinguishedName = [string]$u.DistinguishedName; Groups = $groups }
    } finally { $ctx.Dispose() }
}

function Test-GIAdSignIn {
    <#
    .SYNOPSIS
      Checks a user name and password against Active Directory and the dashboard groups.
      Returns @{ Ok; User } (User shaped like Pode's AD user: Username, Name, Domain, Groups ...) or @{ Ok = $false; Reason; Message }.
    .PARAMETER Groups
      Short group names (without the domain). The user needs at least one.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'Basic authentication: the browser sends a user name and a password, not a credential object.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password', Justification = 'Pode hands the Basic credentials over as strings and PrincipalContext.ValidateCredentials takes a string. The value is never stored, logged or returned.')]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Username,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Password,
        [Parameter(Mandatory)][string]$Domain,
        [string[]]$Groups = @()
    )
    $sam = (($Username -split '@')[0] -split '\\')[-1].Trim()   # DOMAIN\user, user@domain and plain user all work, as with Pode
    if (-not $sam -or -not $Password) { return @{ Ok = $false; Reason = 'badCredentials'; Message = 'Invalid credentials supplied' } }
    try { $acct = Invoke-GIAdBind -Domain $Domain -SamAccountName $sam -Password $Password }
    catch { return @{ Ok = $false; Reason = 'directoryError'; Message = 'Active Directory could not be reached. Try again, or ask the administrator.'; Code = 503 } }
    if (-not $acct) { return @{ Ok = $false; Reason = 'badCredentials'; Message = 'Invalid credentials supplied' } }
    $mine = @($acct.Groups)
    $allowed = @($Groups | Where-Object { $_ } | Where-Object { $g = $_; @($mine | Where-Object { $_ -ieq $g }).Count })
    if ($Groups.Count -and -not $allowed.Count) { return @{ Ok = $false; Reason = 'notAuthorised'; Message = 'You are not authorised to access this website' } }
    return @{ Ok = $true; User = @{
            UserType = 'Domain'; AuthenticationType = 'LDAP'; Username = [string]$acct.Username; Name = [string]$acct.Name; Email = [string]$acct.Email
            DistinguishedName = [string]$acct.DistinguishedName; Fqdn = $Domain; Domain = ($Domain -split '\.')[0]; Groups = $mine } }
}

function Invoke-GIDashboardSignIn {
    <#
    .SYNOPSIS
      The validator of the dashboard's Pode auth method. Returns what Pode expects: @{ User } on success, @{ Message; Code }
      on failure. A failure writes auth.signin.failed (attempted user name only). -GetConfig is called only then, so
      successful requests don't read the config. -Domain is worked out once when the dashboard starts (Get-GIAdDomainName).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'Basic authentication: the browser sends a user name and a password, not a credential object.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password', Justification = 'Pode hands the Basic credentials over as strings and PrincipalContext.ValidateCredentials takes a string. The value is never stored, logged or returned.')]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Username,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Password,
        [Parameter(Mandatory)][string]$Domain,
        [string[]]$Groups = @(),
        [string]$Source = '',
        [Parameter(Mandatory)][scriptblock]$GetConfig
    )
    $r = Test-GIAdSignIn -Username $Username -Password $Password -Domain $Domain -Groups $Groups
    if ($r.Ok) { return @{ User = $r.User } }
    $null = Write-GISignInFailed -Config (& $GetConfig) -User $Username -Reason $r.Reason -Source $Source
    $code = if ($r.ContainsKey('Code')) { [int]$r.Code } else { 401 }
    return @{ Message = [string]$r.Message; Code = $code }
}
