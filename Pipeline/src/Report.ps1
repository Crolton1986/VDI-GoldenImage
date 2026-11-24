#Requires -Version 7.2
# Report.ps1 - HTML run report (Outlook-safe: tables + inline CSS) and email delivery.

function ConvertTo-GIHtmlText {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-GIPropValue {
    [CmdletBinding()]
    param([AllowNull()] $Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-GIStatusColor {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Status)
    switch ($Status) {
        'Succeeded'        { '#2e7d32' }
        'Completed'        { '#2e7d32' }
        'Scheduled'        { '#1565c0' }
        'InProgress'       { '#1565c0' }
        'Running'          { '#1565c0' }
        'AwaitingApproval' { '#ef6c00' }
        'Approved'         { '#2e7d32' }
        'Failed'           { '#c62828' }
        'Rejected'         { '#c62828' }
        'RolledBack'       { '#6a1b9a' }
        'Cancelled'        { '#757575' }
        'Skipped'          { '#757575' }
        'Pending'          { '#9e9e9e' }
        default            { '#9e9e9e' }
    }
}

function Get-GIBadge {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Status)
    $color = Get-GIStatusColor -Status $Status
    $text = ConvertTo-GIHtmlText $Status
    return "<span style=`"background-color:$color;color:#ffffff;padding:2px 8px;font-weight:bold;font-size:12px;`">$text</span>"
}

function Format-GIDuration {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Start, [AllowNull()]$End)
    if (-not $Start -or -not $End) { return '' }
    try {
        $s = [datetimeoffset]::Parse([string]$Start, [cultureinfo]::InvariantCulture)
        $e = [datetimeoffset]::Parse([string]$End, [cultureinfo]::InvariantCulture)
        $span = $e - $s
        if ($span.TotalSeconds -lt 0) { return '' }
        return ('{0:00}:{1:00}:{2:00}' -f [int][math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds)
    }
    catch { return '' }
}

function ConvertTo-GIReportHtml {
    <#
    .SYNOPSIS
    Renders a run state object as a self-contained, Outlook-friendly HTML document.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()] $Run)

    $enc = { param($v) ConvertTo-GIHtmlText $v }
    $th = 'style="text-align:left;background-color:#eceff1;padding:4px 8px;border:1px solid #cfd8dc;font-size:13px;"'
    $td = 'style="padding:4px 8px;border:1px solid #cfd8dc;font-size:13px;vertical-align:top;"'
    $h2 = 'style="font-family:Segoe UI,Arial,sans-serif;font-size:16px;margin:20px 0 6px 0;color:#263238;"'
    $tbl = 'cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;width:100%;font-family:Segoe UI,Arial,sans-serif;"'

    $runId = Get-GIPropValue $Run 'runId'
    $vm = Get-GIPropValue $Run 'goldenVm'
    $status = Get-GIPropValue $Run 'status'

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html><head><meta charset="utf-8">')
    [void]$sb.AppendLine("<title>VDI Pipeline $(& $enc $runId)</title>")
    [void]$sb.AppendLine('</head>')
    [void]$sb.AppendLine('<body style="margin:0;padding:16px;background-color:#ffffff;font-family:Segoe UI,Arial,sans-serif;color:#263238;">')
    [void]$sb.AppendLine('<table width="800" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;max-width:800px;"><tr><td>')

    # Header
    [void]$sb.AppendLine("<h1 style=`"font-size:20px;margin:0 0 8px 0;`">Golden image pipeline run $(& $enc $runId)</h1>")
    [void]$sb.AppendLine("<table $tbl>")
    [void]$sb.AppendLine("<tr><th $th width=`"150`">Run ID</th><td $td>$(& $enc $runId)</td></tr>")
    [void]$sb.AppendLine("<tr><th $th>Golden VM</th><td $td>$(& $enc $vm)</td></tr>")
    [void]$sb.AppendLine("<tr><th $th>Status</th><td $td>$(Get-GIBadge $status)</td></tr>")
    $createdAt = Get-GIPropValue $Run 'createdAt'
    $updatedAt = Get-GIPropValue $Run 'updatedAt'
    if ($createdAt) { [void]$sb.AppendLine("<tr><th $th>Created</th><td $td>$(& $enc $createdAt)</td></tr>") }
    if ($updatedAt) { [void]$sb.AppendLine("<tr><th $th>Updated</th><td $td>$(& $enc $updatedAt)</td></tr>") }
    [void]$sb.AppendLine('</table>')

    # Snapshot
    $snap = Get-GIPropValue $Run 'snapshot'
    if ($snap) {
        [void]$sb.AppendLine("<h2 $h2>Snapshot</h2>")
        [void]$sb.AppendLine("<table $tbl>")
        [void]$sb.AppendLine("<tr><th $th width=`"150`">Name</th><td $td>$(& $enc (Get-GIPropValue $snap 'name'))</td></tr>")
        $snapAt = Get-GIPropValue $snap 'createdAt'
        if ($snapAt) { [void]$sb.AppendLine("<tr><th $th>Created</th><td $td>$(& $enc $snapAt)</td></tr>") }
        [void]$sb.AppendLine('</table>')
        $manifest = Get-GIPropValue $snap 'manifest'
        if ($manifest) {
            $entries = if ($manifest -is [System.Collections.IDictionary]) {
                $manifest.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = $_.Key; Value = $_.Value } }
            }
            else {
                $manifest.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } }
            }
            $entries = @($entries)
            if ($entries.Count -gt 0) {
                [void]$sb.AppendLine("<p style=`"font-size:13px;margin:10px 0 4px 0;font-weight:bold;`">Manifest</p>")
                [void]$sb.AppendLine("<table $tbl><tr><th $th>Component</th><th $th>Version</th></tr>")
                foreach ($e in $entries) {
                    [void]$sb.AppendLine("<tr><td $td>$(& $enc $e.Name)</td><td $td>$(& $enc $e.Value)</td></tr>")
                }
                [void]$sb.AppendLine('</table>')
            }
        }
    }

    # Stages
    $stages = Get-GIPropValue $Run 'stages'
    if ($stages) {
        $order = 'Preflight', 'Maintain', 'Snapshot', 'TestPush', 'Validate', 'Approval', 'Promote', 'PostCheck'
        $names = if ($stages -is [System.Collections.IDictionary]) { @($stages.Keys) } else { @($stages.PSObject.Properties.Name) }
        $sorted = @($order | Where-Object { $_ -in $names }) + @($names | Where-Object { $_ -notin $order })
        [void]$sb.AppendLine("<h2 $h2>Stages</h2>")
        [void]$sb.AppendLine("<table $tbl><tr><th $th>Stage</th><th $th>Status</th><th $th>Started</th><th $th>Ended</th><th $th>Duration</th><th $th>Message</th></tr>")
        foreach ($n in $sorted) {
            $st = Get-GIPropValue $stages $n
            $started = Get-GIPropValue $st 'startedAt'
            $ended = Get-GIPropValue $st 'endedAt'
            [void]$sb.AppendLine("<tr><td $td>$(& $enc $n)</td><td $td>$(Get-GIBadge (Get-GIPropValue $st 'status'))</td><td $td>$(& $enc $started)</td><td $td>$(& $enc $ended)</td><td $td>$(& $enc (Format-GIDuration $started $ended))</td><td $td>$(& $enc (Get-GIPropValue $st 'message'))</td></tr>")
        }
        [void]$sb.AppendLine('</table>')
    }

    # Validation
    $val = Get-GIPropValue $Run 'validation'
    $checks = @(Get-GIPropValue $val 'checks')
    $checks = @($checks | Where-Object { $null -ne $_ })
    if ($val -and $checks.Count -gt 0) {
        [void]$sb.AppendLine("<h2 $h2>Validation</h2>")
        $anyFail = @($checks | Where-Object { -not (Get-GIPropValue $_ 'passed') }).Count -gt 0
        $overall = (Get-GIPropValue $val 'passed') -and -not $anyFail
        $oc = if ($overall) { '#2e7d32' } else { '#c62828' }
        $ot = if ($overall) { 'PASSED' } else { 'FAILED' }
        [void]$sb.AppendLine("<p style=`"font-size:14px;font-weight:bold;color:$oc;margin:4px 0;`">Overall: $ot</p>")
        $groups = $checks | Group-Object { [string](Get-GIPropValue $_ 'category') }
        foreach ($g in $groups) {
            [void]$sb.AppendLine("<p style=`"font-size:13px;margin:10px 0 4px 0;font-weight:bold;`">$(& $enc $g.Name)</p>")
            [void]$sb.AppendLine("<table $tbl><tr><th $th>Check</th><th $th>Target</th><th $th>Result</th><th $th>Detail</th></tr>")
            foreach ($c in $g.Group) {
                $ok = [bool](Get-GIPropValue $c 'passed')
                $bg = if ($ok) { '#e8f5e9' } else { '#ffebee' }
                $fg = if ($ok) { '#2e7d32' } else { '#c62828' }
                $rt = if ($ok) { 'PASS' } else { 'FAIL' }
                [void]$sb.AppendLine("<tr style=`"background-color:$bg;`"><td $td>$(& $enc (Get-GIPropValue $c 'name'))</td><td $td>$(& $enc (Get-GIPropValue $c 'target'))</td><td $td><b style=`"color:$fg;`">$rt</b></td><td $td>$(& $enc (Get-GIPropValue $c 'detail'))</td></tr>")
            }
            [void]$sb.AppendLine('</table>')
        }
    }

    # Approval
    $appr = Get-GIPropValue $Run 'approval'
    if ($appr -and (Get-GIPropValue $appr 'decision')) {
        [void]$sb.AppendLine("<h2 $h2>Approval</h2>")
        [void]$sb.AppendLine("<table $tbl>")
        [void]$sb.AppendLine("<tr><th $th width=`"150`">Decision</th><td $td>$(Get-GIBadge (Get-GIPropValue $appr 'decision'))</td></tr>")
        [void]$sb.AppendLine("<tr><th $th>By</th><td $td>$(& $enc (Get-GIPropValue $appr 'by'))</td></tr>")
        [void]$sb.AppendLine("<tr><th $th>At</th><td $td>$(& $enc (Get-GIPropValue $appr 'at'))</td></tr>")
        [void]$sb.AppendLine("<tr><th $th>Start time</th><td $td>$(& $enc (Get-GIPropValue $appr 'startTime'))</td></tr>")
        [void]$sb.AppendLine("<tr><th $th>Comment</th><td $td>$(& $enc (Get-GIPropValue $appr 'comment'))</td></tr>")
        [void]$sb.AppendLine('</table>')
    }

    # Promotion
    $promo = Get-GIPropValue $Run 'promotion'
    $pools = @(Get-GIPropValue $promo 'pools') | Where-Object { $null -ne $_ }
    $pools = @($pools)
    if ($pools.Count -gt 0) {
        [void]$sb.AppendLine("<h2 $h2>Promotion</h2>")
        [void]$sb.AppendLine("<table $tbl><tr><th $th>Pool</th><th $th>Scheduled start</th><th $th>Status</th><th $th>Message</th></tr>")
        foreach ($p in $pools) {
            [void]$sb.AppendLine("<tr><td $td>$(& $enc (Get-GIPropValue $p 'poolName'))</td><td $td>$(& $enc (Get-GIPropValue $p 'scheduledStart'))</td><td $td>$(Get-GIBadge (Get-GIPropValue $p 'status'))</td><td $td>$(& $enc (Get-GIPropValue $p 'message'))</td></tr>")
        }
        [void]$sb.AppendLine('</table>')
    }

    # Error
    $err = Get-GIPropValue $Run 'error'
    if ($err) {
        $errText = if ($err -is [string]) { $err } else { ($err | ConvertTo-Json -Depth 5 -Compress) }
        [void]$sb.AppendLine("<h2 $h2>Error</h2>")
        [void]$sb.AppendLine("<table $tbl><tr><td style=`"padding:8px;border:1px solid #c62828;background-color:#ffebee;color:#b71c1c;font-size:13px;white-space:pre-wrap;`">$(& $enc $errText)</td></tr></table>")
    }

    [void]$sb.AppendLine('</td></tr></table>')
    [void]$sb.AppendLine('</body></html>')
    return $sb.ToString()
}

function Save-GIReport {
    <#
    .SYNOPSIS
    Writes the HTML report to <Config.Paths.Reports>/<runId>.html and returns the path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)]$Run
    )
    $dir = $Config.Paths.Reports
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $path = Join-Path $dir "$($Run.runId).html"
    $html = ConvertTo-GIReportHtml -Run $Run
    [System.IO.File]::WriteAllText($path, $html, [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Send-GIReport {
    <#
    .SYNOPSIS
    Emails the HTML report when Config.Email.Enabled is true. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)]$Run,
        [string]$Subject
    )
    $mail = $null
    $client = $null
    try {
        $email = $Config.Email
        if (-not $email -or -not $email.Enabled) { return }

        if (-not $Subject) {
            $Subject = "[VDI Pipeline] $($Run.goldenVm) $($Run.runId): $($Run.status)"
        }
        $port = if ($email.Port) { [int]$email.Port } else { 25 }

        $mail = [System.Net.Mail.MailMessage]::new()
        $mail.From = [System.Net.Mail.MailAddress]::new([string]$email.From)
        foreach ($to in @($email.To)) {
            if ($to) { $mail.To.Add([string]$to) }
        }
        $mail.Subject = $Subject
        $mail.SubjectEncoding = [System.Text.Encoding]::UTF8
        $mail.BodyEncoding = [System.Text.Encoding]::UTF8
        $mail.IsBodyHtml = $true
        $mail.Body = ConvertTo-GIReportHtml -Run $Run

        $client = [System.Net.Mail.SmtpClient]::new([string]$email.SmtpServer, $port)
        $client.EnableSsl = [bool]$email.UseSsl
        if ($email.CredentialSecret) {
            $cred = Get-GISecretCredential -Name $email.CredentialSecret
            $client.UseDefaultCredentials = $false
            $client.Credentials = $cred.GetNetworkCredential()
        }
        $client.Send($mail)
    }
    catch {
        Write-Warning "Send-GIReport failed: $($_.Exception.Message)"
    }
    finally {
        if ($mail) { $mail.Dispose() }
        if ($client) { $client.Dispose() }
    }
}
