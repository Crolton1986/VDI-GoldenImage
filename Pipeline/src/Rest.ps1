#----------------[ Horizon + App Volumes REST helpers ]----------------
# Horizon: token auth (POST /rest/login, refresh on 401, POST /rest/logout).
# App Volumes Manager: cookie session (POST <Endpoints.Session>).
# Endpoint paths for App Volumes are config-driven because they differ between releases.

$script:GIHorizon = $null
$script:GIAppVol  = $null

function Invoke-GIRestWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Request,
        [int] $MaxAttempts = 3,
        [int] $DelaySeconds = 5
    )
    for ($attempt = 1; ; $attempt++) {
        try {
            return Invoke-RestMethod @Request -ErrorAction Stop
        } catch {
            $code = $null
            if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
                $code = [int]$_.Exception.Response.StatusCode
            }
            # Retry only on transient failures: no response, 429, or 5xx
            $transient = ($null -eq $code) -or ($code -eq 429) -or ($code -ge 500)
            if (-not $transient -or $attempt -ge $MaxAttempts) { throw }
            Start-Sleep -Seconds ($DelaySeconds * $attempt)
        }
    }
}

#----- Horizon -----

function Connect-GIHorizon {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config)

    $hz   = $Config.Horizon
    $cred = Get-GISecretCredential -Name $hz.CredentialSecret
    $base = "https://$($hz.Server)/rest"
    $body = @{
        domain   = $hz.Domain
        username = $cred.UserName
        password = $cred.GetNetworkCredential().Password
    } | ConvertTo-Json

    $req = @{ Uri = "$base/login"; Method = 'Post'; Body = $body; ContentType = 'application/json' }
    if ($hz.SkipCertificateCheck) { $req.SkipCertificateCheck = $true }
    $tok = Invoke-GIRestWithRetry -Request $req

    $script:GIHorizon = @{
        BaseUri      = $base
        AccessToken  = $tok.access_token
        RefreshToken = $tok.refresh_token
        SkipCert     = [bool]$hz.SkipCertificateCheck
    }
}

function Disconnect-GIHorizon {
    [CmdletBinding()]
    param()
    if (-not $script:GIHorizon) { return }
    try {
        $req = @{
            Uri = "$($script:GIHorizon.BaseUri)/logout"; Method = 'Post'; ContentType = 'application/json'
            Body = (@{ refresh_token = $script:GIHorizon.RefreshToken } | ConvertTo-Json)
        }
        if ($script:GIHorizon.SkipCert) { $req.SkipCertificateCheck = $true }
        Invoke-RestMethod @req -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "Horizon logout failed: $($_.Exception.Message)"
    }
    $script:GIHorizon = $null
}

function Update-GIHorizonToken {
    [CmdletBinding()]
    param()
    $req = @{
        Uri = "$($script:GIHorizon.BaseUri)/refresh"; Method = 'Post'; ContentType = 'application/json'
        Body = (@{ refresh_token = $script:GIHorizon.RefreshToken } | ConvertTo-Json)
    }
    if ($script:GIHorizon.SkipCert) { $req.SkipCertificateCheck = $true }
    $tok = Invoke-RestMethod @req -ErrorAction Stop
    $script:GIHorizon.AccessToken = $tok.access_token
}

function Invoke-GIHorizonApi {
    <#
    .SYNOPSIS
      Calls the Horizon REST API. Path is relative to /rest, e.g. '/inventory/v1/desktop-pools'.
      GET requests with -All page through results (page/size query params).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [ValidateSet('Get','Post','Put','Patch','Delete')] [string] $Method = 'Get',
        [object] $Body,
        [hashtable] $Query,
        [switch] $All,
        [int] $PageSize = 500
    )
    if (-not $script:GIHorizon) { throw "Not connected to Horizon. Call Connect-GIHorizon first." }

    $send = {
        param($q)
        $uri = "$($script:GIHorizon.BaseUri)$Path"
        if ($q -and $q.Count) {
            $pairs = foreach ($k in $q.Keys) { '{0}={1}' -f $k, [uri]::EscapeDataString([string]$q[$k]) }
            $uri += '?' + ($pairs -join '&')
        }
        $req = @{
            Uri = $uri; Method = $Method
            Headers = @{ Authorization = "Bearer $($script:GIHorizon.AccessToken)" }
        }
        if ($null -ne $Body) { $req.Body = ($Body | ConvertTo-Json -Depth 10); $req.ContentType = 'application/json' }
        if ($script:GIHorizon.SkipCert) { $req.SkipCertificateCheck = $true }
        try {
            Invoke-GIRestWithRetry -Request $req
        } catch {
            $code = if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { [int]$_.Exception.Response.StatusCode }
            if ($code -ne 401) { throw }
            # Access token expired (30 min lifetime): refresh once and retry
            Update-GIHorizonToken
            $req.Headers.Authorization = "Bearer $($script:GIHorizon.AccessToken)"
            Invoke-GIRestWithRetry -Request $req
        }
    }

    if (-not $All) { return (& $send $Query) }

    $results = [System.Collections.Generic.List[object]]::new()
    for ($page = 1; ; $page++) {
        $q = @{}; if ($Query) { $q += $Query }
        $q.page = $page; $q.size = $PageSize
        $batch = @(& $send $q)
        foreach ($item in $batch) { $results.Add($item) }
        if ($batch.Count -lt $PageSize) { break }
    }
    return $results.ToArray()
}

