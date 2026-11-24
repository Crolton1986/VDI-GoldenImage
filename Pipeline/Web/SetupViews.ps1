[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Helpers return heterogeneous values by design.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '', Justification = 'Internal view helpers; short positional calls keep HTML builders readable.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-* functions only build strings; nothing is changed.')]
param()

# Pure HTML view functions for the first-run setup wizard (/setup). See docs/CONTRACT.md "First-run setup".
# Requires Web/DashboardViews.ps1 (ConvertTo-GIHtml, Get-GIValue, New-GIPage, ...) and Web/SettingsViews.ps1 (Get-GITokenInput) to be loaded first.
# Every dynamic value is HTML-encoded. Works without JS (meta refresh fallback while a step is running).

function Get-GISetupStepOrder { @('Mode', 'Prerequisites', 'Modules', 'PowerCLI', 'Vault', 'DashboardAccess', 'Tasks', 'Finish') }

function Get-GISetupStep {
    [CmdletBinding()]
    [OutputType([object])]
    param($State, [Parameter(Mandatory)][string]$Name)
    Get-GIValue (Get-GIValue $State 'steps' $null) $Name $null
}

function Get-GISetupStatus {
    [CmdletBinding()]
    [OutputType([string])]
    param($State, [Parameter(Mandatory)][string]$Name)
    $s = [string](Get-GIValue (Get-GISetupStep $State $Name) 'status' 'pending')
    if ($s -notin 'pending', 'running', 'done', 'failed', 'skipped') { return 'pending' }
    return $s
}

function Get-GISetupRunningStep {
    [CmdletBinding()]
    [OutputType([string])]
    param($State)
    foreach ($n in (Get-GISetupStepOrder)) { if ((Get-GISetupStatus $State $n) -eq 'running') { return $n } }
    return $null
}

function Get-GISetupVersion {
    <# Changes whenever the state changes: updatedAt when present, else a hash of statuses/messages/detail. #>
    [CmdletBinding()]
    [OutputType([string])]
    param($State)
    $raw = Get-GIValue $State 'updatedAt' ''
    $u = [string]$raw
    if ($raw -is [datetime]) { $u = $raw.ToUniversalTime().ToString('o') }
    if ($u) { return $u }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($n in (Get-GISetupStepOrder)) {
        $st = Get-GISetupStep $State $n
        [void]$sb.Append($n).Append('|').Append((Get-GISetupStatus $State $n)).Append('|').Append([string](Get-GIValue $st 'message' '')).Append('|').Append(@(Get-GIValue $st 'detail' @()).Count).Append(';')
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return ([System.BitConverter]::ToString($hash) -replace '-', '').Substring(0, 16).ToLowerInvariant()
}

function New-GISetupStatusJson {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$State)
    $steps = [ordered]@{}
    foreach ($n in (Get-GISetupStepOrder)) { $steps[$n] = Get-GISetupStatus $State $n }
    $running = Get-GISetupRunningStep $State
    ([ordered]@{ version = (Get-GISetupVersion $State); running = $running; steps = $steps }) | ConvertTo-Json -Compress -Depth 4
}

function Get-GISetupBadge {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Status)
    $spin = ''
    if ($Status -eq 'running') { $spin = '<span class="spinner" aria-hidden="true"></span>' }
    "<span class=""badge sb-$Status"">$spin$(ConvertTo-GIHtml $Status)</span>"
}

function Get-GISetupFormOpen {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Step, [string]$Token)
    "<form method=""post"" action=""/setup/$(ConvertTo-GIHtml $Step)"">$(Get-GITokenInput $Token)"
}

