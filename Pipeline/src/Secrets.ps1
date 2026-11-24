#----------------[ Credential storage (SecretManagement) ]----------------
# The vault belongs to the account the process runs as. The dashboard and pipeline tasks must run
# under the same service account (Register-GIPipelineTasks.ps1 does this) so they share secrets.

function Assert-GISecretModule {
    if (-not (Get-Command -Name Set-Secret -ErrorAction SilentlyContinue)) {
        Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction SilentlyContinue
    }
    if (-not (Get-Command -Name Set-Secret -ErrorAction SilentlyContinue)) {
        throw 'Microsoft.PowerShell.SecretManagement is not installed. Install-Module Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore'
    }
}

function Set-GISecretCredential {
    <#
    .SYNOPSIS
      Stores a credential under a secret name. The password never leaves this function.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9._-]{1,64}$')] [string] $Name,
        [Parameter(Mandatory)] [pscredential] $Credential
    )
    Assert-GISecretModule
    if ($PSCmdlet.ShouldProcess($Name, 'Store credential')) {
        Set-Secret -Name $Name -Secret $Credential -ErrorAction Stop
    }
}

function Get-GISecretStatus {
    <#
    .SYNOPSIS
      Whether a secret exists, and its user name. Never returns the password. Never throws.
    #>
    [CmdletBinding()]
    param([string] $Name)
    $status = @{ Name = $Name; IsSet = $false; UserName = $null; Error = $null }
    if (-not $Name) { return $status }
    try {
        Assert-GISecretModule
        if (-not (Get-SecretInfo -Name $Name -ErrorAction SilentlyContinue)) { return $status }
        $s = Get-Secret -Name $Name -ErrorAction Stop
        $status.IsSet = $true
        if ($s -is [pscredential]) { $status.UserName = $s.UserName }
    } catch {
        $status.Error = $_.Exception.Message
    }
    return $status
}

function Set-GISecretFromForm {
    <#
    .SYNOPSIS
      Dashboard helper: username + plain password from a form. A blank password keeps the stored
      password (username change only). Returns nothing; throws on invalid input.
    #>
    # The password arrives as plain text from the HTTPS form post; it's converted immediately and never stored or logged
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'Form input')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Form input')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Form input')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $UserName,
        [AllowEmptyString()] [string] $Password
    )
    $UserName = $UserName.Trim()
    if (-not $UserName) { throw 'User name is required.' }
    if ($UserName.Length -gt 256) { throw 'User name is too long.' }
    if ($Password) {
        $sec = ConvertTo-SecureString -String $Password -AsPlainText -Force
    } else {
        Assert-GISecretModule
        $existing = Get-Secret -Name $Name -ErrorAction SilentlyContinue
        if (-not ($existing -is [pscredential])) { throw 'No stored password yet; enter one.' }
        $sec = $existing.Password
    }
    $cred = [pscredential]::new($UserName, $sec)
    if ($PSCmdlet.ShouldProcess($Name, 'Store credential')) { Set-GISecretCredential -Name $Name -Credential $cred }
}
