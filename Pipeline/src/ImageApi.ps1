# JSON API for golden images (see docs/CONTRACT.md "Image API"). One dispatcher, testable without Pode:
#   Invoke-GIApiRequest -Config -Method -Path -Query -Body -User -Role  ->  @{ Code; Body } or @{ Code; File; FileName }
# Roles: Viewer (read), Approver (approve/reject), Admin (everything). Every write is checked here, on the server.

$script:GIRoleRank = @{ Viewer = 0; Approver = 1; Admin = 2 }
$script:GILiveWorkers = @{}

function Get-GIApiRouteTable {
    # Method, regex over the path after /api, minimum role, handler
    @(
        @{ M = 'GET';    P = '^/images$';                                                   R = 'Viewer';   H = 'Get-GIApiImages' }
        @{ M = 'POST';   P = '^/images$';                                                   R = 'Admin';    H = 'New-GIApiImage' }
        @{ M = 'DELETE'; P = '^/images/(?<id>[^/]+)$';                                      R = 'Admin';    H = 'Remove-GIApiImage' }
        @{ M = 'GET';    P = '^/images/(?<id>[^/]+)/live$';                                 R = 'Viewer';   H = 'Get-GIApiImageLive' }
        @{ M = 'GET';    P = '^/images/(?<id>[^/]+)/packages$';                             R = 'Viewer';   H = 'Get-GIApiPackages' }
        @{ M = 'GET';    P = '^/images/(?<id>[^/]+)/runs$';                                 R = 'Viewer';   H = 'Get-GIApiRuns' }
        @{ M = 'POST';   P = '^/images/(?<id>[^/]+)/runs$';                                 R = 'Admin';    H = 'Start-GIApiRun' }
        @{ M = 'GET';    P = '^/images/(?<id>[^/]+)/runs/(?<run>[^/]+)$';                   R = 'Viewer';   H = 'Get-GIApiRun' }
        @{ M = 'POST';   P = '^/images/(?<id>[^/]+)/runs/(?<run>[^/]+)/retry$';             R = 'Admin';    H = 'Invoke-GIApiRetry' }
        @{ M = 'POST';   P = '^/images/(?<id>[^/]+)/runs/(?<run>[^/]+)/approve$';           R = 'Approver'; H = 'Invoke-GIApiApprove' }
        @{ M = 'POST';   P = '^/images/(?<id>[^/]+)/runs/(?<run>[^/]+)/reject$';            R = 'Approver'; H = 'Invoke-GIApiReject' }
        @{ M = 'GET';    P = '^/images/(?<id>[^/]+)/runs/(?<run>[^/]+)/steps/(?<step>[^/]+)/log$'; R = 'Viewer'; H = 'Get-GIApiStepLog' }
        @{ M = 'GET';    P = '^/images/(?<id>[^/]+)/runs/(?<run>[^/]+)/logs\.zip$';        R = 'Viewer';   H = 'Get-GIApiLogBundle' }
        @{ M = 'GET';    P = '^/runs/(?<run>[^/]+)/logs\.zip$';                             R = 'Viewer';   H = 'Get-GIApiLogBundle' }
        @{ M = 'POST';   P = '^/images/(?<id>[^/]+)/pause$';                                R = 'Admin';    H = 'Invoke-GIApiPause' }
        @{ M = 'POST';   P = '^/images/(?<id>[^/]+)/resume$';                               R = 'Admin';    H = 'Invoke-GIApiResume' }
        @{ M = 'POST';   P = '^/images/(?<id>[^/]+)/vm/power$';                             R = 'Admin';    H = 'Invoke-GIApiVmPower' }
        @{ M = 'POST';   P = '^/images/(?<id>[^/]+)/vm/revert$';                            R = 'Admin';    H = 'Invoke-GIApiVmRevert' }
        @{ M = 'POST';   P = '^/images/(?<id>[^/]+)/pools/(?<pool>[^/]+)/rollback$';        R = 'Admin';    H = 'Invoke-GIApiRollback' }
        @{ M = 'GET';    P = '^/images/(?<id>[^/]+)/settings/(?<section>[^/]+)$';           R = 'Viewer';   H = 'Get-GIApiImageSettings' }
        @{ M = 'POST';   P = '^/images/(?<id>[^/]+)/settings/(?<section>[^/]+)$';           R = 'Admin';    H = 'Save-GIApiImageSettings' }
        @{ M = 'GET';    P = '^/settings/(?<section>[^/]+)$';                               R = 'Viewer';   H = 'Get-GIApiGlobalSettings' }
        @{ M = 'POST';   P = '^/settings/(?<section>[^/]+)$';                               R = 'Admin';    H = 'Save-GIApiGlobalSettings' }
        @{ M = 'POST';   P = '^/settings/(?<section>[^/]+)/test$';                          R = 'Admin';    H = 'Test-GIApiSettings' }
        @{ M = 'GET';    P = '^/inventory$';                                                R = 'Admin';    H = 'Get-GIApiInventory' }
        @{ M = 'GET';    P = '^/fixes$';                                                    R = 'Viewer';   H = 'Get-GIApiFixes' }
    )
}

function Test-GIRoleAtLeast {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Have, [string]$Need)
    $h = if ($script:GIRoleRank.ContainsKey($Have)) { $script:GIRoleRank[$Have] } else { -1 }
    return ($h -ge $script:GIRoleRank[$Need])
}

function New-GIApiError {
    param([int]$Code, [string]$Message, [hashtable]$Extra = @{})
    $b = [ordered]@{ error = $Message }
    foreach ($k in $Extra.Keys) { $b[$k] = $Extra[$k] }
    @{ Code = $Code; Body = $b }
}