function Get-GISetupModeForm {
    [CmdletBinding()]
    [OutputType([string])]
    param($State, [string]$Token)
    $action = [string](Get-GIValue (Get-GIValue $State 'options' $null) 'invalidCertAction' 'Warn')
    $opts = foreach ($v in 'Warn', 'Ignore', 'Fail') {
        $sel = ''
        if ($v -eq $action) { $sel = ' selected' }
        "<option value=""$v""$sel>$v</option>"
    }
    $certField = "<div class=""field""><label for=""invalidCertAction"">When vCenter/Horizon certificates aren't trusted</label><select id=""invalidCertAction"" name=""invalidCertAction"">$($opts -join '')</select></div>"
    $f = Get-GISetupFormOpen 'Mode' $Token
    if ((Get-GIValue $State 'modeLocked' $false) -eq $true) {
        return "$f<p><strong>Lab mode (started with -LocalAdmin)</strong></p><input type=""hidden"" name=""mode"" value=""Lab"">$certField<button type=""submit"">Continue</button></form>"
    }
    $cur = [string](Get-GIValue $State 'mode' '')
    $prodChk = ' checked'
    $labChk = ''
    if ($cur -eq 'Lab') { $labChk = ' checked'; $prodChk = '' }
    @"
$f
<div class="choice"><label><input type="radio" name="mode" value="Production"$prodChk> <strong>Production</strong></label>
<p class="muted">Serves the dashboard over https, signs users in with Active Directory, registers scheduled tasks, and installs modules for all users. Needs an administrator.</p></div>
<div class="choice"><label><input type="radio" name="mode" value="Lab"$labChk> <strong>Lab</strong></label>
<p class="muted">This machine only (127.0.0.1), no sign-in, no scheduled tasks, and modules are installed for the current user.</p></div>
$certField
<button type="submit">Continue</button></form>
"@
}

function Get-GISetupRunForm {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Step, [string]$Token, [string]$Status)
    $label = 'Run'
    if ($Status -eq 'failed') { $label = 'Retry' }
    "$(Get-GISetupFormOpen $Step $Token)<button type=""submit"">$label</button></form>"
}

function Get-GISetupModulesTable {
    [CmdletBinding()]
    [OutputType([string])]
    param($State)
    $items = @(Get-GIValue (Get-GIValue (Get-GISetupStep $State 'Modules') 'data' $null) 'items' @())
    if ($items.Count -eq 0) { return '' }
    $rows = foreach ($i in $items) {
        $st = [string](Get-GIValue $i 'status' '')
        $cls = 'st-pending'
        if ($st -eq 'ok') { $cls = 'st-ok' } elseif ($st -in 'failed', 'missing', 'error') { $cls = 'st-bad' } elseif ($st -in 'installing', 'running') { $cls = 'st-running' }
        "<tr><td>$(ConvertTo-GIHtml (Get-GIValue $i 'name'))</td><td>$(ConvertTo-GIHtml (Get-GIValue $i 'required'))</td><td>$(ConvertTo-GIHtml (Get-GIValue $i 'installed'))</td><td><span class=""badge $cls"">$(ConvertTo-GIHtml $st)</span></td></tr>"
    }
    "<table class=""modules""><thead><tr><th>Module</th><th>Required</th><th>Installed</th><th>Status</th></tr></thead><tbody>$($rows -join '')</tbody></table>"
}

function Get-GISetupAccessForm {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Token, $Certificates)
    $certOpts = foreach ($c in @($Certificates)) {
        if ($null -eq $c) { continue }
        $na = Get-GIValue $c 'NotAfter' ''
        $exp = [string]$na
        if ($na -is [datetime]) { $exp = $na.ToString('yyyy-MM-dd') } elseif ($exp.Length -ge 10) { $exp = $exp.Substring(0, 10) }
        $thumb = Get-GIValue $c 'Thumbprint'
        "<option value=""$(ConvertTo-GIHtml $thumb)"">$(ConvertTo-GIHtml (Get-GIValue $c 'Subject')) (expires $(ConvertTo-GIHtml $exp)) - $(ConvertTo-GIHtml $thumb)</option>"
    }
    $self = '<option value="__selfsigned__">Create a self-signed certificate for this server (browsers will warn)</option>'
    @"
