# Registers the dashboard's Pode authentication method 'AD'. Used by Start-GIDashboard.ps1 inside Start-PodeServer.
#
# Default: a custom Pode scheme (Basic header parsed by ConvertFrom-GIBasicAuthHeader) with a validator that checks
# Active Directory itself (Invoke-GIDashboardSignIn, src/Auth.ps1), so a wrong password can be written to the audit log as
# auth.signin.failed. Dashboard.LegacyAdAuth = $true in pipeline.config.psd1 switches back to Pode's own Windows AD
# authentication (no failed sign-in entries).

function Add-GIDashboardAuth {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'The validator scriptblock has the (username, password, options) signature Pode calls it with; Add-GIDashboardAuth itself takes neither.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Pode passes the Basic credentials to the validator as strings. The value is never stored, logged or returned.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string[]]$Groups,   # short names, as Pode and the dashboard use them
        [string]$Realm = 'VDI Golden Image Pipeline'
    )
    if ([bool](Get-GIConfigValue $Context.Config 'Dashboard.LegacyAdAuth' $false)) {
        New-PodeAuthScheme -Basic -Realm $Realm | Add-PodeAuthWindowsAd -Name 'AD' -Groups $Groups -Sessionless
        return 'legacy'
    }
    $domain = Get-GIAdDomainName -Config $Context.Config
    if (-not $domain) { throw 'No Active Directory domain found for sign-in. Join this server to the domain, or set Dashboard.AdDomain in pipeline.config.psd1.' }
    $parser = Get-GIBasicAuthParser
    $scheme = if (Get-Command -Name New-PodeAuthCustomScheme -ErrorAction SilentlyContinue) { New-PodeAuthCustomScheme -Name 'Basic' -Realm $Realm -ScriptBlock $parser }
    else { New-PodeAuthScheme -Custom -Name 'Basic' -Realm $Realm -ScriptBlock $parser }
    $scheme | Add-PodeAuth -Name 'AD' -Sessionless -ArgumentList @{ Domain = $domain; Groups = @($Groups) } -ScriptBlock {
        param($username, $password, $options)
        $c = Get-PodeState -Name 'GIContext'
        $src = ''
        try { $src = [string]$WebEvent.Request.RemoteEndPoint.Address } catch { $src = '' }
        $getCfg = { Get-GIDashboardConfig $c }.GetNewClosure()
        Invoke-GIDashboardSignIn -Username ([string]$username) -Password ([string]$password) -Domain ([string]$options.Domain) -Groups @($options.Groups) -Source $src -GetConfig $getCfg
    }
    return 'custom'
}
