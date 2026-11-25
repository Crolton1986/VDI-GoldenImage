<#
.SYNOPSIS
  Guest watcher: runs the Maintain guest steps from plan.json, applies known fixes, asks the host for reboots.
  Windows PowerShell 5.1 compatible. Spec: Pipeline/docs/CONTRACT.md, section "Guest watcher".
.DESCRIPTION
  Exit codes: 0 all done or reboot requested, 1 a step failed, 2 plan missing or invalid, 3 unexpected crash.
  Dot-sourcing this file (Pester) defines the functions without running anything; the main loop only runs when the
  file is executed. Every child process goes through Start-GIStepProcess / Start-GIFixProcess so tests can mock them.
.PARAMETER WorkDir
  Guest work folder <W> holding plan.json, steps\, fixes\ and the watcher\ copy of this script.
#>
param([Parameter(Mandatory)] [string] $WorkDir)

. (Join-Path $PSScriptRoot 'GIWatcher.Core.ps1')

#----- Child processes (the only place that starts processes) -----

function Stop-GIProcessTree {
    <#
    .SYNOPSIS  Kills one process and its descendants (used only for the fix child that timed out).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int] $ProcessId)
    $ids = New-Object System.Collections.Generic.List[int]
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($ProcessId)
    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        $ids.Add($cur)
        try {
            foreach ($c in @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$cur" -ErrorAction Stop)) { $queue.Enqueue([int]$c.ProcessId) }
        } catch { Write-Verbose "Child lookup failed: $($_.Exception.Message)" }
    }
    for ($i = $ids.Count - 1; $i -ge 0; $i--) { Stop-Process -Id $ids[$i] -Force -ErrorAction SilentlyContinue }
}

function Invoke-GIChildProcess {
    <#
    .SYNOPSIS  Runs powershell.exe with stdout+stderr in ONE file, calling OnTick every TickSec while it runs.
    .DESCRIPTION
      Start-Process cannot send both streams to the same file, and async readers inside the scheduled task add
      event-runspace trouble, so the child is started through `cmd /s /c "... > out 2>&1"`: the shell owns the
      redirection and the file is always complete when the child exits. The exit code of cmd is the child's.
    .OUTPUTS   @{ ExitCode; TimedOut }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $ArgumentList, [Parameter(Mandatory)] [string] $OutFile,
        [int] $TickSec = 15, [scriptblock] $OnTick, [int] $TimeoutSec = 0
    )
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $inner = '"{0}" {1} > "{2}" 2>&1' -f $ps, ($ArgumentList -join ' '), $OutFile
    $p = Start-Process -FilePath $env:ComSpec -ArgumentList @('/s', '/c', ('"' + $inner + '"')) -PassThru -WindowStyle Hidden
    $null = $p.Handle   # keeps the handle so ExitCode stays readable after exit
    $deadline = if ($TimeoutSec -gt 0) { (Get-Date).AddSeconds($TimeoutSec) } else { $null }
    $timedOut = $false
    while (-not $p.WaitForExit([Math]::Max(1, $TickSec) * 1000)) {
        if ($OnTick) { try { & $OnTick } catch { Write-Verbose "Tick failed: $($_.Exception.Message)" } }
        if ($deadline -and (Get-Date) -gt $deadline) {
            Stop-GIProcessTree -ProcessId $p.Id
            $timedOut = $true
            $null = $p.WaitForExit(5000)
            break
        }
    }
    $code = if ($timedOut) { -1 } else { $p.ExitCode }
    return @{ ExitCode = $code; TimedOut = $timedOut }
}

