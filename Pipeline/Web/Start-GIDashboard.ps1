<#
.SYNOPSIS
    Read-only Pode dashboard for the golden image pipeline.
.DESCRIPTION
    Server-rendered HTML. State is read via the module (Get-GIConfig, Get-GIRunList, Get-GIRun,
    Get-GILastKnownGood); nothing is written and Horizon is never queried.
.PARAMETER ConfigPath
    Optional pipeline config file (defaults to pipeline.config.psd1 next to the module).
.PARAMETER Port
    Listen port (default Dashboard.Port from config).
.PARAMETER NoTls
    Serve plain http (lab/testing). Without it, Dashboard.CertificateThumbprint is used for https.
.PARAMETER NoAuth
    Skip AD authentication (lab/testing, and non-Windows hosts). The dashboard is then strictly
    read-only: approve/reject is disabled.
.NOTES
    Auth: HTTP Basic over HTTPS, validated against Active Directory (Windows host only).
    Viewers = members of Dashboard.ViewerGroup or Dashboard.ApproverGroup.
    Approve/Reject = members of Dashboard.ApproverGroup only. Forms carry a per-user, per-run
    HMAC token and the Origin header is checked, so a third-party page can't submit them.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [int]$Port,
    [switch]$NoTls,
    [switch]$NoAuth
)

$ErrorActionPreference = 'Stop'
$webRoot = $PSScriptRoot
$pipelineRoot = Split-Path -Parent $webRoot
$manifest = Join-Path $pipelineRoot 'VDI-GIPipeline.psd1'

Import-Module $manifest -Force
Import-Module Pode -MaximumVersion 2.99.99 -ErrorAction Stop

$configArgs = @{}
if ($ConfigPath) { $configArgs.Path = $ConfigPath }
$config = Get-GIConfig @configArgs
$dash = $config.Dashboard
if (-not $dash) { $dash = @{} }
if (-not $PSBoundParameters.ContainsKey('Port')) { $Port = if ($dash.Port) { [int]$dash.Port } else { 8443 } }
$refresh = if ($dash.RefreshSeconds) { [int]$dash.RefreshSeconds } else { 20 }
$thumb = [string]$dash.CertificateThumbprint

# Shared context for all routes (also the hook for the future auth/approval code).
$script:DashboardContext = @{
    Config         = $config
    RefreshSeconds = $refresh
    ViewerGroup    = [string]$dash.ViewerGroup
    ApproverGroup  = [string]$dash.ApproverGroup
    ManifestPath   = $manifest
    ViewsPath      = Join-Path $webRoot 'DashboardViews.ps1'
    NoAuth         = [bool]$NoAuth
    # Pode returns group names without the domain prefix
    ApproverShort  = ([string]$dash.ApproverGroup -split '\\')[-1]
    ViewerShort    = ([string]$dash.ViewerGroup -split '\\')[-1]
    FormSecret     = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
}
if (-not $NoAuth -and -not $IsWindows) { throw 'AD authentication needs a Windows host. Use -NoAuth for a read-only lab dashboard.' }
if (-not $NoAuth -and $NoTls) { Write-Warning 'Basic auth over plain http sends passwords in clear text. Use https outside the lab.' }

$ctx = $script:DashboardContext
$viewsPath = $ctx.ViewsPath