function ConvertTo-GIHorizonFilter {
    # Builds the URL 'filter' JSON for an Equals match, e.g. desktop_pool_id = X
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [string] $Value)
    return (@{ type = 'Equals'; name = $Name; value = $Value } | ConvertTo-Json -Compress)
}

function Get-GIHorizonPool {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Name)
    $pool = Invoke-GIHorizonApi -Path '/inventory/v1/desktop-pools' -All |
        Where-Object { $_.name -eq $Name -or $_.display_name -eq $Name } | Select-Object -First 1
    if (-not $pool) { throw "Horizon desktop pool '$Name' not found." }
    return $pool
}

function Get-GIHorizonPools {
    [CmdletBinding()]
    param()
    return Invoke-GIHorizonApi -Path '/inventory/v1/desktop-pools' -All
}

function Get-GIHorizonPoolMachines {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $PoolId)
    $filter = ConvertTo-GIHorizonFilter -Name 'desktop_pool_id' -Value $PoolId
    return Invoke-GIHorizonApi -Path '/inventory/v1/machines' -Query @{ filter = $filter } -All
}

function Get-GIHorizonVCenterId {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config)
    $vcs = @(Invoke-GIHorizonApi -Path '/config/v1/virtual-centers')
    $vc = $vcs | Where-Object { $_.server_name -eq $Config.vCenter.Server } | Select-Object -First 1
    if (-not $vc) {
        if ($vcs.Count -eq 1) { $vc = $vcs[0] } else { throw "vCenter '$($Config.vCenter.Server)' not registered in Horizon." }
    }
    return $vc.id
}

function Get-GIHorizonBaseImage {
    <#
    .SYNOPSIS
      Resolves Horizon's IDs for the golden VM and (optionally) one of its snapshots.
      Horizon uses its own IDs, not vCenter MoRefs, in push-image calls.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [string] $SnapshotName
    )
    $vcId = Get-GIHorizonVCenterId -Config $Config
    $baseVm = Invoke-GIHorizonApi -Path '/external/v1/base-vms' -Query @{ vcenter_id = $vcId } |
        Where-Object { $_.name -eq $Config.GoldenImage.VmName } | Select-Object -First 1
    if (-not $baseVm) { throw "Golden VM '$($Config.GoldenImage.VmName)' not visible to Horizon as a base VM." }

    $snaps = @(Invoke-GIHorizonApi -Path '/external/v1/base-snapshots' -Query @{ vcenter_id = $vcId; base_vm_id = $baseVm.id })
    $snap = $null
    if ($SnapshotName) {
        $snap = $snaps | Where-Object { $_.name -eq $SnapshotName } | Select-Object -First 1
        if (-not $snap) { throw "Snapshot '$SnapshotName' not visible to Horizon on '$($Config.GoldenImage.VmName)'." }
    }
    [pscustomobject]@{ VCenterId = $vcId; BaseVm = $baseVm; Snapshot = $snap; AllSnapshots = $snaps }
}

function Get-GIPoolImageInfo {
    <#
    .SYNOPSIS
      Normalizes the parts of a desktop pool object the pipeline cares about.
      Field names follow inventory/v1; missing fields come back as $null.
    #>
    param([Parameter(Mandatory)] $Pool)
    $ps  = if ($Pool.PSObject.Properties['provisioning_settings']) { $Pool.provisioning_settings }
    $psd = if ($Pool.PSObject.Properties['provisioning_status_data']) { $Pool.provisioning_status_data }
    $get = { param($o, $n) if ($o -and $o.PSObject.Properties[$n]) { $o.$n } }
    [pscustomobject]@{
        PoolId              = $Pool.id
        Name                = $Pool.name
        ParentVmId          = & $get $ps 'parent_vm_id'
        SnapshotId          = & $get $ps 'base_snapshot_id'
        PendingParentVmId   = & $get $psd 'instant_clone_pending_image_parent_vm_id'
        PendingSnapshotId   = & $get $psd 'instant_clone_pending_image_snapshot_id'
        PendingImageState   = & $get $psd 'instant_clone_pending_image_state'
        Operation           = & $get $psd 'instant_clone_operation'
        CurrentImageState   = & $get $psd 'instant_clone_current_image_state'
        PendingImageProgress = & $get $psd 'instant_clone_pending_image_progress'
    }
}

