<#
Cause: MSI error 1618 (ERROR_INSTALL_ALREADY_RUNNING) means another installation holds the Windows Installer mutex
(Global\_MSIExecute). Typical holders: the previous agent's background msiexec work, or a servicing tail after
Windows Update. The guest script exits 1 and only reports the 1618 in its error text, so the match is on exit code 1
plus the text.
Escalation: fix attempt 1 only waits for the installer to go idle (nothing is stopped). Attempt 2 waits again, then
stops leftovers from InstallDir and msiexec. Attempt 3 stops InstallDir leftovers and the host reboots
(RebootFromAttempt), AfterReboot waits for idle.
With MaxStepAttempts 4 (default) the four step attempts are the original run plus these three fix retries.
Every attempt first logs the running msiexec processes (read only) to show who holds the lock.
Windows PowerShell 5.1 compatible.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Read by Read-GIFixCatalog')]
param()
$GIFix = @{
    Id                = 'InstallerBusy1618'
    Description       = 'Windows Installer busy (MSI 1618): wait for idle, then stop leftover installers, then reboot on the third time'
    Priority          = 90
    Actions           = @('*')
    MaxAttempts       = 3
    RebootFromAttempt = 3
    Match             = @{
        ExitCodes = @(1)
        Patterns  = @('exited with code 1618\b', 'ERROR_INSTALL_ALREADY_RUNNING', 'another installation is (already )?in progress')
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
            $idle = [bool](Wait-GIMsiIdle -TimeoutSec 300)
            $msg = "After reboot, last boot time $boot; Windows Installer is $(if ($idle) { 'idle' } else { 'still busy' })"
            Write-GIFixLog -Message $msg
            return @{ Ok = $idle; Message = $msg }
        }

        # Diagnostic (read only): who holds the installer lock
        try {
            $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='msiexec.exe'" -ErrorAction Stop)
            if ($procs.Count -eq 0) {
                Write-GIFixLog -Message 'Diagnostic: no msiexec process is running'
            } else {
                foreach ($p in $procs) {
                    $cl = [string]$p.CommandLine
                    if ($cl.Length -gt 300) { $cl = $cl.Substring(0, 300) }
                    Write-GIFixLog -Message "Diagnostic: msiexec pid $($p.ProcessId): $cl"
                }
            }
        } catch {
            Write-GIFixLog -Message "Diagnostic: could not list msiexec processes: $($_.Exception.Message)"
        }

        $attempt = [int]$Context.FixAttempt
        if ($attempt -le 1) {
            Write-GIFixLog -Message "MSI 1618 in step $($Context.StepId): waiting up to 540 s for the Windows Installer"
            $idle = [bool](Wait-GIMsiIdle -TimeoutSec 540)   # under the 600 s FixTimeoutSec, so the watcher never kills a wait that just succeeded
            $msg = "Waited for the Windows Installer; it is $(if ($idle) { 'idle' } else { 'still busy' })"
            Write-GIFixLog -Message $msg
            return @{ Ok = $idle; Message = $msg }
        }
        if ($attempt -eq 2) {
            Write-GIFixLog -Message "MSI 1618 in step $($Context.StepId), second time: waiting up to 120 s, then stopping leftover installers"
            $stopped = @()
            $idle = [bool](Wait-GIMsiIdle -TimeoutSec 120)
            if (-not $idle) {
                $stopped += @(Stop-GIAllowedProcess -InstallDirOnly)
                $stopped += @(Stop-GIAllowedProcess -Name 'msiexec')
                $idle = [bool](Wait-GIMsiIdle -TimeoutSec 120)
            }
            $msg = "Stopped $(@($stopped).Count) process(es); Windows Installer is $(if ($idle) { 'idle' } else { 'still busy' })"
            Write-GIFixLog -Message $msg
            return @{ Ok = $idle; Message = $msg }
        }

        Write-GIFixLog -Message "MSI 1618 in step $($Context.StepId), third time: stopping leftover installers; a reboot follows"
        $stopped = @(Stop-GIAllowedProcess -InstallDirOnly)
        $msg = "Stopped $(@($stopped).Count) process(es) from InstallDir; rebooting before the retry"
        Write-GIFixLog -Message $msg
        return @{ Ok = $true; Message = $msg }
    } catch {
        return @{ Ok = $false; Message = "Fix could not complete: $($_.Exception.Message)" }
    }
}