function Invoke-GIApiRequest {
    <#
    .SYNOPSIS
      Routes one API call. Returns @{ Code; Body } (or File/FileName for the log bundle). Never throws:
      unexpected errors become a 500 with an error id that is also written to the audit log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Query = @{},
        $Body = $null,
        [string]$User = 'anonymous',
        [ValidateSet('Viewer', 'Approver', 'Admin')][string]$Role = 'Viewer',
        [hashtable]$Options = @{}   # ConfigPath, LiveInvoker (tests)
    )
    $p = $Path
    if ($p.StartsWith('/api')) { $p = $p.Substring(4) }
    $p = $p.TrimEnd('/')
    if ($p.Contains('%')) { try { $p = [uri]::UnescapeDataString($p) } catch { return New-GIApiError 400 'Bad path' } }
    foreach ($route in (Get-GIApiRouteTable)) {
        if ($route.M -ne $Method.ToUpperInvariant()) { continue }
        $m = [regex]::Match($p, $route.P)
        if (-not $m.Success) { continue }
        if (-not (Test-GIRoleAtLeast -Have $Role -Need $route.R)) {
            Write-GIAudit -Config $Config -User $User -Role $Role -Action 'auth.denied' -Target "$Method $p" -Detail @{ needed = $route.R; role = $Role; result = 'Denied' }
            return New-GIApiError 403 "This needs the $($route.R.ToLower()) role."
        }
        $req = @{ Config = $Config; Method = $Method; Path = $p; Query = $Query; Body = $Body; User = $User; Role = $Role; Options = $Options; Args = @{} }
        foreach ($g in $m.Groups) { if ($g.Name -notmatch '^\d+$') { $req.Args[$g.Name] = $g.Value } }
        try {
            return (& $route.H $req)
        } catch {
            $eid = [guid]::NewGuid().ToString('N').Substring(0, 8)
            Write-GIAudit -Config $Config -User $User -Role $Role -Action 'api.error' -Target "$Method $p" -Detail @{ errorId = $eid; message = $_.Exception.Message; result = 'Error' }
            return New-GIApiError 500 'Something went wrong on the server.' @{ errorId = $eid }
        }
    }
    return New-GIApiError 404 'Unknown API path'
}

#----- Helpers -----

function Get-GIBodyValue {
    param($Body, [string]$Name, $Default = $null)
    if ($null -eq $Body) { return $Default }
    if ($Body -is [System.Collections.IDictionary]) { if ($Body.Contains($Name)) { return $Body[$Name] } else { return $Default } }
    $pr = $Body.PSObject.Properties[$Name]
    if ($pr) { return $pr.Value } else { return $Default }
}

function Resolve-GIApiImage {
    # @{ Config } with the image config, or @{ Error } to return as is.
    param($Req)
    $id = [string]$Req.Args['id']
    if (-not (Test-GIImageId $id) -or -not (Get-GIImageEntry -Config $Req.Config -Id $id)) { return @{ Error = (New-GIApiError 404 'Golden image not found') } }
    return @{ Error = $null; Config = (Get-GIImageConfig -Config $Req.Config -ImageId $id); Id = $id }
}

function Write-GIApiAudit {
    param($Req, [string]$Action, [string]$Target = '', [hashtable]$Detail = @{}, [string]$Result = 'OK', $ImageConfig = $null)
    $c = if ($ImageConfig) { $ImageConfig } else { $Req.Config }
    Write-GIAudit -Config $c -User $Req.User -Role $Req.Role -Action $Action -Target $Target -Detail $Detail -Result $Result
}

function Get-GIOpt { param($Req, [string]$Name) if ($Req.Options.ContainsKey($Name)) { $Req.Options[$Name] } else { $null } }

function Get-GIApiTimestamp { (Get-Date).ToString('o') }

#----- Reads -----

function Get-GIApiImages {
    param($Req)
    $items = foreach ($e in (Get-GIImageEntries -Config $Req.Config)) { Get-GIImageSummary -Config $Req.Config -ImageId $e.Id }
    @{ Code = 200; Body = [ordered]@{ images = @($items) } }
}

function Get-GIApiPackages {
    param($Req)
    $img = Resolve-GIApiImage $Req; if ($img.Error) { return $img.Error }
    $st = Get-GIInstallerStatus -Config $img.Config
    @{ Code = 200; Body = [ordered]@{
            folder = $st.Folder; folderError = $st.FolderError
            packages = @($st.Packages | ForEach-Object { [ordered]@{ id = $_.Action; name = $_.Name; selected = $_.Selected; state = $_.State; file = $_.File; version = $_.Version; sizeMB = $_.SizeMB; modified = $_.Modified; autoDownload = $_.AutoDownload } })
        } }
}

function Get-GIApiRuns {
    param($Req)
    $img = Resolve-GIApiImage $Req; if ($img.Error) { return $img.Error }
    $status = [string]$Req.Query['status']
    $page = 1; if ($Req.Query['page'] -and -not [int]::TryParse([string]$Req.Query['page'], [ref]$page)) { $page = 1 }
    if ($page -lt 1) { $page = 1 }
    $size = 20
    $all = @(Get-GIRunList -Config $img.Config)
    if ($status) { $all = @($all | Where-Object { [string]$_.status -eq $status }) }
    $slice = @($all | Select-Object -Skip (($page - 1) * $size) -First $size | ForEach-Object { Get-GIRunSummary $_ })
    @{ Code = 200; Body = [ordered]@{ runs = $slice; page = $page; pageSize = $size; total = $all.Count } }
}

