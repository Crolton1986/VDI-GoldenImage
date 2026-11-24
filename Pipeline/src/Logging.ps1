function Write-GILog {
    <#
    .SYNOPSIS
        Appends a line to the run log and writes it to the host. Never throws.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console output with colour is intended.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Warn', 'Error', 'Success')][string]$Level = 'Info'
    )

    try {
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $Message
        $color = switch ($Level) { 'Warn' { 'Yellow' } 'Error' { 'Red' } 'Success' { 'Green' } default { 'Gray' } }
        Write-Host $line -ForegroundColor $color
        $dir = $Config.Paths.Logs
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        Add-Content -LiteralPath (Join-Path $dir "$RunId.log") -Value $line -Encoding UTF8
    } catch {
        Write-Warning "Write-GILog failed: $($_.Exception.Message)"
    }
}