function Start-GIStepProcess {
    <#
    .SYNOPSIS  Runs one step attempt (Action script or WU pass) in a fresh powershell.exe; waits and heartbeats. Mock point for tests.
    .OUTPUTS   @{ ExitCode; TimedOut }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $ArgumentList, [Parameter(Mandatory)] [string] $OutFile,
        [string] $StepId, [int] $Attempt, [string] $ResultFile, [int] $TickSec = 15, [scriptblock] $OnTick
    )
    return Invoke-GIChildProcess -ArgumentList $ArgumentList -OutFile $OutFile -TickSec $TickSec -OnTick $OnTick
}

function Start-GIFixProcess {
    <#
    .SYNOPSIS  Runs Invoke-GIFixRunner.ps1 for one fix, killing only that child after TimeoutSec. Mock point for tests.
    .OUTPUTS   @{ ExitCode; TimedOut }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $ArgumentList, [Parameter(Mandatory)] [string] $OutFile,
        [string] $StepId, [string] $FixId, [string] $FixPath, [string] $ContextPath, [string] $ResultPath,
        [int] $TimeoutSec = 600, [int] $TickSec = 15, [scriptblock] $OnTick
    )
    return Invoke-GIChildProcess -ArgumentList $ArgumentList -OutFile $OutFile -TickSec $TickSec -OnTick $OnTick -TimeoutSec $TimeoutSec
}

#----- State helpers -----

function Add-GIWatcherLogLine {
    # Logging must never take the watcher down
    param($Ctx, [string] $Level, [string] $StepId, [string] $Message)
    try { Write-GIWatcherLog -Path $Ctx.Paths.Log -Level $Level -StepId $StepId -Message $Message } catch { Write-Verbose "Log write failed: $($_.Exception.Message)" }
}

function Save-GIWatcherState {
    <#
    .SYNOPSIS  Updates and writes watcher.json (state Running/Exited/RebootRequested, exitReason).
    #>
    param($Ctx, [string] $State = 'Running', [string] $ExitReason, [string] $CurrentStep)
    $w = $Ctx.Watcher
    $now = (Get-Date).ToString('o')
    $w.heartbeat = $now
    if ($PSBoundParameters.ContainsKey('CurrentStep')) { $w.currentStep = $CurrentStep }
    $w.state = $State
    $w.exitReason = if ($ExitReason) { $ExitReason } else { $null }
    $w.endedAt = if ($State -ne 'Running') { $now } else { $null }
    Write-GIWatcherJson -Path $Ctx.Paths.Watcher -InputObject $w
}

function Save-GIStep {
    param($Ctx, $Step)
    Write-GIWatcherJson -Path (Join-Path $Ctx.Paths.Steps ((Get-GIStepFileId -Id $Step.id) + '.json')) -InputObject $Step
}

function New-GIStepState {
    param($Plan, [string] $Id)
    return [ordered]@{
        schemaVersion = 1; runId = $Plan.runId; attemptId = $Plan.attemptId; id = $Id; status = 'Pending'
        attempt = 0; attemptStartedAt = $null; startedAt = $null; endedAt = $null; heartbeat = $null
        exitCode = $null; message = ''; originalError = $null; fixApplied = @(); pendingFix = $null
        rebootAfter = $false; data = [ordered]@{}
    }
}

function Invoke-GIWatcherHeartbeat {
    <#
    .SYNOPSIS  One heartbeat: refresh step file and watcher.json, copy new child output lines to watcher.log as OUT.
    #>
    param($Ctx, $Step, [string] $OutFile, $OffsetBox, [switch] $Final)
    $now = (Get-Date).ToString('o')
    $Step.heartbeat = $now
    Save-GIStep -Ctx $Ctx -Step $Step
    Save-GIWatcherState -Ctx $Ctx -State 'Running'
    $tail = Read-GIOutTail -Path $OutFile -Offset $OffsetBox.v -Final:$Final
    foreach ($l in $tail.Lines) { Add-GIWatcherLogLine -Ctx $Ctx -Level 'OUT' -StepId $Step.id -Message $l }
    $OffsetBox.v = $tail.NextOffset
}

#----- Fix execution -----