function Get-GIApiRun {
    param($Req)
    $img = Resolve-GIApiImage $Req; if ($img.Error) { return $img.Error }
    $runId = [string]$Req.Args['run']
    if (-not (Test-GIRunId $runId) -or -not (Test-Path -LiteralPath (Get-GIRunPath $img.Config $runId))) { return (New-GIApiError 404 'Run not found') }
    $run = Get-GIRun -Config $img.Config -RunId $runId
    $steps = @(); try { $steps = @(Get-GIStepList -Run $run) } catch { Write-Verbose 'no steps' }
    $pools = @(@($img.Config.Pools.Production) | ForEach-Object { [ordered]@{ name = [string]$_.Name; logoffPolicy = [string]$_.LogoffPolicy } })
    $next = $null; try { $next = (Get-GINextMaintenanceWindow -Config $img.Config).ToString('o') } catch { Write-Verbose 'no window' }
    $logLines = @{}
    foreach ($s in $steps) {
        try {
            $r = Get-GIStepLogResponse -Config $img.Config -RunId $runId -StepId ([string]$s.id) -Offset '0'
            if ($r.Status -eq 200) { $logLines[[string]$s.id] = @($r.Body.lines).Count }
        } catch { Write-Verbose "no log for $($s.id)" }
    }
    $body = [ordered]@{
        run = $run; imageId = $img.Id; steps = @($steps | ForEach-Object {
                $o = [ordered]@{ id = $_.id; label = $_.label; status = $_.status; startedAt = $_.startedAt; endedAt = $_.endedAt; message = $_.message
                    logLines = if ($logLines.ContainsKey([string]$_.id)) { $logLines[[string]$_.id] } else { 0 }
                    fixApplied = @(if ($_.PSObject.Properties['fixes']) { $_.fixes } else { @() }) }
                $o })
        approval = [ordered]@{ decision = Get-GIWatcherProp (Get-GIWatcherProp $run 'approval' $null) 'decision' $null; by = Get-GIWatcherProp (Get-GIWatcherProp $run 'approval' $null) 'by' $null
            at = Get-GIWatcherProp (Get-GIWatcherProp $run 'approval' $null) 'at' $null
            validation = Get-GIWatcherProp $run 'validation' $null; poolsToUpdate = $pools; nextWindow = $next }
        logBundleUrl = "/api/images/$($img.Id)/runs/$runId/logs.zip"
    }
    @{ Code = 200; Body = $body }
}

function Get-GIApiStepLog {
    param($Req)
    $img = Resolve-GIApiImage $Req; if ($img.Error) { return $img.Error }
    $r = Get-GIStepLogResponse -Config $img.Config -RunId ([string]$Req.Args['run']) -StepId ([string]$Req.Args['step']) -Offset '0'
    if ($r.Status -ne 200) { return @{ Code = $r.Status; Body = $r.Body } }
    $lines = @($r.Body.lines)
    $tail = 0
    if ($Req.Query['tail'] -and [int]::TryParse([string]$Req.Query['tail'], [ref]$tail) -and $tail -gt 0 -and $lines.Count -gt $tail) { $lines = @($lines | Select-Object -Last $tail) }
    @{ Code = 200; Body = [ordered]@{ lines = $lines; running = $r.Body.running; total = @($r.Body.lines).Count } }
}

function Get-GIApiLogBundle {
    param($Req)
    $runId = [string]$Req.Args['run']
    if (-not (Test-GIRunId $runId)) { return (New-GIApiError 404 'Run not found') }
    $cfg = $null
    if ($Req.Args['id']) { $img = Resolve-GIApiImage $Req; if ($img.Error) { return $img.Error }; $cfg = $img.Config }
    else {
        foreach ($e in (Get-GIImageEntries -Config $Req.Config)) {
            $c = Get-GIImageConfig -Config $Req.Config -ImageId $e.Id
            if (Test-Path -LiteralPath (Get-GIRunPath $c $runId)) { $cfg = $c; break }
        }
    }
    if (-not $cfg -or -not (Test-Path -LiteralPath (Get-GIRunPath $cfg $runId))) { return (New-GIApiError 404 'Run not found') }
    $b = New-GILogBundle -Config $cfg -RunId $runId
    @{ Code = 200; File = $b.Path; FileName = $b.Name; DeleteAfter = $true; ContentType = 'application/zip' }
}

function Get-GIApiFixes {
    param($Req)
    @{ Code = 200; Body = [ordered]@{ fixes = @(Get-GIFixCatalogView -Config $Req.Config) } }
}

function Get-GIApiImageSettings {
    param($Req)
    $img = Resolve-GIApiImage $Req; if ($img.Error) { return $img.Error }
    $sec = [string]$Req.Args['section']
    if ($sec -eq 'General') {
        $e = Get-GIImageEntry -Config $Req.Config -Id $img.Id
        return @{ Code = 200; Body = [ordered]@{ section = 'General'; values = [ordered]@{ Name = $e.Name; Description = $e.Description; Os = $e.Os } } }
    }
    if ($sec -eq 'AppVolumes') { return @{ Code = 200; Body = [ordered]@{ section = 'AppVolumes'; values = [ordered]@{ TestPackages = @($img.Config.AppVolumes.TestPackages) } } } }
    if ($sec -notin $script:GIImageBlocks -and $sec -notin 'Packages', 'WindowsUpdate') { return (New-GIApiError 404 'Unknown section') }
    $s = Get-GISettingsSection -Config $img.Config -Section $sec
    @{ Code = 200; Body = [ordered]@{ section = $sec; values = $s.Values } }
}

function Get-GIApiGlobalSettings {
    param($Req)
    $sec = [string]$Req.Args['section']
    if ($sec -notin 'vCenter', 'Horizon', 'AppVolumes', 'Email', 'Dashboard') { return (New-GIApiError 404 'Unknown section') }
    $s = Get-GISettingsSection -Config $Req.Config -Section $sec
    @{ Code = 200; Body = [ordered]@{ section = $sec; values = $s.Values; readOnly = [bool](Get-GISettingsSectionDef $sec).ReadOnly } }
}

#----- Live state (never in the first paint path) -----

