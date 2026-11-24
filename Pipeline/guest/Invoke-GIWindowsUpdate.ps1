<#
.SYNOPSIS
  One Windows Update pass inside the golden image. Runs as SYSTEM from a scheduled task
  (the Windows Update Agent refuses Download/Install from non-interactive remote sessions).
  Writes a JSON result the pipeline polls for. Windows PowerShell 5.1 compatible.
#>
param(
    [Parameter(Mandatory)] [string] $ResultFile,
    [string] $Criteria = "IsInstalled=0 and IsHidden=0 and Type='Software'"
)
$result = [ordered]@{ startedAt = (Get-Date).ToString('o'); found = 0; installed = 0; failed = 0
                      rebootRequired = $false; resultCode = $null; titles = @(); error = $null; finishedAt = $null }
try {
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $search   = $searcher.Search($Criteria)
    $result.found = $search.Updates.Count

    if ($search.Updates.Count -gt 0) {
        $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $search.Updates) {
            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            [void]$toInstall.Add($u)
            $result.titles += $u.Title
        }
        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $toInstall
        [void]$downloader.Download()

        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $toInstall
        $inst = $installer.Install()
        $result.resultCode = $inst.ResultCode          # 2 = Succeeded, 3 = SucceededWithErrors, 4 = Failed
        $result.rebootRequired = [bool]$inst.RebootRequired
        for ($i = 0; $i -lt $toInstall.Count; $i++) {
            if ($inst.GetUpdateResult($i).ResultCode -eq 2) { $result.installed++ } else { $result.failed++ }
        }
    }
    # Pending reboot from earlier installs also counts
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $result.rebootRequired = $true
    }
} catch {
    $result.error = $_.Exception.Message
}
$result.finishedAt = (Get-Date).ToString('o')
$dir = Split-Path $ResultFile -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$result | ConvertTo-Json -Depth 4 | Set-Content -Path "$ResultFile.tmp" -Encoding UTF8
Move-Item "$ResultFile.tmp" $ResultFile -Force