function Invoke-GIWatcherFix {
    <#
    .SYNOPSIS  Runs one fix in the runner child and returns @{ outcome = Applied|FixFailed|TimedOut; message }.
    #>
    param($Ctx, $Step, $FixEntry, [int] $FixAttempt, [ValidateSet('BeforeRetry', 'AfterReboot')] [string] $Phase, $ErrorText, $ExitCode)
    $plan = $Ctx.Plan
    $fid = Get-GIStepFileId -Id $Step.id
    $suffix = if ($Phase -eq 'AfterReboot') { "$($Step.attempt).after" } else { "$($Step.attempt)" }
    $ctxFile = Join-Path $Ctx.Paths.FixesRun "$fid.$suffix.context.json"
    $resFile = Join-Path $Ctx.Paths.FixesRun "$fid.$suffix.result.json"
    $outFile = Join-Path $Ctx.Paths.FixesRun "$fid.$suffix.out.txt"
    if (Test-Path -LiteralPath $resFile) { Remove-Item -LiteralPath $resFile -Force -ErrorAction SilentlyContinue }
    $action = if ($Step.id -eq 'WindowsUpdate') { 'WindowsUpdate' } else { [string]$Ctx.PlanSteps[$Step.id].action }
    $et = if ($ErrorText) { $ErrorText } else { @{ Errors = ''; Output = ''; Log = '' } }
    $context = [ordered]@{
        StepId = $Step.id; Action = $action; Phase = $Phase; ExitCode = $ExitCode; ErrorText = $et
        FixAttempt = $FixAttempt; StepAttempt = $Step.attempt; WorkDir = $Ctx.Paths.WorkDir; ScriptPath = [string]$plan.scriptPath
        InstallDir = [string]$plan.installDir; LogDir = [string]$plan.logDir; WatcherPid = $PID
        ProtectedPids = @(Get-GIParentPidChain -ProcessId $PID)
    }
    Write-GIWatcherJson -Path $ctxFile -InputObject $context
    $runner = Join-Path $Ctx.ScriptDir 'Invoke-GIFixRunner.ps1'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $runner),
        '-FixPath', ('"{0}"' -f $FixEntry.File), '-ContextPath', ('"{0}"' -f $ctxFile), '-ResultPath', ('"{0}"' -f $resFile))
    $box = @{ v = 0 }
    $tick = { Invoke-GIWatcherHeartbeat -Ctx $Ctx -Step $Step -OutFile $outFile -OffsetBox $box }.GetNewClosure()
    Add-GIWatcherLogLine -Ctx $Ctx -Level 'INFO' -StepId $Step.id -Message "Running fix $($FixEntry.Id) (fix attempt $FixAttempt, phase $Phase): $($FixEntry.Meta.Description)"
    $run = Start-GIFixProcess -ArgumentList $argList -OutFile $outFile -StepId $Step.id -FixId $FixEntry.Id -FixPath $FixEntry.File `
        -ContextPath $ctxFile -ResultPath $resFile -TimeoutSec (Get-GIWatcherSetting -Plan $plan -Name 'fixTimeoutSec') `
        -TickSec (Get-GIWatcherSetting -Plan $plan -Name 'heartbeatSec') -OnTick $tick
    Invoke-GIWatcherHeartbeat -Ctx $Ctx -Step $Step -OutFile $outFile -OffsetBox $box -Final
    $res = Read-GIWatcherJson -Path $resFile
    if ($run.TimedOut) { $out = @{ outcome = 'TimedOut'; message = "Fix timed out after $(Get-GIWatcherSetting -Plan $plan -Name 'fixTimeoutSec') s" } }
    elseif (-not $res) { $out = @{ outcome = 'FixFailed'; message = "Fix runner left no result (exit $($run.ExitCode))" } }
    else { $out = @{ outcome = $(if ($res.ok -eq $true) { 'Applied' } else { 'FixFailed' }); message = [string]$res.message } }
    $lvl = if ($out.outcome -eq 'Applied') { 'INFO' } else { 'WARN' }
    Add-GIWatcherLogLine -Ctx $Ctx -Level $lvl -StepId $Step.id -Message "Fix $($FixEntry.Id): $($out.outcome). $($out.message)"
    return $out
}