function Get-GILiveWorker {
    # One reusable runspace per source, so the vCenter and Horizon sessions are logged in once and reused.
    param([string]$Name)
    if (-not $script:GILiveWorkers) { $script:GILiveWorkers = @{} }
    $w = $script:GILiveWorkers[$Name]
    if ($w -and $w.Runspace.RunspaceStateInfo.State -eq 'Opened') { return $w }
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    $manifest = Join-Path $script:GIModuleRoot 'VDI-GIPipeline.psd1'
    $null = $ps.AddScript('param($m) $ProgressPreference = "SilentlyContinue"; Import-Module $m -Force -ErrorAction Stop').AddArgument($manifest).Invoke()
    $ps.Commands.Clear()
    $w = @{ Runspace = $rs; Shell = $ps }
    $script:GILiveWorkers[$Name] = $w
    return $w
}

function Stop-GILiveWorker {
    param([string]$Name)
    $w = if ($script:GILiveWorkers) { $script:GILiveWorkers[$Name] } else { $null }
    if (-not $w) { return }
    $script:GILiveWorkers.Remove($Name)
    try { $w.Shell.Stop() } catch { Write-Verbose "stop: $($_.Exception.Message)" }
    try { $w.Runspace.Dispose() } catch { Write-Verbose "dispose: $($_.Exception.Message)" }
}

function Invoke-GILiveSource {
    <#
    .SYNOPSIS
      Runs a script block in the named reusable worker runspace with a hard time limit. Returns @{ Ok; Data; Error }.
      On a timeout the worker is discarded (a new one, and a new login, is made on the next call).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Work, [object[]]$ArgumentList = @(), [int]$TimeoutSec = 15)
    try {
        $w = Get-GILiveWorker -Name $Name
        $w.Shell.Commands.Clear(); $w.Shell.Streams.ClearStreams()
        $null = $w.Shell.AddScript($Work.ToString())
        foreach ($a in $ArgumentList) { $null = $w.Shell.AddArgument($a) }
        $async = $w.Shell.BeginInvoke()
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutSec * 1000)) {
            Stop-GILiveWorker -Name $Name
            return @{ Ok = $false; Data = $null; Error = "$Name did not answer within $TimeoutSec seconds" }
        }
        $out = $w.Shell.EndInvoke($async)
        if ($w.Shell.HadErrors -and $w.Shell.Streams.Error.Count) {
            $ex = $w.Shell.Streams.Error[0].Exception
            while ($ex.InnerException) { $ex = $ex.InnerException }
            $msg = [string]$ex.Message
            return @{ Ok = $false; Data = $null; Error = "${Name}: $msg" }
        }
        return @{ Ok = $true; Data = @($out | Select-Object -Last 1)[0]; Error = $null }
    } catch {
        $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }
        return @{ Ok = $false; Data = $null; Error = "${Name}: $($ex.Message)" }
    }
}

function Get-GIImageLiveState {
    <#
    .SYNOPSIS
      Live VM power state, VM snapshots and each pool's current snapshot. vCenter and Horizon are asked in parallel;
      each source reports its own error. -Invoker replaces Invoke-GILiveSource (tests).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$ImageConfig, [int]$TimeoutSec = 15, [scriptblock]$Invoker)
    $inv = if ($Invoker) { $Invoker } else { { param($n, $w, $a, $t) Invoke-GILiveSource -Name $n -Work $w -ArgumentList $a -TimeoutSec $t } }
    $vcWork = {
        param($cfg)
        $srv = $cfg.vCenter.Server
        $conn = @($global:DefaultVIServers | Where-Object { $_.IsConnected -and $_.Name -eq $srv })
        if (-not $conn) { Connect-VIServer -Server $srv -Credential (Get-GISecretCredential -Name $cfg.vCenter.CredentialSecret) -ErrorAction Stop | Out-Null }
        $vm = Get-VM -Name $cfg.GoldenImage.VmName -ErrorAction Stop
        [pscustomobject]@{
            power = [string]$vm.PowerState
            snapshots = @(Get-Snapshot -VM $vm -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ name = $_.Name; created = $_.Created.ToString('o'); isCurrent = [bool]$_.IsCurrent } })
        }
    }
    $hzWork = {
        param($cfg)
        # Reuse the Horizon login for 10 minutes
        if (-not $global:GILiveHzAt -or ((Get-Date) - $global:GILiveHzAt).TotalMinutes -gt 10) { Connect-GIHorizon -Config $cfg; $global:GILiveHzAt = Get-Date }
        $img = Get-GIHorizonBaseImage -Config $cfg
        $idToName = @{}; foreach ($s in $img.AllSnapshots) { $idToName[[string]$s.id] = $s.name }
        $names = @(@($cfg.Pools.Test.Name) + @($cfg.Pools.Production | ForEach-Object { $_.Name }) | Where-Object { $_ })
        $rows = foreach ($n in $names) {
            $info = Get-GIPoolImageInfo -Pool (Get-GIHorizonPool -Name $n)
            [pscustomobject]@{ pool = $n; snapshot = $(if ($info.SnapshotId -and $idToName.ContainsKey([string]$info.SnapshotId)) { $idToName[[string]$info.SnapshotId] } else { '' })
                pending = $(if ($info.PendingSnapshotId -and $idToName.ContainsKey([string]$info.PendingSnapshotId)) { $idToName[[string]$info.PendingSnapshotId] } else { '' }); state = [string]$info.PendingImageState }
        }
        [pscustomobject]@{ pools = @($rows) }
    }
    $lkg = Get-GILastKnownGood -Config $ImageConfig
    $vc = & $inv 'vCenter' $vcWork @($ImageConfig) $TimeoutSec
    $hz = & $inv 'Horizon' $hzWork @($ImageConfig) $TimeoutSec
    $latest = ''
    if ($vc.Ok -and $vc.Data) { $latest = [string](@($vc.Data.snapshots | Sort-Object created | Select-Object -Last 1).name) }
    $pools = @()
    if ($hz.Ok -and $hz.Data) {
        $pools = @($hz.Data.pools | ForEach-Object {
                [ordered]@{ pool = $_.pool; snapshot = [string](Get-GIWatcherProp $_ 'snapshot' ''); pending = [string](Get-GIWatcherProp $_ 'pending' ''); state = [string](Get-GIWatcherProp $_ 'state' ''); matchesLatest = [bool]($latest -and (Get-GIWatcherProp $_ 'snapshot' '') -eq $latest) }
            })
    }
    [ordered]@{
        checkedAt = Get-GIApiTimestamp
        vm = if ($vc.Ok) { [ordered]@{ name = $ImageConfig.GoldenImage.VmName; power = [string]$vc.Data.power; snapshots = @($vc.Data.snapshots); latestSnapshot = $latest } } else { $null }
        pools = $pools
        lastKnownGood = if ($lkg) { [string]$lkg.snapshotName } else { '' }
        errors = @(@(if (-not $vc.Ok) { $vc.Error }) + @(if (-not $hz.Ok) { $hz.Error }))
    }
}