function Invoke-GIHorizonPushImage {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $PoolId,
        [Parameter(Mandatory)] [string] $ParentVmId,
        [Parameter(Mandatory)] [string] $SnapshotId,
        [Parameter(Mandatory)] [datetime] $StartTime,
        [ValidateSet('FORCE_LOGOFF','WAIT_FOR_LOGOFF')] [string] $LogoffPolicy = 'WAIT_FOR_LOGOFF',
        [bool] $StopOnFirstError = $true
    )
    $body = @{
        parent_vm_id        = $ParentVmId
        snapshot_id         = $SnapshotId
        start_time          = ([DateTimeOffset]$StartTime).ToUnixTimeMilliseconds()
        logoff_policy       = $LogoffPolicy
        stop_on_first_error = $StopOnFirstError
    }
    if ($PSCmdlet.ShouldProcess($PoolId, "Schedule push image at $StartTime")) {
        Invoke-GIHorizonApi -Path "/inventory/v1/desktop-pools/$PoolId/action/schedule-push-image" -Method Post -Body $body | Out-Null
    }
}

function Stop-GIHorizonPushImage {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $PoolId)
    if ($PSCmdlet.ShouldProcess($PoolId, 'Cancel scheduled push image')) {
        Invoke-GIHorizonApi -Path "/inventory/v1/desktop-pools/$PoolId/action/cancel-scheduled-push-image" -Method Post | Out-Null
    }
}

#----- App Volumes Manager -----

function Get-GIAppVolEndpoint {
    param([Parameter(Mandatory)] [hashtable] $Config, [Parameter(Mandatory)] [string] $Name)
    $defaults = @{
        Session        = '/app_volumes/sessions'
        OnlineEntities = '/app_volumes/online_entities'
        Attachments    = '/app_volumes/app_attachments'
    }
    $ep = $Config.AppVolumes['Endpoints']
    if ($ep -and $ep[$Name]) { return $ep[$Name] }
    return $defaults[$Name]
}

function Connect-GIAppVol {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config)
    $av   = $Config.AppVolumes
    $cred = Get-GISecretCredential -Name $av.CredentialSecret
    $base = "https://$($av.Server)"
    $sess = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $req = @{
        Uri = $base + (Get-GIAppVolEndpoint -Config $Config -Name Session); Method = 'Post'
        ContentType = 'application/json'; WebSession = $sess
        Body = (@{ username = $cred.UserName; password = $cred.GetNetworkCredential().Password } | ConvertTo-Json)
    }
    if ($av.SkipCertificateCheck) { $req.SkipCertificateCheck = $true }
    Invoke-GIRestWithRetry -Request $req | Out-Null
    $script:GIAppVol = @{ BaseUri = $base; Session = $sess; SkipCert = [bool]$av.SkipCertificateCheck }
}

function Invoke-GIAppVolApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [ValidateSet('Get','Post','Put','Delete')] [string] $Method = 'Get',
        [object] $Body
    )
    if (-not $script:GIAppVol) { throw "Not connected to App Volumes Manager. Call Connect-GIAppVol first." }
    $req = @{ Uri = "$($script:GIAppVol.BaseUri)$Path"; Method = $Method; WebSession = $script:GIAppVol.Session }
    if ($null -ne $Body) { $req.Body = ($Body | ConvertTo-Json -Depth 10); $req.ContentType = 'application/json' }
    if ($script:GIAppVol.SkipCert) { $req.SkipCertificateCheck = $true }
    return Invoke-GIRestWithRetry -Request $req
}

function Get-GIAppVolCollection {
    <#
    .SYNOPSIS
      AVM responses wrap arrays in a property named after the collection (e.g. { "online": { "records": [...] } }
      or { "data": [...] }). Returns the first array found, searching two levels deep.
    #>
    param($Response)
    if ($null -eq $Response) { return @() }
    if ($Response -is [array]) { return $Response }
    foreach ($p in $Response.PSObject.Properties) {
        if ($p.Value -is [array]) { return $p.Value }
        if ($p.Value -is [pscustomobject]) {
            foreach ($q in $p.Value.PSObject.Properties) { if ($q.Value -is [array]) { return $q.Value } }
        }
    }
    return @()
}
