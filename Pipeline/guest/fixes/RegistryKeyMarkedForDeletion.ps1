<#
Cause: "Illegal operation attempted on a registry key that has been marked for deletion" means the profile/session
hive the process was started under was unloaded (typical: the process came from a VMware Tools guest operation that
ended, or a user session logged off). Registry and COM calls in that process fail from then on. A fresh process gets a
fresh token and hive; a reboot clears any stale hive state.
Fix attempt 1: clean up leftover installers, wait for the MSI service, the step retries in a new process.
Fix attempt 2: same cleanup, then the host reboots (RebootFromAttempt), AfterReboot logs the boot time.
Windows PowerShell 5.1 compatible.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Read by Read-GIFixCatalog')]
param()
$GIFix = @{
    Id                = 'RegistryKeyMarkedForDeletion'
    Description       = 'Registry key marked for deletion (stale hive): stop leftover installers, wait for MSI idle, retry; reboot on the second time'
    Priority          = 100
    Actions           = @('*')
    MaxAttempts       = 2
    RebootFromAttempt = 2
    Match             = @{
        ExitCodes = @(1)
        Patterns  = @('registry\s+key\s+that\s+has\s+been\s+marked\s+for\s+deletion')
        Sources   = @('Errors', 'Output', 'Log')
    }
}

function Invoke-GIFix {
    param([Parameter(Mandatory)] $Context)
    try {
        if ([string]$Context.Phase -eq 'AfterReboot') {
            $boot = 'unknown'
            try { $boot = ([string](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime) } catch { $boot = 'unknown' }
            Write-GIFixLog -Message "After reboot; last boot time $boot"
            return @{ Ok = $true; Message = "After reboot, last boot time $boot" }
        }

        Write-GIFixLog -Message "Registry hive error in step $($Context.StepId): stopping leftover installers and waiting for the Windows Installer"
        $stopped = @()
        $stopped += @(Stop-GIAllowedProcess -InstallDirOnly)
        $idle = [bool](Wait-GIMsiIdle -TimeoutSec 60)
        if (-not $idle) {
            Write-GIFixLog -Message 'Windows Installer still busy after 60 s; stopping msiexec'
            $stopped += @(Stop-GIAllowedProcess -Name 'msiexec')
            $idle = [bool](Wait-GIMsiIdle -TimeoutSec 240)
        }
        $msg = "Stopped $(@($stopped).Count) process(es); Windows Installer is $(if ($idle) { 'idle' } else { 'still busy' })"
        Write-GIFixLog -Message $msg
        return @{ Ok = $idle; Message = $msg }
    } catch {
        return @{ Ok = $false; Message = "Fix could not complete: $($_.Exception.Message)" }
    }
}