function Get-GIApiImageLive {
    param($Req)
    $img = Resolve-GIApiImage $Req; if ($img.Error) { return $img.Error }
    $p = @{ ImageConfig = $img.Config }
    if ((Get-GIOpt $Req 'LiveInvoker')) { $p.Invoker = (Get-GIOpt $Req 'LiveInvoker') }
    if ((Get-GIOpt $Req 'LiveTimeoutSec')) { $p.TimeoutSec = [int](Get-GIOpt $Req 'LiveTimeoutSec') }
    @{ Code = 200; Body = (Get-GIImageLiveState @p) }
}

#----- Writes -----

function New-GIApiImage {
    param($Req)
    $payload = @{}
    if ($Req.Body -is [System.Collections.IDictionary]) { foreach ($k in $Req.Body.Keys) { if ($k -ne 'token') { $payload[$k] = $Req.Body[$k] } } }
    if ($Req.Query['dryRun']) {
        # Validate only (wizard review step): same rules, nothing is saved
        try {
            $existing = @(Get-GIImageEntries -Config $Req.Config)
            $entry = @{ Name = ([string]$payload['Name']).Trim() }
            foreach ($b in ($script:GIImageBlocks + 'AppVolumes')) { if ($payload.ContainsKey($b)) { $entry[$b] = Copy-GIValue $payload[$b] } }
            $entry.Id = New-GIImageId -Name $entry.Name -Existing @($existing | ForEach-Object { $_.Id })
            if (-not $entry.Name) { throw 'Image not saved, 1 problem(s): Name: required' }
            Assert-GIImageEntryValid -Entry $entry -Others $existing
        } catch { return (New-GIApiError 400 $_.Exception.Message) }
        return @{ Code = 200; Body = [ordered]@{ valid = $true } }
    }
    try { $e = New-GIImageFromPayload -Config $Req.Config -Payload $payload -By $Req.User }
    catch { return (New-GIApiError 400 $_.Exception.Message) }
    @{ Code = 201; Body = [ordered]@{ id = $e.Id; name = $e.Name } }
}

function Remove-GIApiImage {
    param($Req)
    $img = Resolve-GIApiImage $Req; if ($img.Error) { return $img.Error }
    try { Remove-GIImageEntry -Config $Req.Config -ImageId $img.Id -By $Req.User }
    catch { return (New-GIApiError 409 $_.Exception.Message) }
    @{ Code = 200; Body = [ordered]@{ removed = $img.Id; note = 'Removed from the dashboard only. vCenter, Horizon, snapshots, pools and run history were not touched.' } }
}

function Invoke-GIApiPause { param($Req) $i = Resolve-GIApiImage $Req; if ($i.Error) { return $i.Error }; Set-GIImagePaused -Config $Req.Config -ImageId $i.Id -Paused $true -By $Req.User; @{ Code = 200; Body = @{ paused = $true } } }
function Invoke-GIApiResume { param($Req) $i = Resolve-GIApiImage $Req; if ($i.Error) { return $i.Error }; Set-GIImagePaused -Config $Req.Config -ImageId $i.Id -Paused $false -By $Req.User; @{ Code = 200; Body = @{ paused = $false } } }

function Save-GIApiImageSettings {
    param($Req)
    $img = Resolve-GIApiImage $Req; if ($img.Error) { return $img.Error }
    $values = @{}
    if ($Req.Body -is [System.Collections.IDictionary]) { foreach ($k in $Req.Body.Keys) { if ($k -ne 'token') { $values[$k] = $Req.Body[$k] } } }
    $sec = [string]$Req.Args['section']
    $def = if ($sec -in 'General', 'AppVolumes') { $null } else { try { Get-GISettingsSectionDef $sec } catch { $null } }
    if ($sec -notin 'General', 'AppVolumes' -and -not $def) { return (New-GIApiError 404 'Unknown section') }
    # Form-style payloads (strings, checkboxes) convert with the schema; JSON payloads are already typed
    if ($def -and (Get-GIOpt $Req 'FormEncoded')) {
        $conv = ConvertFrom-GISettingsForm -Section $sec -Form $values
        if (@($conv.Errors.Keys).Count) { return (New-GIApiError 400 ((@($conv.Errors.GetEnumerator() | ForEach-Object { "$($_.Name): $($_.Value)" })) -join '; ')) }
        $values = $conv.Values
    }
    try { $r = Save-GIImageSection -Config $Req.Config -ImageId $img.Id -Section $sec -Values $values -By $Req.User }
    catch { return (New-GIApiError 400 $_.Exception.Message) }
    Write-GIAudit -Config $Req.Config -User $Req.User -Role $Req.Role -Action 'settings.update' -Target $sec -Detail @{ image = $img.Id; section = $sec; keys = @($r.Changed) } -Result 'OK'
    @{ Code = 200; Body = [ordered]@{ section = $sec; changed = @($r.Changed) } }
}