$(Get-GISetupFormOpen 'DashboardAccess' $Token)
<div class="field"><label for="port">Port</label><input type="number" id="port" name="port" value="8443" min="1" max="65535"></div>
<div class="field"><label for="certificate">Certificate</label><select id="certificate" name="certificate">$($certOpts -join '')$self</select></div>
<div class="field"><label for="viewerGroup">Viewer group</label><input type="text" id="viewerGroup" name="viewerGroup" placeholder="DOMAIN\VDI-Pipeline-Viewers"></div>
<div class="field"><label for="approverGroup">Approver group</label><input type="text" id="approverGroup" name="approverGroup" placeholder="DOMAIN\VDI-Pipeline-Approvers"></div>
<div class="field"><label for="adminGroup">Admin group</label><input type="text" id="adminGroup" name="adminGroup" placeholder="DOMAIN\VDI-Pipeline-Admins"><div class="help">Groups are checked in Active Directory before saving</div></div>
<button type="submit">Save</button></form>
"@
}

function Get-GISetupTaskTrigger {
    [CmdletBinding()]
    [OutputType([string])]
    param($Trigger)
    if ($null -eq $Trigger) { return '' }
    $parts = @(
        [string](Get-GIValue $Trigger 'Type' ''),
        [string](Get-GIValue $Trigger 'Day' ''),
        [string](Get-GIValue $Trigger 'Time' '')
    ) | Where-Object { $_ }
    $parts -join ' '
}

function Get-GISetupTasksForm {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Token, $TaskDefinitions, [string]$CurrentUser)
    $rows = foreach ($t in @($TaskDefinitions)) {
        if ($null -eq $t) { continue }
        "<tr><td>$(ConvertTo-GIHtml (Get-GIValue $t 'Name'))</td><td>$(ConvertTo-GIHtml (Get-GIValue $t 'Description'))</td><td>$(ConvertTo-GIHtml (Get-GISetupTaskTrigger (Get-GIValue $t 'Trigger' $null)))</td></tr>"
    }
    $table = ''
    if (@($rows).Count -gt 0) { $table = "<table class=""tasks""><thead><tr><th>Task</th><th>What it does</th><th>When</th></tr></thead><tbody>$($rows -join '')</tbody></table>" }
    @"
$table
$(Get-GISetupFormOpen 'Tasks' $Token)
<div class="field"><label for="taskUser">Run as</label><input type="text" id="taskUser" value="$(ConvertTo-GIHtml $CurrentUser)" readonly></div>
<div class="field"><label for="taskPassword">Your Windows password (Task Scheduler needs it to run tasks when you're logged off; it isn't stored by the pipeline)</label><input type="password" id="taskPassword" name="password" autocomplete="current-password"></div>
<button type="submit" name="action" value="register">Register tasks</button></form>
$(Get-GISetupFormOpen 'Tasks' $Token)<button type="submit" name="action" value="skip" class="sec">Skip (leave Task Scheduler untouched)</button></form>
"@
}

function Get-GISetupStepForm {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Step, $State, [string]$Token, [string]$Status, $Certificates, $TaskDefinitions, [string]$CurrentUser)
    switch ($Step) {
        'Mode' { Get-GISetupModeForm $State $Token }
        'DashboardAccess' { Get-GISetupAccessForm $Token $Certificates }
        'Tasks' { Get-GISetupTasksForm $Token $TaskDefinitions $CurrentUser }
        'Finish' { "$(Get-GISetupFormOpen 'Finish' $Token)<button type=""submit"">Finish setup</button></form>" }
        default {
            $warn = ''
            if ($Step -eq 'Vault') {
                $warn = "<p class=""warn"">The vault is set to open without a password for this Windows user, so scheduled tasks can read it. Anyone who can log on as $(ConvertTo-GIHtml $CurrentUser) can read these secrets; protect that account.</p>"
            }
            "$warn$(Get-GISetupRunForm $Step $Token $Status)"
        }
    }
}