#----- One step -----

function Invoke-GIWatcherStep {
    <#
    .SYNOPSIS  Drives one plan step to Succeeded, a reboot request or Failed (contract steps 3-8).
    .OUTPUTS   'Succeeded' | 'RebootRequested' | 'Failed'
    #>
    param($Ctx, $PlanStep)
    $plan = $Ctx.Plan
    $id = [string]$PlanStep.id
    $fid = Get-GIStepFileId -Id $id
    $existing = Read-GIWatcherJson -Path (Join-Path $Ctx.Paths.Steps "$fid.json")
    $decision = Get-GIStepStartDecision -Plan $plan -StepFile $existing

    if ($decision -eq 'Skip') { Add-GIWatcherLogLine -Ctx $Ctx -Level 'INFO' -StepId $id -Message 'Step already succeeded; skipping'; return 'Succeeded' }
    if ($decision -eq 'Reset') {
        $step = New-GIStepState -Plan $plan -Id $id
    } else {
        $step = ConvertTo-GIHashtable -InputObject $existing
        foreach ($k in 'fixApplied') { if ($null -eq $step[$k]) { $step[$k] = @() } }
        if ($null -eq $step['data']) { $step['data'] = [ordered]@{} }
    }
    Save-GIWatcherState -Ctx $Ctx -State 'Running' -CurrentStep $id

    if ($decision -eq 'Stop') {
        Add-GIWatcherLogLine -Ctx $Ctx -Level 'ERROR' -StepId $id -Message "Step is Failed in this attempt: $($step.message)"
        Save-GIWatcherState -Ctx $Ctx -State 'Exited' -ExitReason 'StepFailed'
        return 'Failed'
    }
    if ($decision -eq 'Resume' -and $step.status -in 'Running', 'Fixing') {
        Add-GIWatcherLogLine -Ctx $Ctx -Level 'WARN' -StepId $id -Message "Step was $($step.status) when the watcher started (interrupted); continuing as a new attempt"
    }
    if ($decision -eq 'AfterReboot' -and $step.pendingFix) {
        $pf = $step.pendingFix
        $entry = @($Ctx.Catalog | Where-Object { $_.Valid -and $_.Id -eq $pf.id }) | Select-Object -First 1
        if ($entry) {
            $r = Invoke-GIWatcherFix -Ctx $Ctx -Step $step -FixEntry $entry -FixAttempt ([int]$pf.fixAttempt) -Phase 'AfterReboot' -ErrorText $null -ExitCode $step.exitCode
            Add-GIWatcherLogLine -Ctx $Ctx -Level 'INFO' -StepId $id -Message "Post-reboot part of fix $($pf.id): $($r.outcome)"
        } else {
            Add-GIWatcherLogLine -Ctx $Ctx -Level 'WARN' -StepId $id -Message "Pending fix '$($pf.id)' is no longer in the catalog; retrying anyway"
        }
        $step.pendingFix = $null
    }
    if (-not $step.startedAt) { $step.startedAt = (Get-Date).ToString('o') }
    $isWu = ($PlanStep.kind -eq 'WindowsUpdate')
    $maxAttempts = Get-GIWatcherSetting -Plan $plan -Name 'maxStepAttempts'
    $maxPasses = if ($PlanStep.PSObject.Properties['maxPasses'] -and $PlanStep.maxPasses) { [int]$PlanStep.maxPasses } else { 5 }
    $tickSec = Get-GIWatcherSetting -Plan $plan -Name 'heartbeatSec'
    $actionName = if ($isWu) { 'WindowsUpdate' } else { [string]$PlanStep.action }

    while ($true) {
        $passes = @(); if ($step.data.Contains('passes') -and $step.data['passes']) { $passes = @($step.data['passes']) }
        # Every WU pass is its own launch, but only retries count against the cap
        $effective = [pscustomobject]@{ attempt = ([int]$step.attempt - $passes.Count) }
        if (-not (Test-GIAttemptAllowed -StepFile $effective -MaxAttempts $maxAttempts)) {
            $orig = if ($step.originalError) { $step.originalError } else { 'unknown error' }
            $step.status = 'Failed'; $step.endedAt = (Get-Date).ToString('o'); $step.message = "Gave up after $($step.attempt) attempts: $orig"
            Save-GIStep -Ctx $Ctx -Step $step
            Add-GIWatcherLogLine -Ctx $Ctx -Level 'ERROR' -StepId $id -Message $step.message
            Save-GIWatcherState -Ctx $Ctx -State 'Exited' -ExitReason 'StepFailed'
            return 'Failed'
        }
        $pass = if ($isWu) { [int]$(if ($step.data.Contains('pass')) { $step.data['pass'] } else { 0 }) + 1 } else { 0 }
        $step.attempt = [int]$step.attempt + 1
        $step.status = 'Running'
        $step.attemptStartedAt = (Get-Date).ToString('o')
        $step.message = if ($isWu) { "Windows Update pass $pass" } else { "Running $actionName" }
        New-Item -ItemType Directory -Path $Ctx.Paths.Steps -Force | Out-Null
        $outFile = Join-Path $Ctx.Paths.Steps "$fid.$($step.attempt).out.txt"
        $resFile = Join-Path $Ctx.Paths.Steps "$fid.$($step.attempt).result.json"
        foreach ($f in $outFile, $resFile) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
        Save-GIStep -Ctx $Ctx -Step $step
        Add-GIWatcherLogLine -Ctx $Ctx -Level 'INFO' -StepId $id -Message "Attempt $($step.attempt): $($step.message)"

        $argList = New-GIStepArgumentList -Step $PlanStep -Plan $plan -ResultFile $resFile -ScriptDir $Ctx.ScriptDir
        $box = @{ v = 0 }
        $tick = { Invoke-GIWatcherHeartbeat -Ctx $Ctx -Step $step -OutFile $outFile -OffsetBox $box }.GetNewClosure()
        $run = Start-GIStepProcess -ArgumentList $argList -OutFile $outFile -StepId $id -Attempt $step.attempt -ResultFile $resFile -TickSec $tickSec -OnTick $tick
        Invoke-GIWatcherHeartbeat -Ctx $Ctx -Step $step -OutFile $outFile -OffsetBox $box -Final

        $result = Read-GIWatcherJson -Path $resFile
        $exit = [int]$run.ExitCode
        $kind = if ($isWu) { 'WindowsUpdate' } else { 'Action' }
        $o = Get-GIAttemptOutcome -Kind $kind -ExitCode $exit -Result $result -MaxPasses $maxPasses -Pass $pass

        if ($o.Status -ne 'Failed') {
            $step.exitCode = $exit
            if ($isWu) {
                $step.data['passes'] = @($passes) + $o.PassEntry
                $step.data['pass'] = $pass
            } else {
                $step.data['versions'] = $o.Data.versions
                $step.data['rebootRequired'] = $o.Data.rebootRequired
            }
            $step.message = $o.Message
            Add-GIWatcherLogLine -Ctx $Ctx -Level 'INFO' -StepId $id -Message "Attempt $($step.attempt) finished: $($o.Status). $($o.Message)"
            switch ($o.Status) {
                'NextPass' { Save-GIStep -Ctx $Ctx -Step $step; continue }
                'RebootRequired' {
                    $step.status = 'RebootRequired'
                    Save-GIStep -Ctx $Ctx -Step $step
                    Save-GIWatcherState -Ctx $Ctx -State 'RebootRequested' -ExitReason 'RebootRequested'
                    return 'RebootRequested'
                }
                default {
                    $step.status = 'Succeeded'; $step.endedAt = (Get-Date).ToString('o'); $step.exitCode = 0
                    $step.rebootAfter = [bool]$o.RebootAfter
                    Save-GIStep -Ctx $Ctx -Step $step
                    if ($o.RebootAfter) {
                        Save-GIWatcherState -Ctx $Ctx -State 'RebootRequested' -ExitReason 'RebootRequested'
                        return 'RebootRequested'
                    }
                    return 'Succeeded'
                }
            }
            continue
        }

        # Failure: build the error text once, remember the first one, look for a fix
        $et = Get-GIStepErrorText -Result $result -OutFile $outFile -LogDir ([string]$plan.logDir) -Since $step.attemptStartedAt
        if (-not $step.originalError) { $step.originalError = Get-GIOriginalError -ErrorText $et -ExitCode $exit }
        $step.exitCode = $exit
        Add-GIWatcherLogLine -Ctx $Ctx -Level 'WARN' -StepId $id -Message "Attempt $($step.attempt) failed (exit $exit): $(Get-GIOriginalError -ErrorText $et -ExitCode $exit)"
        $sel = Select-GIFix -Catalog $Ctx.Catalog -Action $actionName -ExitCode $exit -ErrorText $et -Applied @($step.fixApplied)
        if (-not $sel) {
            $step.status = 'Failed'; $step.endedAt = (Get-Date).ToString('o')
            $step.message = "In-guest action '$actionName' exited ${exit}: $($step.originalError)"
            Save-GIStep -Ctx $Ctx -Step $step
            Add-GIWatcherLogLine -Ctx $Ctx -Level 'ERROR' -StepId $id -Message $step.message
            Save-GIWatcherState -Ctx $Ctx -State 'Exited' -ExitReason 'StepFailed'
            return 'Failed'
        }
        $step.status = 'Fixing'
        $step.message = "Attempt $($step.attempt) failed; applying fix $($sel.Fix.Id)"
        Save-GIStep -Ctx $Ctx -Step $step
        $fr = Invoke-GIWatcherFix -Ctx $Ctx -Step $step -FixEntry $sel.Fix -FixAttempt $sel.FixAttempt -Phase 'BeforeRetry' -ErrorText $et -ExitCode $exit
        $step.fixApplied = @($step.fixApplied) + [ordered]@{
            id = $sel.Fix.Id; fixAttempt = $sel.FixAttempt; stepAttempt = $step.attempt
            at = (Get-Date).ToString('o'); outcome = $fr.outcome; message = $fr.message
        }
        if ($sel.RebootBeforeRetry) {
            $step.pendingFix = [ordered]@{ id = $sel.Fix.Id; fixAttempt = $sel.FixAttempt }
            $step.status = 'RebootRequired'
            $step.message = "Reboot requested after fix $($sel.Fix.Id)"
            Save-GIStep -Ctx $Ctx -Step $step
            Save-GIWatcherState -Ctx $Ctx -State 'RebootRequested' -ExitReason 'RebootRequested'
            return 'RebootRequested'
        }
        Save-GIStep -Ctx $Ctx -Step $step
    }
}