function Save-GIApiGlobalSettings {
    param($Req)
    $sec = [string]$Req.Args['section']
    if ($sec -notin 'vCenter', 'Horizon', 'AppVolumes', 'Email') { return (New-GIApiError 404 'Unknown or read-only section') }
    $values = @{}
    if ($Req.Body -is [System.Collections.IDictionary]) { foreach ($k in $Req.Body.Keys) { if ($k -ne 'token') { $values[$k] = $Req.Body[$k] } } }
    try { $r = Save-GISettingsSection -Config $Req.Config -Section $sec -Values $values -By $Req.User }
    catch { return (New-GIApiError 400 $_.Exception.Message) }
    Write-GIAudit -Config $Req.Config -User $Req.User -Role $Req.Role -Action 'settings.update' -Target $sec -Detail @{ section = $sec; keys = @($r.Changed) } -Result 'OK'
    @{ Code = 200; Body = [ordered]@{ section = $sec; changed = @($r.Changed) } }
}

function Test-GIApiSettings {
    param($Req)
    $sec = [string]$Req.Args['section']
    if ($sec -notin 'vCenter', 'Horizon', 'AppVolumes', 'Email') { return (New-GIApiError 404 'This section has no connection test') }
    $over = @{}
    if ($Req.Body -is [System.Collections.IDictionary]) {
        $over[$sec] = @{}
        foreach ($k in $Req.Body.Keys) { if ($k -ne 'token' -and $k -notmatch 'Secret|Password') { Set-GISettingsNode $over @(@($sec) + $k.Split('.')) $Req.Body[$k] } }
    }
    $run = if (Get-GIOpt $Req 'TestRunner') { Get-GIOpt $Req 'TestRunner' } else { { param($cp, $s, $o) Invoke-GIConnectionTest -ConfigPath $cp -System $s -Overrides $o } }
    $res = & $run (Get-GIOpt $Req 'ConfigPath') $sec $over
    Write-GIApiAudit -Req $Req -Action 'connection.test' -Target $sec -Detail @{ ok = [bool]$res.ok } -Result $(if ($res.ok) { 'OK' } else { 'Failed' })
    @{ Code = 200; Body = [ordered]@{ ok = [bool]$res.ok; detail = [string]$res.detail; seconds = $res.seconds } }
}

function Start-GIApiRun {
    param($Req)
    $img = Resolve-GIApiImage $Req; if ($img.Error) { return $img.Error }
    if ($img.Config.ImagePaused) { return (New-GIApiError 409 'This image is paused. Resume it to start a run.') }
    if (Test-GIImageBusy -ImageConfig $img.Config) { return (New-GIApiError 409 'A run is already active for this image.') }
    try { $r = New-GIRunRequest -Config $img.Config -Action All -RequestedBy $Req.User }
    catch { return (New-GIApiError 409 $_.Exception.Message) }
    $notice = 'queued'
    if (Get-GIOpt $Req 'StartRunner') { $notice = & (Get-GIOpt $Req 'StartRunner') $img.Config }
    Write-GIApiAudit -Req $Req -Action 'run.start' -Target $img.Id -Detail @{ image = $img.Id; request = $r.id } -ImageConfig $img.Config
    @{ Code = 202; Body = [ordered]@{ requestId = $r.id; notice = $notice } }
}

function Invoke-GIApiRetry {
    param($Req)
    $img = Resolve-GIApiImage $Req; if ($img.Error) { return $img.Error }
    $runId = [string]$Req.Args['run']
    if (-not (Test-GIRunId $runId) -or -not (Test-Path -LiteralPath (Get-GIRunPath $img.Config $runId))) { return (New-GIApiError 404 'Run not found') }
    $run = Get-GIRun -Config $img.Config -RunId $runId
    if ($run.status -ne 'Failed') { return (New-GIApiError 409 "Run $runId is $($run.status), not failed.") }
    if (Test-GIImageBusy -ImageConfig $img.Config) { return (New-GIApiError 409 'A run is already active for this image.') }
    $stage = [string]$run.currentStage; if (-not $stage) { $stage = 'Preflight' }
    $step = [string](Get-GIBodyValue $Req.Body 'step' '')
    $p = @{ Config = $img.Config; Action = 'FromStage'; Stage = $stage; RunId = $runId; RequestedBy = $Req.User }
    if ($step) { $p.Step = $step }
    try { $r = New-GIRunRequest @p } catch { return (New-GIApiError 409 $_.Exception.Message) }
    Write-GIApiAudit -Req $Req -Action 'run.retry' -Target $runId -Detail @{ image = $img.Id; stage = $stage; step = $step } -ImageConfig $img.Config
    @{ Code = 202; Body = [ordered]@{ requestId = $r.id; stage = $stage } }
}

function Invoke-GIApiApprove {
    param($Req)
    $img = Resolve-GIApiImage $Req; if ($img.Error) { return $img.Error }
    $runId = [string]$Req.Args['run']
    if (-not (Test-GIRunId $runId) -or -not (Test-Path -LiteralPath (Get-GIRunPath $img.Config $runId))) { return (New-GIApiError 404 'Run not found') }
    $run = Get-GIRun -Config $img.Config -RunId $runId
    if ($run.approval -and $run.approval.decision) {
        return (New-GIApiError 409 "Already $($run.approval.decision.ToString().ToLower()) by $($run.approval.by) at $((Get-Date $run.approval.at).ToString('HH:mm'))" @{ decidedBy = [string]$run.approval.by; decidedAt = [string]$run.approval.at })
    }
    $p = @{ Config = $img.Config; RunId = $runId; By = $Req.User; Comment = [string](Get-GIBodyValue $Req.Body 'comment' '') }
    $st = Get-GIBodyValue $Req.Body 'startTime' $null
    if ($st) { try { $p.StartTime = [datetime]::Parse([string]$st, [cultureinfo]::InvariantCulture) } catch { return (New-GIApiError 400 'Start time is not a valid date and time.') } }
    if ((Get-GIOpt $Req 'NoConnect')) { $p.NoConnect = $true }
    try { $null = Approve-GIRun @p } catch { return (New-GIApiError 409 $_.Exception.Message) }
    Write-GIApiAudit -Req $Req -Action 'approval.approve' -Target $runId -Detail @{ image = $img.Id; startTime = [string]$st; comment = $p.Comment } -ImageConfig $img.Config
    @{ Code = 200; Body = [ordered]@{ decision = 'Approved' } }
}