function New-GISetupPage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$State,
        [string]$Token = '',
        [string]$Notice = '',
        $Certificates = @(),
        $TaskDefinitions = @(),
        [string]$CurrentUser = '',
        [bool]$IsComplete = $false,
        [bool]$ReadOnly = $false,
        [hashtable]$LogTails = @{},
        [int]$StallMinutes = 0
    )
    $order = Get-GISetupStepOrder
    $running = Get-GISetupRunningStep $State
    $active = $null
    if (-not $IsComplete) {
        foreach ($n in $order) {
            if ((Get-GISetupStatus $State $n) -notin 'done', 'skipped') { $active = $n; break }
        }
    }
    $body = '<h2>Set up the golden image pipeline</h2>'
    if ($Notice) { $body += "<div class=""notice"" role=""status"">$(ConvertTo-GIHtml $Notice)</div>" }
    if ($IsComplete) {
        $body += '<div class="banner-ok">Setup is complete.</div><p class="links"><a href="/settings">Settings</a><a href="/">Dashboard</a></p>'
        if ($ReadOnly) { $body += '<p class="muted">To run setup again, start Start-GIPipeline.ps1 -ResetSetup on the server.</p>' }
    }
    $num = 0
    foreach ($n in $order) {
        $num++
        $st = Get-GISetupStatus $State $n
        $step = Get-GISetupStep $State $n
        $msg = [string](Get-GIValue $step 'message' '')
        $card = "<section class=""card setup-step s-$st"" id=""step-$n""><h2><span class=""num"">$num.</span> $(ConvertTo-GIHtml $n) $(Get-GISetupBadge $st)</h2>"
        if ($msg) { $card += "<p>$(ConvertTo-GIHtml $msg)</p>" }
        $detail = @(Get-GIValue $step 'detail' @())
        if ($detail.Count -gt 0) {
            $last = @($detail | Select-Object -Last 15)
            $open = ''
            if ($st -in 'running', 'failed') { $open = ' open' }
            $card += "<details$open><summary>Details ($($last.Count))</summary><pre class=""detail"">$(($last | ForEach-Object { ConvertTo-GIHtml $_ }) -join "`n")</pre></details>"
        }
        if ($st -eq 'running') {
            $procId = Get-GIValue $step 'pid' $null
            if ($procId) { $card += "<p class=""muted"">process $(ConvertTo-GIHtml ([string]$procId))</p>" }
            if ($LogTails.ContainsKey($n) -and $LogTails[$n]) { $card += "<pre class=""detail log-tail"" style=""font-family:monospace"">$(ConvertTo-GIHtml ([string]$LogTails[$n]))</pre>" }
            if ($StallMinutes -ge 2) { $card += "<p class=""warn"">No progress for $(ConvertTo-GIHtml ([string]$StallMinutes)) minutes. Check the log; if the process has stopped, this step switches to failed and you can retry it.</p>" }
        }
        if ($st -notin 'pending', 'skipped' -and $n -in 'Prerequisites', 'Modules', 'PowerCLI', 'Vault') {
            $card += "<p class=""links""><a href=""/setup/log/$(ConvertTo-GIHtml $n)"" target=""_blank"" rel=""noopener"">View log</a></p>"
        }
        if ($n -eq 'Modules' -and $st -ne 'pending') { $card += Get-GISetupModulesTable $State }
        if (-not $ReadOnly -and -not $IsComplete) {
            if ($n -eq $active) {
                $form = Get-GISetupStepForm -Step $n -State $State -Token $Token -Status $st -Certificates $Certificates -TaskDefinitions $TaskDefinitions -CurrentUser $CurrentUser
                if ($running) { $card += "<fieldset disabled>$form</fieldset>" } else { $card += $form }
            } elseif ($st -eq 'pending' -and $active) {
                $card += "<p class=""waits"">waits for step $([array]::IndexOf($order, $active) + 1)</p>"
            }
        }
        $body += $card + '</section>'
    }
    if ($running) {
        $body += @'
<script>
(function(){var v=document.body.getAttribute('data-version');
setInterval(function(){fetch('/setup/status',{cache:'no-store'}).then(function(r){return r.json();}).then(function(j){if(String(j.version)!==v){location.reload();}}).catch(function(){});},2000);})();
</script>
'@
    }
    $html = New-GIPage -Title 'Set up the golden image pipeline' -BodyHtml $body
    $ver = ConvertTo-GIHtml (Get-GISetupVersion $State)
    $html = $html.Replace('<body>', "<body data-version=""$ver"">")
    if ($running) { $html = $html.Replace('</head>', '<noscript><meta http-equiv="refresh" content="3"></noscript></head>') }
    return $html
}