Start-PodeServer -Quiet {
    # Make the context, module and view functions available in every route runspace.
    Set-PodeState -Name 'GIContext' -Value $ctx | Out-Null
    Import-PodeModule -Path $manifest
    Use-PodeScript -Path $viewsPath

    # --- Endpoint ---
    if ($NoTls) {
        Add-PodeEndpoint -Address * -Port $Port -Protocol Http
    } elseif ($thumb) {
        Add-PodeEndpoint -Address * -Port $Port -Protocol Https -CertificateThumbprint $thumb
    } else {
        throw 'Dashboard.CertificateThumbprint is empty. Configure a certificate or start with -NoTls (lab only).'
    }

    # --- Authentication ---
    $auth = @{}
    if (-not $ctx.NoAuth) {
        $groups = @($ctx.ViewerShort, $ctx.ApproverShort) | Where-Object { $_ } | Select-Object -Unique
        if (-not $groups) { throw 'Dashboard.ViewerGroup / ApproverGroup must be set when authentication is on.' }
        New-PodeAuthScheme -Basic -Realm 'VDI Golden Image Pipeline' |
            Add-PodeAuthWindowsAd -Name 'AD' -Groups $groups -Sessionless
        $auth = @{ Authentication = 'AD' }
    }

    Add-PodeRoute -Method Get -Path '/' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        $runs = @(Get-GIRunList -Config $c.Config -Last 50)
        Write-PodeHtmlResponse -Value (New-GIRunListPage -Runs $runs -RefreshSeconds $c.RefreshSeconds)
    }

    Add-PodeRoute -Method Get -Path '/runs/:runId' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        $id = $WebEvent.Parameters['runId']
        if (-not (Test-GIRunId $id) -or -not (Test-Path -LiteralPath (Join-Path $c.Config.Paths.State "$id.json"))) {
            Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message 'Run not found.') -StatusCode 404
            return
        }
        $run = Get-GIRun -Config $c.Config -RunId $id
        $form = ''
        $refresh = $c.RefreshSeconds
        $user = Get-GIDashboardUser -Context $c -WebEvent $WebEvent
        if ($run.status -eq 'AwaitingApproval' -and (Test-GIDashboardApprover -Context $c -WebEvent $WebEvent)) {
            $token = Get-GIFormToken -Secret $c.FormSecret -User $user -RunId $id
            $form = New-GIApprovalForm -RunId $id -Token $token -DefaultStart (Get-GINextMaintenanceWindow -Config $c.Config)
            $refresh = 0   # don't wipe a half-filled form
        }
        $notice = switch ($WebEvent.Query['result']) {
            'approved' { 'Approved. Production push scheduled.' }
            'rejected' { 'Run rejected.' }
            default { '' }
        }
        Write-PodeHtmlResponse -Value (New-GIRunDetailPage -Run $run -RefreshSeconds $refresh -ApprovalFormHtml $form -NoticeHtml $notice)
    }

    Add-PodeRoute -Method Post -Path '/runs/:runId/decision' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        $id = $WebEvent.Parameters['runId']
        $deny = { param($code, $msg) Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message $msg) -StatusCode $code }
        if ($c.NoAuth) { & $deny 403 'Approvals are disabled when the dashboard runs without authentication.'; return }
        if (-not (Test-GIRunId $id)) { & $deny 404 'Run not found.'; return }
        if (-not (Test-GIDashboardApprover -Context $c -WebEvent $WebEvent)) { & $deny 403 'You are not in the approver group.'; return }
        # Same-origin check (browsers send Origin on POST); token check covers clients that omit it
        $origin = $WebEvent.Request.Headers['Origin']
        $hostHdr = $WebEvent.Request.Headers['Host']
        if ($origin -and ([uri]$origin).Authority -ne $hostHdr) { & $deny 403 'Cross-origin request refused.'; return }
        $user = Get-GIDashboardUser -Context $c -WebEvent $WebEvent
        if (-not (Test-GIFormToken -Secret $c.FormSecret -User $user -RunId $id -Token ([string]$WebEvent.Data['token']))) {
            & $deny 403 'Form expired or invalid. Reload the run page and try again.'; return
        }
        $comment = [string]$WebEvent.Data['comment']
        if ($comment.Length -gt 500) { $comment = $comment.Substring(0, 500) }
        try {
            if ($WebEvent.Data['decision'] -eq 'approve') {
                $start = [datetime]::ParseExact([string]$WebEvent.Data['startTime'], 'yyyy-MM-ddTHH:mm', [cultureinfo]::InvariantCulture)
                Approve-GIRun -Config $c.Config -RunId $id -By $user -StartTime $start -Comment $comment | Out-Null
                Move-PodeResponseUrl -Url "/runs/$id?result=approved"
            } elseif ($WebEvent.Data['decision'] -eq 'reject') {
                Deny-GIRun -Config $c.Config -RunId $id -By $user -Comment $comment | Out-Null
                Move-PodeResponseUrl -Url "/runs/$id?result=rejected"
            } else {
                & $deny 400 'Unknown decision.'
            }
        } catch {
            & $deny 409 "Not done: $($_.Exception.Message)"
        }
    }

    Add-PodeRoute -Method Get -Path '/reports/:runId' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        $id = $WebEvent.Parameters['runId']
        $file = if (Test-GIRunId $id) { Join-Path $c.Config.Paths.Reports "$id.html" }
        if (-not $file -or -not (Test-Path -LiteralPath $file -PathType Leaf)) {
            Write-PodeHtmlResponse -Value (New-GINotFoundPage -Message 'Report not found.') -StatusCode 404
            return
        }
        # Reports are generated HTML; lock down what they may load.
        Add-PodeHeader -Name 'Content-Security-Policy' -Value "default-src 'none'; style-src 'unsafe-inline'; img-src data:"
        Write-PodeHtmlResponse -Value (Get-Content -LiteralPath $file -Raw -Encoding UTF8)
    }

    Add-PodeRoute -Method Get -Path '/logs/:runId' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        $id = $WebEvent.Parameters['runId']
        $file = if (Test-GIRunId $id) { Join-Path $c.Config.Paths.Logs "$id.log" }
        if (-not $file -or -not (Test-Path -LiteralPath $file -PathType Leaf)) {
            Write-PodeTextResponse -Value 'Log not found.' -ContentType 'text/plain' -StatusCode 404
            return
        }
        $text = (Get-Content -LiteralPath $file -Tail 2000 -Encoding UTF8) -join "`n"
        Write-PodeTextResponse -Value $text -ContentType 'text/plain'
    }

    Add-PodeRoute -Method Get -Path '/pools' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        $runs = @(Get-GIRunList -Config $c.Config -Last 50)
        $lkg = Get-GILastKnownGood -Config $c.Config
        Write-PodeHtmlResponse -Value (New-GIPoolsPage -LastKnownGood $lkg -Runs $runs -TestPoolName ([string]$c.Config.Pools.Test.Name) -RefreshSeconds $c.RefreshSeconds)
    }

    Add-PodeRoute -Method Get -Path '/api/runs' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        $runs = @(Get-GIRunList -Config $c.Config -Last 50)
        Write-PodeJsonResponse -Value (ConvertTo-Json -InputObject $runs -Depth 10)
    }

    Add-PodeRoute -Method Get -Path '/api/runs/:runId' @auth -ScriptBlock {
        $c = (Get-PodeState -Name 'GIContext')
        $id = $WebEvent.Parameters['runId']
        if (-not (Test-GIRunId $id) -or -not (Test-Path -LiteralPath (Join-Path $c.Config.Paths.State "$id.json"))) {
            Write-PodeJsonResponse -Value '{"error":"Run not found"}' -StatusCode 404
            return
        }
        Write-PodeJsonResponse -Value (ConvertTo-Json -InputObject (Get-GIRun -Config $c.Config -RunId $id) -Depth 10)
    }
}