function Invoke-GIApiReject {
    param($Req)
    $img = Resolve-GIApiImage $Req; if ($img.Error) { return $img.Error }
    $runId = [string]$Req.Args['run']
    if (-not (Test-GIRunId $runId) -or -not (Test-Path -LiteralPath (Get-GIRunPath $img.Config $runId))) { return (New-GIApiError 404 'Run not found') }
    $comment = ([string](Get-GIBodyValue $Req.Body 'comment' '')).Trim()
    if (-not $comment) { return (New-GIApiError 400 'Add a reason when you reject a run.') }
    $run = Get-GIRun -Config $img.Config -RunId $runId
    if ($run.approval -and $run.approval.decision) {
        return (New-GIApiError 409 "Already $($run.approval.decision.ToString().ToLower()) by $($run.approval.by) at $((Get-Date $run.approval.at).ToString('HH:mm'))" @{ decidedBy = [string]$run.approval.by })
    }
    try { $null = Deny-GIRun -Config $img.Config -RunId $runId -By $Req.User -Comment $comment } catch { return (New-GIApiError 409 $_.Exception.Message) }
    Write-GIApiAudit -Req $Req -Action 'approval.reject' -Target $runId -Detail @{ image = $img.Id; comment = $comment } -ImageConfig $img.Config
    @{ Code = 200; Body = [ordered]@{ decision = 'Rejected' } }
}

function Invoke-GIVmAction {
    # Runs a vCenter VM action in the live worker (same 15 s limit as the read path; revert and power take a little longer).
    param($ImageConfig, [string]$Action, [string]$Snapshot, [scriptblock]$Invoker)
    $work = {
        param($cfg, $act, $snap)
        $srv = $cfg.vCenter.Server
        if (-not @($global:DefaultVIServers | Where-Object { $_.IsConnected -and $_.Name -eq $srv })) { Connect-VIServer -Server $srv -Credential (Get-GISecretCredential -Name $cfg.vCenter.CredentialSecret) -ErrorAction Stop | Out-Null }
        $vm = Get-VM -Name $cfg.GoldenImage.VmName -ErrorAction Stop
        switch ($act) {
            'on' { if ($vm.PowerState -ne 'PoweredOn') { Start-VM -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null } }
            'off' { if ($vm.PowerState -eq 'PoweredOn') { Stop-VMGuest -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null } }
            'revert' { $s = Get-Snapshot -VM $vm -Name $snap -ErrorAction Stop | Select-Object -First 1; Set-VM -VM $vm -Snapshot $s -Confirm:$false -ErrorAction Stop | Out-Null }
        }
        'ok'
    }
    if ($Invoker) { return (& $Invoker 'vCenter' $work @($ImageConfig, $Action, $Snapshot) 60) }
    Invoke-GILiveSource -Name 'vCenter' -Work $work -ArgumentList @($ImageConfig, $Action, $Snapshot) -TimeoutSec 60
}

function Invoke-GIApiVmPower {
    param($Req)
    $img = Resolve-GIApiImage $Req; if ($img.Error) { return $img.Error }
    $act = ([string](Get-GIBodyValue $Req.Body 'action' '')).ToLowerInvariant()
    if ($act -notin 'on', 'off') { return (New-GIApiError 400 'Action must be "on" or "off".') }
    if (Test-GIImageBusy -ImageConfig $img.Config) { return (New-GIApiError 409 'A run is active. Power changes are blocked until it finishes.') }
    $r = Invoke-GIVmAction -ImageConfig $img.Config -Action $act -Invoker (Get-GIOpt $Req 'LiveInvoker')
    Write-GIApiAudit -Req $Req -Action 'vm.power' -Target $img.Config.GoldenImage.VmName -Detail @{ image = $img.Id; power = $act } -Result $(if ($r.Ok) { 'OK' } else { 'Failed' }) -ImageConfig $img.Config
    if (-not $r.Ok) { return (New-GIApiError 502 $r.Error) }
    @{ Code = 200; Body = [ordered]@{ power = $act } }
}

function Invoke-GIApiVmRevert {
    param($Req)
    $img = Resolve-GIApiImage $Req; if ($img.Error) { return $img.Error }
    $snap = ([string](Get-GIBodyValue $Req.Body 'snapshot' '')).Trim()
    if (-not $snap -or $snap -notmatch '^[\w .:()-]{1,80}$') { return (New-GIApiError 400 'Pick a snapshot to revert to.') }
    if (Test-GIImageBusy -ImageConfig $img.Config) { return (New-GIApiError 409 'A run is active. Revert is blocked until it finishes.') }
    $r = Invoke-GIVmAction -ImageConfig $img.Config -Action revert -Snapshot $snap -Invoker (Get-GIOpt $Req 'LiveInvoker')
    Write-GIApiAudit -Req $Req -Action 'vm.revert' -Target $img.Config.GoldenImage.VmName -Detail @{ image = $img.Id; snapshot = $snap } -Result $(if ($r.Ok) { 'OK' } else { 'Failed' }) -ImageConfig $img.Config
    if (-not $r.Ok) { return (New-GIApiError 502 $r.Error) }
    @{ Code = 200; Body = [ordered]@{ revertedTo = $snap } }
}