#----- Main -----

function Invoke-GIWatcherMain {
    <#
    .SYNOPSIS  The watcher: plan -> steps -> watcher.json. Returns the process exit code and never throws.
    .PARAMETER WorkDir    Guest work folder <W>.
    .PARAMETER ScriptDir  Folder of the watcher scripts (where Invoke-GIFixRunner.ps1 and Invoke-GIWindowsUpdate.ps1 live).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $WorkDir, [string] $ScriptDir = $PSScriptRoot)
    $paths = Get-GIWatcherPaths -WorkDir $WorkDir
    $ctx = @{ Paths = $paths; ScriptDir = $ScriptDir; Plan = $null; Catalog = @(); PlanSteps = @{}; Watcher = $null }
    try {
        $plan = Read-GIWatcherJson -Path $paths.Plan
        $planErrors = @(Test-GIWatcherPlan -Plan $plan)
        $now = (Get-Date).ToString('o')
        $ctx.Watcher = [ordered]@{
            schemaVersion = 1; pid = $PID; launchId = $(if ($plan) { [string]$plan.launchId } else { $null }); attemptId = $(if ($plan) { [string]$plan.attemptId } else { $null })
            startedAt = $now; heartbeat = $now; currentStep = $null; state = 'Running'; exitReason = $null; endedAt = $null
        }
        if ($planErrors.Count -gt 0) {
            Add-GIWatcherLogLine -Ctx $ctx -Level 'ERROR' -StepId '' -Message "Invalid plan: $($planErrors -join '; ')"
            Save-GIWatcherState -Ctx $ctx -State 'Exited' -ExitReason 'PlanError'
            return 2
        }
        $ctx.Plan = $plan
        foreach ($s in @($plan.steps)) { $ctx.PlanSteps[[string]$s.id] = $s }
        Save-GIWatcherState -Ctx $ctx -State 'Running'
        Add-GIWatcherLogLine -Ctx $ctx -Level 'INFO' -StepId '' -Message "Watcher started (pid $PID, launch $($plan.launchId), attempt $($plan.attemptId), $(@($plan.steps).Count) step(s))"

        $ctx.Catalog = @(Read-GIFixCatalog -Path $paths.Fixes)
        foreach ($c in $ctx.Catalog) {
            if (-not $c.Valid) { Add-GIWatcherLogLine -Ctx $ctx -Level 'WARN' -StepId '' -Message "Fix file '$($c.Id)' ignored: $($c.Errors -join '; ')" }
        }
        Add-GIWatcherLogLine -Ctx $ctx -Level 'INFO' -StepId '' -Message "Fix catalog: $(@($ctx.Catalog | Where-Object { $_.Valid }).Count) valid fix(es)"

        foreach ($ps in @($plan.steps)) {
            $r = Invoke-GIWatcherStep -Ctx $ctx -PlanStep $ps
            if ($r -eq 'RebootRequested') {
                Add-GIWatcherLogLine -Ctx $ctx -Level 'INFO' -StepId '' -Message 'Reboot requested; watcher exits'
                return 0
            }
            if ($r -eq 'Failed') { Add-GIWatcherLogLine -Ctx $ctx -Level 'ERROR' -StepId '' -Message "Step $($ps.id) failed; watcher exits"; return 1 }
        }
        Save-GIWatcherState -Ctx $ctx -State 'Exited' -ExitReason 'AllDone' -CurrentStep ''
        Add-GIWatcherLogLine -Ctx $ctx -Level 'INFO' -StepId '' -Message 'All steps succeeded'
        return 0
    } catch {
        $msg = $_.Exception.Message
        Add-GIWatcherLogLine -Ctx $ctx -Level 'ERROR' -StepId '' -Message "Watcher crashed: $msg"
        try {
            if (-not $ctx.Watcher) { $ctx.Watcher = [ordered]@{ schemaVersion = 1; pid = $PID; launchId = $null; attemptId = $null; startedAt = (Get-Date).ToString('o'); heartbeat = $null; currentStep = $null; state = 'Running'; exitReason = $null; endedAt = $null } }
            Save-GIWatcherState -Ctx $ctx -State 'Exited' -ExitReason 'Crashed'
        } catch { Write-Verbose "Could not write watcher.json: $($_.Exception.Message)" }
        return 3
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $code = @(Invoke-GIWatcherMain -WorkDir $WorkDir -ScriptDir $PSScriptRoot)[-1]
    exit ([int]$code)
}
