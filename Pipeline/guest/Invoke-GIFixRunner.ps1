<#
.SYNOPSIS
  Runs one fix script in its own process for the guest watcher (Windows PowerShell 5.1 compatible).
.DESCRIPTION
  Dot-sources the fix, calls Invoke-GIFix -Context and writes { ok, message, outcome } to ResultPath. A throw inside
  the fix is a FixFailed result, never a crash of the watcher. The helpers below are what fixes may call; they are
  the only sanctioned way to stop processes or wait for the installer service.
#>
param(
    [Parameter(Mandatory)] [string] $FixPath,
    [Parameter(Mandatory)] [string] $ContextPath,
    [Parameter(Mandatory)] [string] $ResultPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GIWatcher.Core.ps1')

$script:GIFixContext = $null

function Write-GIFixLog {
    <#
    .SYNOPSIS  Appends a line to the watcher log under the current step id.
    #>
    param([Parameter(Mandatory)] [string] $Message)
    $c = $script:GIFixContext
    if (-not $c -or -not $c.WorkDir) { return }
    Write-GIWatcherLog -Path (Join-Path $c.WorkDir 'watcher.log') -Level INFO -StepId ([string]$c.StepId) -Message "[fix] $Message"
}

function Stop-GIAllowedProcess {
    <#
    .SYNOPSIS  Stops msiexec (-Name msiexec) or processes whose image is under InstallDir (-InstallDirOnly). Returns stopped pids.
    .DESCRIPTION
      The watcher, its parent chain and this runner are protected; anything outside the allowlist is skipped even
      when named, so a fix cannot take down the pipeline.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByName')] [string] $Name,
        [Parameter(Mandatory, ParameterSetName = 'InstallDir')] [switch] $InstallDirOnly
    )
    $c = $script:GIFixContext
    $protected = @($c.ProtectedPids | ForEach-Object { [int]$_ }) + $PID + $(if ($c.WatcherPid) { [int]$c.WatcherPid })
    $stopped = @()
    $procs = if ($PSCmdlet.ParameterSetName -eq 'ByName') { @(Get-Process -Name ($Name -replace '\.exe$', '') -ErrorAction SilentlyContinue) } else { @(Get-Process -ErrorAction SilentlyContinue) }
    foreach ($p in $procs) {
        $path = $null
        try { $path = $p.Path } catch { $path = $null }
        $ok = Test-GIProcessStoppable -ProcessId $p.Id -Name $p.ProcessName -Path $path -InstallDir ([string]$c.InstallDir) -ProtectedPids $protected -InstallDirOnly:$InstallDirOnly
        if (-not $ok) { continue }
        try {
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
            $stopped += $p.Id
            Write-GIFixLog -Message "Stopped $($p.ProcessName) (pid $($p.Id))"
        } catch { Write-GIFixLog -Message "Could not stop $($p.ProcessName) (pid $($p.Id)): $($_.Exception.Message)" }
    }
    return $stopped
}

function Wait-GIMsiIdle {
    <#
    .SYNOPSIS  Waits until the Windows Installer mutex (Global\_MSIExecute) is free; $true when idle, $false on timeout.
    #>
    param([int] $TimeoutSec = 300)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $busy = $false
        try {
            $m = [System.Threading.Mutex]::OpenExisting('Global\_MSIExecute')
            try {
                # Owning it means nobody else does: the service is idle
                try { if ($m.WaitOne(0)) { $m.ReleaseMutex() } else { $busy = $true } } catch [System.Threading.AbandonedMutexException] { $busy = $false }
            } finally { $m.Dispose() }
        } catch { $busy = $false }   # mutex absent (or not supported here) = idle
        if (-not $busy) { return $true }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return $false
}

$result = [ordered]@{ ok = $false; message = ''; outcome = 'FixFailed' }
try {
    $script:GIFixContext = Get-Content -LiteralPath $ContextPath -Raw -Encoding UTF8 | ConvertFrom-Json
    # The runner and its parents (powershell/cmd) are never stoppable
    $script:GIFixContext.ProtectedPids = @(@($script:GIFixContext.ProtectedPids) + (Get-GIParentPidChain -ProcessId $PID))
    . $FixPath
    $ret = @(Invoke-GIFix -Context $script:GIFixContext) | Where-Object {
        $_ -is [System.Collections.IDictionary] -or ($_ -and $_.PSObject.Properties['Ok'])
    } | Select-Object -Last 1
    if ($null -eq $ret) { throw 'Invoke-GIFix returned no @{ Ok; Message } result' }
    $ok = if ($ret -is [System.Collections.IDictionary]) { [bool]$ret['Ok'] } else { [bool]$ret.Ok }
    $msg = if ($ret -is [System.Collections.IDictionary]) { [string]$ret['Message'] } else { [string]$ret.Message }
    $result.ok = $ok
    $result.message = $msg
    $result.outcome = if ($ok) { 'Applied' } else { 'FixFailed' }
} catch {
    $result.ok = $false
    $result.message = "Fix threw: $($_.Exception.Message)"
    $result.outcome = 'FixFailed'
}
Write-GIWatcherJson -Path $ResultPath -InputObject $result
exit 0