function Invoke-GIApiRollback {
    param($Req)
    $img = Resolve-GIApiImage $Req; if ($img.Error) { return $img.Error }
    $pool = [string]$Req.Args['pool']
    if ((Get-GIConfigPoolNames -Config $img.Config) -notcontains $pool) { return (New-GIApiError 404 "Pool '$pool' does not belong to this image.") }
    $snap = ([string](Get-GIBodyValue $Req.Body 'snapshot' '')).Trim()
    if ($snap -and $snap -notmatch '^[\w .:()-]{1,80}$') { return (New-GIApiError 400 'Snapshot name is not valid.') }
    $policy = ([string](Get-GIBodyValue $Req.Body 'logoffPolicy' 'WAIT_FOR_LOGOFF')).ToUpperInvariant()
    if ($policy -notin 'WAIT_FOR_LOGOFF', 'FORCE_LOGOFF') { return (New-GIApiError 400 'Logoff policy must be WAIT_FOR_LOGOFF or FORCE_LOGOFF.') }
    $startTime = Get-Date
    $at = Get-GIBodyValue $Req.Body 'startTime' $null
    if ($at) { try { $startTime = [datetime]::Parse([string]$at, [cultureinfo]::InvariantCulture) } catch { return (New-GIApiError 400 'Start time is not a valid date and time.') } }
    if ($startTime -lt (Get-Date).AddMinutes(-1)) { return (New-GIApiError 400 'Start time is in the past.') }
    $runId = [string](Get-GIBodyValue $Req.Body 'runId' '')
    if ($runId -and -not (Test-GIRunId $runId)) { return (New-GIApiError 400 'Bad run id.') }
    $p = @{ Config = $img.Config; PoolName = $pool; StartTime = $startTime; ForceLogoff = ($policy -eq 'FORCE_LOGOFF') }
    if ($snap) { $p.SnapshotName = $snap }
    if ($runId) { $p.RunId = $runId }
    $runner = if ((Get-GIOpt $Req 'RollbackRunner')) { (Get-GIOpt $Req 'RollbackRunner') } else { { param($a) Connect-GIServices -Config $a.Config -SkipAppVolumes; try { Invoke-GIRollback @a } finally { Disconnect-GIServices } } }
    try { $res = & $runner $p } catch {
        Write-GIApiAudit -Req $Req -Action 'pool.rollback' -Target $pool -Detail @{ image = $img.Id; snapshot = $snap; error = $_.Exception.Message } -Result 'Failed' -ImageConfig $img.Config
        return (New-GIApiError 502 $_.Exception.Message)
    }
    Write-GIApiAudit -Req $Req -Action 'pool.rollback' -Target $pool -Detail @{ image = $img.Id; snapshot = [string]$res.SnapshotName; logoffPolicy = $policy; startTime = $startTime.ToString('o'); runId = $runId } -ImageConfig $img.Config
    @{ Code = 200; Body = [ordered]@{ pool = $pool; snapshot = [string]$res.SnapshotName; logoffPolicy = $policy; startTime = $startTime.ToString('o') } }
}

function Get-GIApiInventory {
    <# VMs from vCenter and pools from Horizon, each with the image that already uses it. Admin only (wizard). #>
    param($Req)
    $entries = @(Get-GIImageEntries -Config $Req.Config)
    $usedVm = @{}; $usedPool = @{}
    foreach ($e in $entries) {
        $usedVm[([string]$e.GoldenImage.VmName).ToLowerInvariant()] = $e.Name
        foreach ($p in (Get-GIImagePoolNames $e)) { $usedPool[$p.ToLowerInvariant()] = $e.Name }
    }
    $cfg = $Req.Config
    $vcWork = {
        param($c)
        $srv = $c.vCenter.Server
        if (-not @($global:DefaultVIServers | Where-Object { $_.IsConnected -and $_.Name -eq $srv })) { Connect-VIServer -Server $srv -Credential (Get-GISecretCredential -Name $c.vCenter.CredentialSecret) -ErrorAction Stop | Out-Null }
        , @(Get-VM -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ name = $_.Name; power = [string]$_.PowerState; os = [string]$_.Guest.OSFullName; snapshots = @(Get-Snapshot -VM $_ -ErrorAction SilentlyContinue).Count } })
    }
    $hzWork = {
        param($c)
        if (-not $global:GILiveHzAt -or ((Get-Date) - $global:GILiveHzAt).TotalMinutes -gt 10) { Connect-GIHorizon -Config $c; $global:GILiveHzAt = Get-Date }
        , @(Get-GIHorizonPools | ForEach-Object { [pscustomobject]@{ name = [string]$_.name } })
    }
    $inv = if (Get-GIOpt $Req 'LiveInvoker') { Get-GIOpt $Req 'LiveInvoker' } else { { param($n, $w, $a, $t) Invoke-GILiveSource -Name $n -Work $w -ArgumentList $a -TimeoutSec $t } }
    $vc = & $inv 'vCenter' $vcWork @($cfg) 15
    $hz = & $inv 'Horizon' $hzWork @($cfg) 15
    @{ Code = 200; Body = [ordered]@{
            vms = @(if ($vc.Ok) { @($vc.Data) | ForEach-Object { [ordered]@{ name = $_.name; power = $_.power; os = $_.os; snapshots = $_.snapshots; usedBy = [string]$usedVm[([string]$_.name).ToLowerInvariant()] } } })
            pools = @(if ($hz.Ok) { @($hz.Data) | ForEach-Object { [ordered]@{ name = $_.name; usedBy = [string]$usedPool[([string]$_.name).ToLowerInvariant()] } } })
            errors = @(@(if (-not $vc.Ok) { $vc.Error }) + @(if (-not $hz.Ok) { $hz.Error }))
        } }
}
