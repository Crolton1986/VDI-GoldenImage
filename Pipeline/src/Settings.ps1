# Settings schema + form conversion, validation and persistence for the dashboard (see docs/CONTRACT.md).
# Edits are stored as a sparse overlay in <Root>/config/settings.json; Get-GIConfig merges it over the psd1.

$script:GIDayNames = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
$script:GIGuestActions = @('VmTools', 'Horizon', 'DEM', 'AppVolumes', 'HorizonRec', 'FSLogix', 'MsTeams', 'OneDrive', 'GoogleDrive')
$script:GITimePattern = '^([01]\d|2[0-3]):[0-5]\d$'

$script:GISettingsSchema = [ordered]@{
    vCenter = @{
        Title = 'vCenter'; ConfigPath = 'vCenter'; Test = 'vCenter'; ReadOnly = $false
        Description = 'vCenter Server used for snapshots, power operations and guest operations.'
        Fields = @(
            @{ Key = 'Server'; Label = 'Server (FQDN)'; Type = 'string'; Required = $true; Help = 'vCenter host name, without https://.' }
            @{ Key = 'CredentialSecret'; Label = 'Credential'; Type = 'secret'; Help = 'Account with snapshot, power and guest-operation rights.' }
        )
    }
    Horizon = @{
        Title = 'Horizon'; ConfigPath = 'Horizon'; Test = 'Horizon'; ReadOnly = $false
        Description = 'Horizon Connection Server REST API.'
        Fields = @(
            @{ Key = 'Server'; Label = 'Connection Server (FQDN)'; Type = 'string'; Required = $true }
            @{ Key = 'Domain'; Label = 'Domain'; Type = 'string'; Help = 'NetBIOS domain of the Horizon administrator account.' }
            @{ Key = 'CredentialSecret'; Label = 'Credential'; Type = 'secret' }
            @{ Key = 'SkipCertificateCheck'; Label = 'Skip certificate check'; Type = 'bool'; Warning = 'Disables TLS certificate validation for this server.' }
        )
    }
    AppVolumes = @{
        Title = 'App Volumes'; ConfigPath = 'AppVolumes'; Test = 'AppVolumes'; ReadOnly = $false
        Description = 'App Volumes Manager REST API and the packages checked on the test pool.'
        Fields = @(
            @{ Key = 'Server'; Label = 'Manager (FQDN)'; Type = 'string'; Required = $true }
            @{ Key = 'CredentialSecret'; Label = 'Credential'; Type = 'secret' }
            @{ Key = 'SkipCertificateCheck'; Label = 'Skip certificate check'; Type = 'bool'; Warning = 'Disables TLS certificate validation for this server.' }
            @{ Key = 'TestPackages'; Label = 'Test packages'; Type = 'list'; Help = 'One package name per line; assigned to the test pool computer OU.' }
            @{ Key = 'Endpoints.Session'; Label = 'Session endpoint'; Type = 'string'; Pattern = '^/'; Help = 'API paths differ between App Volumes releases. Must start with /. Test connection tries the other known path on a 404 and tells you which one worked.' }
            @{ Key = 'Endpoints.OnlineEntities'; Label = 'Online entities endpoint'; Type = 'string'; Pattern = '^/' }
            @{ Key = 'Endpoints.Attachments'; Label = 'Attachments endpoint'; Type = 'string'; Pattern = '^/' }
        )
    }
    GoldenImage = @{
        Title = 'Golden image'; ConfigPath = 'GoldenImage'; Test = 'GoldenImage'; ReadOnly = $false
        Description = 'The golden image VM and the actions run inside it.'
        Fields = @(
            @{ Key = 'VmName'; Label = 'VM name'; Type = 'string'; Required = $true }
            @{ Key = 'GuestCredentialSecret'; Label = 'Guest administrator'; Type = 'secret'; Help = 'Local administrator inside the golden image.' }
            @{ Key = 'ScriptPathInGuest'; Label = 'Script path in guest'; Type = 'string'; Required = $true }
            @{ Key = 'GuestWorkDir'; Label = 'Guest work folder'; Type = 'string'; Default = 'C:\ProgramData\VDI\Pipeline'; Required = $true }
            @{ Key = 'CopyScript'; Label = 'Copy script into guest before each run'; Type = 'bool'; Default = $true }
            @{ Key = 'Actions'; Label = 'Actions'; Type = 'list'; ItemValues = $script:GIGuestActions
               Help = "One per line, run in order with -Unattended after updates. Valid: $($script:GIGuestActions -join ', ')." }
            @{ Key = 'FinalizeAction'; Label = 'Finalize action'; Type = 'enum'; Values = @('Finalize', 'FinalizeFast'); Required = $true }
            @{ Key = 'PowerOffTimeoutMin'; Label = 'Power-off timeout (min)'; Type = 'int'; Min = 5; Max = 600; Required = $true }
        )
    }
    WindowsUpdate = @{
        Title = 'Windows Update'; ConfigPath = 'GoldenImage.WindowsUpdate'; Test = $null; ReadOnly = $false
        Description = 'Windows Update passes run in the golden image before the guest actions.'
        Fields = @(
            @{ Key = 'Enabled'; Label = 'Run Windows Update'; Type = 'bool' }
            @{ Key = 'MaxPasses'; Label = 'Maximum passes'; Type = 'int'; Min = 1; Max = 20; Required = $true; Help = 'Each pass installs updates, then reboots if needed.' }
            @{ Key = 'PassTimeoutMin'; Label = 'Pass timeout (min)'; Type = 'int'; Min = 10; Max = 600; Default = 120; Required = $true }
        )
    }
    Pools = @{
        Title = 'Pools'; ConfigPath = 'Pools'; Test = 'Pools'; ReadOnly = $false
        Description = 'The test pool receives every new snapshot; production pools only after approval.'
        Fields = @(
            @{ Key = 'Test.Name'; Label = 'Test pool name'; Type = 'string'; Required = $true }
            @{ Key = 'Test.LogoffPolicy'; Label = 'Test pool logoff policy'; Type = 'enum'; Values = @('FORCE_LOGOFF', 'WAIT_FOR_LOGOFF'); Required = $true; Default = 'FORCE_LOGOFF' }
            @{ Key = 'Production'; Label = 'Production pools'; Type = 'table'; Required = $true; UniqueBy = 'Name'; DistinctFrom = 'Test.Name'
               Help = 'Names must be unique and different from the test pool.'
               Columns = @(
                   @{ Key = 'Name'; Label = 'Pool name'; Type = 'string'; Required = $true }
                   @{ Key = 'LogoffPolicy'; Label = 'Logoff policy'; Type = 'enum'; Values = @('WAIT_FOR_LOGOFF', 'FORCE_LOGOFF'); Required = $true; Default = 'WAIT_FOR_LOGOFF' }
               ) }
            @{ Key = 'PushTimeoutMin'; Label = 'Push timeout (min)'; Type = 'int'; Min = 10; Max = 1440; Required = $true }
        )
    }
    Validation = @{
        Title = 'Validation'; ConfigPath = 'Validation'; Test = $null; ReadOnly = $false
        Description = 'Post-push checks on the test pool.'
        Fields = @(
            @{ Key = 'GuestSampleCount'; Label = 'Machines sampled'; Type = 'int'; Min = 0; Max = 20; Required = $true; Help = 'Guest-level checks run on this many test machines (0 = none).' }
            @{ Key = 'RequiredServices'; Label = 'Required services'; Type = 'list'; Help = 'Windows service names that must be running, one per line.' }
            @{ Key = 'MachineReadyTimeoutMin'; Label = 'Machine ready timeout (min)'; Type = 'int'; Min = 5; Max = 600; Required = $true }
            @{ Key = 'GuestCredentialSecret'; Label = 'Guest credential'; Type = 'secret'; DefaultName = 'GI-CloneGuestAdmin'
               Help = 'Account used inside the test clones. Falls back to the golden image guest credential when not set.' }
        )
    }
    Snapshots = @{
        Title = 'Snapshots'; ConfigPath = 'Snapshots'; Test = $null; ReadOnly = $false
        Description = 'Snapshot naming and retention on the golden image VM. Retention runs after a production push passes its checks.'
        Fields = @(
            @{ Key = 'NamePrefix'; Label = 'Snapshot name prefix'; Type = 'string'; Default = 'Baseline'; Pattern = '^[A-Za-z0-9][A-Za-z0-9 _.-]{0,39}$'
               Help = "New snapshots are named '<prefix> yy.MM.dd.HHmm', e.g. 'Baseline 26.11.24.0131'. Existing snapshots with this prefix are managed by retention." }
            @{ Key = 'Mode'; Label = 'Retention mode'; Type = 'enum'; Values = @('Chain', 'Tree'); Default = 'Chain'
               Help = 'Chain keeps Master > previous Baseline > production Baseline and removes older Baselines under them. Tree never removes a parent of an in-use snapshot, so a straight chain keeps growing.' }
            @{ Key = 'Keep'; Label = 'Baselines to keep'; Type = 'int'; Min = 1; Max = 50; Required = $true
               Help = '2 keeps production plus the previous one for rollback. The root (Master) snapshot is never removed and does not count.' }
            @{ Key = 'MaxChainDepth'; Label = 'Maximum chain depth'; Type = 'int'; Min = 2; Max = 31; Required = $true }
            @{ Key = 'Prune'; Label = 'Delete old snapshots'; Type = 'bool'; Warning = 'When off, retention only reports what it would delete. When on, old snapshots are removed and disks consolidated.' }
            @{ Key = 'ProtectAncestors'; Label = 'Protect ancestors of pending pushes'; Type = 'bool'; Confirm = $true
               Help = 'Chain mode: keeps every parent of a snapshot a push is still pending for. Tree mode: keeps every parent of any in-use snapshot.'
               Warning = 'Turning this off can delete a parent snapshot that a pending push depends on.' }
            @{ Key = 'ConsolidateTimeoutMin'; Label = 'Disk consolidation timeout (min)'; Type = 'int'; Min = 5; Max = 600; Default = 60 }
            @{ Key = 'MinFreeSpacePercent'; Label = 'Warn below datastore free space (%)'; Type = 'int'; Min = 1; Max = 90; Default = 15
               Help = 'Checked before each new snapshot. Warning only.' }
        )
    }
    Promotion = @{
        Title = 'Schedule & promotion'; ConfigPath = 'Promotion'; Test = $null; ReadOnly = $false
        Description = 'When the pipeline starts and when approved snapshots are pushed to production.'
        Fields = @(
            @{ Key = 'AutoPromote'; Label = 'Promote automatically after validation'; Type = 'bool'; Confirm = $true
               Warning = 'Skips the human approval gate: validated snapshots go to production pools in the next maintenance window.' }
            @{ Key = 'MaintenanceWindow.Days'; Label = 'Maintenance window days'; Type = 'days'; Required = $true }
            @{ Key = 'MaintenanceWindow.StartTime'; Label = 'Maintenance window start (HH:mm)'; Type = 'time'; Required = $true }
            @{ Key = 'PipelineSchedule.Day'; Label = 'Pipeline start day'; Type = 'enum'; Values = $script:GIDayNames; Default = 'Tuesday'; Required = $true }
            @{ Key = 'PipelineSchedule.Time'; Label = 'Pipeline start time (HH:mm)'; Type = 'time'; Default = '20:00'; Required = $true }
        )
    }
    Email = @{
        Title = 'Email'; ConfigPath = 'Email'; Test = 'Email'; ReadOnly = $false
        Description = 'Run report email.'
        Fields = @(
            @{ Key = 'Enabled'; Label = 'Send run reports'; Type = 'bool' }
            @{ Key = 'SmtpServer'; Label = 'SMTP server'; Type = 'string'; RequiredIf = 'Enabled' }
            @{ Key = 'Port'; Label = 'Port'; Type = 'int'; Min = 1; Max = 65535; Required = $true }
            @{ Key = 'UseSsl'; Label = 'Use SSL/TLS'; Type = 'bool' }
            @{ Key = 'From'; Label = 'From address'; Type = 'string'; RequiredIf = 'Enabled'; Pattern = '^[^@\s]+@[^@\s]+$'; PatternMessage = 'Must be an email address.' }
            @{ Key = 'To'; Label = 'Recipients'; Type = 'list'; RequiredIf = 'Enabled'; ItemPattern = '^[^@\s]+@[^@\s]+$'; ItemMessage = 'Not an email address'; Help = 'One address per line.' }
            @{ Key = 'CredentialSecret'; Label = 'SMTP credential'; Type = 'secret'; DefaultName = 'GI-Smtp'; Help = 'Optional; leave unset for anonymous relay.' }
        )
    }
    Dashboard = @{
        Title = 'Dashboard'; ConfigPath = 'Dashboard'; Test = $null; ReadOnly = $true
        Description = 'Read only here: changing the listener or access groups from the dashboard could lock you out. Edit pipeline.config.psd1 and restart.'
        Fields = @(
            @{ Key = 'Port'; Label = 'Port'; Type = 'int'; Min = 1; Max = 65535 }
            @{ Key = 'CertificateThumbprint'; Label = 'Certificate thumbprint'; Type = 'string' }
            @{ Key = 'ViewerGroup'; Label = 'Viewer group'; Type = 'string' }
            @{ Key = 'ApproverGroup'; Label = 'Approver group'; Type = 'string' }
            @{ Key = 'AdminGroup'; Label = 'Admin group'; Type = 'string' }
            @{ Key = 'RefreshSeconds'; Label = 'Refresh interval (s)'; Type = 'int'; Min = 2; Max = 3600 }
        )
    }
}

function Get-GISettingsAttr {
    # Optional hashtable attribute under StrictMode.
    param([System.Collections.IDictionary]$Table, [string]$Name, $Default = $null)
    if ($Table.Contains($Name)) { return $Table[$Name] }
    return $Default
}

function Get-GISettingsSchema {
    [CmdletBinding()]
    param()
    return $script:GISettingsSchema
}

function Get-GISettingsSectionDef {
    param([Parameter(Mandatory)][string]$Section)
    if (-not $script:GISettingsSchema.Contains($Section)) {
        throw "Unknown settings section '$Section'. Valid: $(@($script:GISettingsSchema.Keys) -join ', ')"
    }
    return $script:GISettingsSchema[$Section]
}

function Get-GISettingsNode {
    # Walks a dotted path through nested dictionaries. Returns @{ Found; Value }.
    param($Root, [string[]]$Parts)
    $node = $Root
    foreach ($p in $Parts) {
        if ($node -is [System.Collections.IDictionary] -and $node.Contains($p)) { $node = $node[$p] }
        else { return @{ Found = $false; Value = $null } }
    }
    return @{ Found = $true; Value = $node }
}

function Set-GISettingsNode {
    param([System.Collections.IDictionary]$Root, [string[]]$Parts, $Value)
    $node = $Root
    for ($i = 0; $i -lt $Parts.Count - 1; $i++) {
        $p = $Parts[$i]
        if (-not $node.Contains($p) -or $node[$p] -isnot [System.Collections.IDictionary]) { $node[$p] = @{} }
        $node = $node[$p]
    }
    $node[$Parts[-1]] = $Value
}

function Get-GISettingsFieldPath {
    param($Def, $Field)
    @($Def.ConfigPath.Split('.')) + @($Field.Key.Split('.'))
}

function ConvertTo-GISettingsFieldValue {
    # Normalizes a config value to the field's typed shape (used for effective values and diffs).
    param($Field, $Value, [bool]$Found)
    $type = $Field.Type
    switch ($type) {
        'bool' {
            if (-not $Found -or $null -eq $Value) { return [bool](Get-GISettingsAttr $Field 'Default' $false) }
            return [bool]$Value
        }
        'int' {
            if (-not $Found -or $null -eq $Value) { return Get-GISettingsAttr $Field 'Default' $null }
            $n = 0
            if ([int]::TryParse([string]$Value, [ref]$n)) { return $n }
            return $Value
        }
        { $_ -in 'list', 'days' } {
            if (-not $Found -or $null -eq $Value) { return , @() }
            return , @(@($Value) | ForEach-Object { [string]$_ })
        }
        'table' {
            if (-not $Found -or $null -eq $Value) { return , @() }
            $rows = foreach ($r in @($Value)) {
                $row = [ordered]@{}
                foreach ($c in $Field.Columns) {
                    $has = $r -is [System.Collections.IDictionary] -and $r.Contains($c.Key)
                    $row[$c.Key] = ConvertTo-GISettingsFieldValue $c $(if ($has) { $r[$c.Key] } else { $null }) $has
                }
                $row
            }
            return , @($rows)
        }
        default {
            if (-not $Found -or $null -eq $Value) { return [string](Get-GISettingsAttr $Field 'Default' '') }
            return [string]$Value
        }
    }
}

function Get-GISettingsEffective {
    # Effective non-secret values of a section from a merged config.
    param([hashtable]$Config, $Def)
    $values = @{}
    foreach ($f in $Def.Fields) {
        if ($f.Type -eq 'secret') { continue }
        $n = Get-GISettingsNode $Config (Get-GISettingsFieldPath $Def $f)
        $values[$f.Key] = ConvertTo-GISettingsFieldValue $f $n.Value $n.Found
    }
    return $values
}

function Get-GISettingsSection {
    <#
    .SYNOPSIS
        Effective values of a section from the merged config. Secret fields return @{ Name; IsSet; UserName; Configured }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Section
    )
    $def = Get-GISettingsSectionDef $Section
    $values = Get-GISettingsEffective -Config $Config -Def $def
    foreach ($f in $def.Fields) {
        if ($f.Type -ne 'secret') { continue }
        $n = Get-GISettingsNode $Config (Get-GISettingsFieldPath $def $f)
        if ($n.Found -and -not [string]::IsNullOrWhiteSpace([string]$n.Value)) {
            $st = Get-GISecretStatus -Name ([string]$n.Value)
            $values[$f.Key] = @{ Name = [string]$n.Value; IsSet = [bool]$st.IsSet; UserName = $st.UserName; Configured = $true }
        } else {
            # Not referenced by the config yet: the UI stores a credential under DefaultName on first set.
            $values[$f.Key] = @{ Name = (Get-GISettingsAttr $f 'DefaultName' $null); IsSet = $false; UserName = $null; Configured = $false }
        }
    }
    return @{ Section = $Section; Values = $values }
}

function Convert-GISettingsScalar {
    # Raw form string(s) -> typed scalar. Returns @{ Value; Error }.
    param($Field, $Raw)
    $first = if ($null -eq $Raw) { '' } else { [string](@($Raw)[0]) }
    $first = $first.Trim()
    switch ($Field.Type) {
        'bool' {
            $falseSet = @('false', '0', 'no', 'off', '')
            $isTrue = $false
            if ($null -ne $Raw) { foreach ($r in @($Raw)) { if (([string]$r).Trim().ToLowerInvariant() -notin $falseSet) { $isTrue = $true } } }
            return @{ Value = $isTrue; Error = $null }
        }
        'int' {
            if ($first -eq '') { return @{ Value = $null; Error = $null } }
            $n = 0
            if ([int]::TryParse($first, [System.Globalization.NumberStyles]::Integer, [cultureinfo]::InvariantCulture, [ref]$n)) {
                return @{ Value = $n; Error = $null }
            }
            return @{ Value = $null; Error = "Must be a whole number (got '$first')." }
        }
        default { return @{ Value = $first; Error = $null } }
    }
}

function ConvertFrom-GISettingsForm {
    <#
    .SYNOPSIS
        Converts raw form strings to typed values per schema. Returns @{ Values; Errors } (Errors = parse problems only;
        run Test-GISettingsSection on Values for the rest). Secret fields are excluded.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Form
    )
    $def = Get-GISettingsSectionDef $Section
    $values = @{}
    $errors = @{}
    foreach ($f in $def.Fields) {
        $key = $f.Key
        $raw = if ($Form.Contains($key)) { $Form[$key] } else { $null }
        switch ($f.Type) {
            'secret' { }
            'list' {
                $text = (@($raw) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) -join "`n"
                $values[$key] = @($text -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
            }
            'days' {
                $items = foreach ($r in @($raw)) { if ($null -ne $r) { ([string]$r) -split ',' } }
                $values[$key] = @($items | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
            }
            'table' {
                $rx = '^' + [regex]::Escape($key) + '\[(\d+)\]\.(.+)$'
                $byIndex = @{}
                foreach ($fk in $Form.Keys) {
                    if ([string]$fk -match $rx) { $byIndex[[int]$Matches[1]] = $true }
                }
                $rows = [System.Collections.Generic.List[object]]::new()
                # Dropdowns and checkboxes always post a value, so a spare row's selects don't make it a real row.
                # A row counts only when a typed column (text, number, time) has a value. Tables with no typed
                # column fall back to any non-bool value.
                $typedCols = @($f.Columns | Where-Object { $_.Type -notin 'enum', 'bool' })
                foreach ($i in ($byIndex.Keys | Sort-Object)) {
                    $rmKey = "$key[$i]._remove"
                    if ($Form.Contains($rmKey) -and [string]$Form[$rmKey] -in 'on', 'true', '1') { continue }
                    $row = [ordered]@{}
                    $rowErrors = @{}
                    $nonEmpty = $false
                    foreach ($c in $f.Columns) {
                        $ck = "$key[$i].$($c.Key)"
                        $cr = if ($Form.Contains($ck)) { $Form[$ck] } else { $null }
                        $conv = Convert-GISettingsScalar $c $cr
                        if ($conv.Error) { $rowErrors[$ck] = $conv.Error }
                        $row[$c.Key] = $conv.Value
                        $counts = if ($typedCols.Count) { $c.Type -notin 'enum', 'bool' } else { $c.Type -ne 'bool' }
                        if ($counts -and ($conv.Error -or ($null -ne $conv.Value -and "$($conv.Value)" -ne ''))) { $nonEmpty = $true }
                    }
                    if ($nonEmpty) {
                        $rows.Add($row)
                        foreach ($ek in $rowErrors.Keys) { $errors[$ek] = $rowErrors[$ek] }
                    }
                }
                $values[$key] = @($rows)
            }
            default {
                $conv = Convert-GISettingsScalar $f $raw
                if ($conv.Error) { $errors[$key] = $conv.Error }
                $values[$key] = $conv.Value
            }
        }
    }
    return @{ Values = $values; Errors = $errors }
}

function Test-GISettingsScalar {
    # Validates one scalar (top-level field or table column). Returns an error string or $null.
    param($Field, $Value, [bool]$Required)
    switch ($Field.Type) {
        'string' {
            $s = if ($null -eq $Value) { '' } else { [string]$Value }
            if ($s.Trim() -eq '') { if ($Required) { return 'Required.' } else { return $null } }
            $pattern = Get-GISettingsAttr $Field 'Pattern'
            if ($pattern -and $s -notmatch $pattern) {
                return (Get-GISettingsAttr $Field 'PatternMessage' "Must match the pattern $pattern.")
            }
        }
        'int' {
            if ($null -eq $Value -or "$Value" -eq '') { if ($Required) { return 'Required.' } else { return $null } }
            $n = [long]0
            if ($Value -is [int] -or $Value -is [long]) { $n = [long]$Value }
            elseif ($Value -is [string] -and [long]::TryParse($Value.Trim(), [ref]$n)) { }
            else { return 'Must be a whole number.' }
            $min = Get-GISettingsAttr $Field 'Min'
            $max = Get-GISettingsAttr $Field 'Max'
            if (($null -ne $min -and $n -lt $min) -or ($null -ne $max -and $n -gt $max)) {
                return "Must be between $min and $max."
            }
        }
        'bool' {
            if ($null -ne $Value -and $Value -isnot [bool]) { return 'Must be true or false.' }
        }
        'enum' {
            $s = if ($null -eq $Value) { '' } else { [string]$Value }
            if ($s -eq '') { if ($Required) { return 'Required.' } else { return $null } }
            if ($Field.Values -cnotcontains $s) { return "Must be one of: $($Field.Values -join ', ')." }
        }
        'time' {
            $s = if ($null -eq $Value) { '' } else { [string]$Value }
            if ($s -eq '') { if ($Required) { return 'Required.' } else { return $null } }
            if ($s -notmatch $script:GITimePattern) { return 'Use 24-hour HH:mm, for example 22:00.' }
        }
    }
    return $null
}

function Test-GISettingsSection {
    <#
    .SYNOPSIS
        Validates typed values. Returns @{ <Key> = 'error text' } (table cells use '<Key>[<i>].<Col>'); empty when valid.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values
    )
    $def = Get-GISettingsSectionDef $Section
    $errors = @{}
    foreach ($f in $def.Fields) {
        if ($f.Type -eq 'secret') { continue }
        $key = $f.Key
        $value = if ($Values.Contains($key)) { $Values[$key] } else { $null }
        $required = [bool](Get-GISettingsAttr $f 'Required' $false)
        $requiredIf = Get-GISettingsAttr $f 'RequiredIf'
        if ($requiredIf -and $Values.Contains($requiredIf) -and $Values[$requiredIf] -eq $true) { $required = $true }

        switch ($f.Type) {
            'list' {
                $items = @(@($value) | Where-Object { $null -ne $_ -and ([string]$_).Trim() -ne '' } | ForEach-Object { ([string]$_).Trim() })
                if ($items.Count -eq 0) {
                    if ($required) { $errors[$key] = 'At least one entry is required.' }
                    continue
                }
                $itemValues = Get-GISettingsAttr $f 'ItemValues'
                $itemPattern = Get-GISettingsAttr $f 'ItemPattern'
                $bad = @()
                foreach ($it in $items) {
                    if ($itemValues -and $itemValues -cnotcontains $it) { $bad += $it }
                    elseif ($itemPattern -and $it -notmatch $itemPattern) { $bad += $it }
                }
                if ($bad.Count) {
                    if ($itemValues) { $errors[$key] = "Invalid value(s): $($bad -join ', '). Valid: $($itemValues -join ', ')." }
                    else { $errors[$key] = "$(Get-GISettingsAttr $f 'ItemMessage' 'Invalid entry'): $($bad -join ', ')." }
                }
            }
            'days' {
                $items = @(@($value) | Where-Object { $null -ne $_ -and ([string]$_).Trim() -ne '' } | ForEach-Object { ([string]$_).Trim() })
                if ($items.Count -eq 0) { if ($required) { $errors[$key] = 'Select at least one day.' }; continue }
                $bad = @($items | Where-Object { $script:GIDayNames -cnotcontains $_ })
                if ($bad.Count) { $errors[$key] = "Invalid day(s): $($bad -join ', ')." }
            }
            'table' {
                $rows = @($value | Where-Object { $null -ne $_ })
                if ($rows.Count -eq 0) { if ($required) { $errors[$key] = 'Add at least one row.' }; continue }
                $seen = @{}
                $uniqueBy = Get-GISettingsAttr $f 'UniqueBy'
                $distinct = Get-GISettingsAttr $f 'DistinctFrom'
                $distinctValue = if ($distinct -and $Values.Contains($distinct)) { [string]$Values[$distinct] } else { $null }
                for ($i = 0; $i -lt $rows.Count; $i++) {
                    $row = $rows[$i]
                    foreach ($c in $f.Columns) {
                        $cv = if ($row -is [System.Collections.IDictionary] -and $row.Contains($c.Key)) { $row[$c.Key] } else { $null }
                        $err = Test-GISettingsScalar $c $cv ([bool](Get-GISettingsAttr $c 'Required' $false))
                        if ($err) { $errors["$key[$i].$($c.Key)"] = $err }
                    }
                    if ($uniqueBy -and $row -is [System.Collections.IDictionary] -and $row.Contains($uniqueBy)) {
                        $n = ([string]$row[$uniqueBy]).Trim()
                        $ck = "$key[$i].$uniqueBy"
                        if ($n -ne '' -and -not $errors.ContainsKey($ck)) {
                            if ($seen.ContainsKey($n.ToLowerInvariant())) { $errors[$ck] = "Duplicate: '$n' is already listed." }
                            elseif ($distinctValue -and $n -ieq $distinctValue.Trim()) { $errors[$ck] = "'$n' is the test pool; production pools must be different." }
                            $seen[$n.ToLowerInvariant()] = $true
                        }
                    }
                }
            }
            default {
                $err = Test-GISettingsScalar $f $value $required
                if ($err) { $errors[$key] = $err }
            }
        }
    }
    return $errors
}

function Read-GISettingsOverlay {
    param([hashtable]$Config)
    $path = Get-GISettingsFilePath $Config
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        return ($raw | ConvertFrom-Json -AsHashtable -Depth 20)
    } catch {
        throw "Settings overlay '$path' is not valid JSON: $($_.Exception.Message)"
    }
}

function Get-GISettingsFilePath {
    param([hashtable]$Config)
    if ($Config.Contains('SettingsPath') -and $Config['SettingsPath']) { return [string]$Config['SettingsPath'] }
    return Join-Path (Join-Path $Config.Root 'config') 'settings.json'
}

function Update-GISettingsOverlay {
    # Applies @{ Path = 'A.B'; Value = ... } items to settings.json (backup first, atomic write).
    param([hashtable]$Config, [object[]]$Set)
    $path = Get-GISettingsFilePath $Config
    $overlay = Read-GISettingsOverlay $Config
    foreach ($s in $Set) { Set-GISettingsNode $overlay @($s.Path.Split('.')) $s.Value }
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    if (Test-Path -LiteralPath $path -PathType Leaf) { Copy-Item -LiteralPath $path -Destination "$path.bak" -Force }
    Write-GIJsonAtomic -Path $path -InputObject $overlay
    return $path
}

function Save-GISettingsSection {
    <#
    .SYNOPSIS
        Validates and writes the changed keys of one section into settings.json. Throws listing all errors; refuses ReadOnly sections.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values,
        [string]$By = 'unknown'
    )
    $def = Get-GISettingsSectionDef $Section
    if ($def.ReadOnly) { throw "Settings section '$Section' is read only." }

    $errors = Test-GISettingsSection -Section $Section -Values $Values
    if ($errors.Count) {
        $list = ($errors.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name): $($_.Value)" }) -join '; '
        throw "Settings '$Section' not saved, $($errors.Count) error(s): $list"
    }

    $current = Get-GISettingsEffective -Config $Config -Def $def
    $set = [System.Collections.Generic.List[object]]::new()
    $diff = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $def.Fields) {
        if ($f.Type -eq 'secret' -or -not $Values.Contains($f.Key)) { continue }
        $new = ConvertTo-GISettingsFieldValue $f $Values[$f.Key] $true
        $old = $current[$f.Key]
        if ((ConvertTo-Json -InputObject $old -Depth 5 -Compress) -ceq (ConvertTo-Json -InputObject $new -Depth 5 -Compress)) { continue }
        $set.Add(@{ Path = (Get-GISettingsFieldPath $def $f) -join '.'; Value = $new })
        $diff.Add(@{ key = $f.Key; old = $old; new = $new })
    }
    $path = Get-GISettingsFilePath $Config
    if ($set.Count -gt 0) {
        $path = Update-GISettingsOverlay -Config $Config -Set @($set)
        Write-GIAudit -Config $Config -User $By -Action 'settings.save' -Target $Section -Detail @{ changes = @($diff) }
    }
    return @{ Section = $Section; Changed = @($diff | ForEach-Object { $_.key }); Path = $path }
}

function Set-GISettingsSecretName {
    <#
    .SYNOPSIS
        Ensures a secret field references a secret name in settings.json (the field's DefaultName when not yet configured).
        Returns the name. Called by the dashboard after it stored a credential.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [string]$By = 'unknown'
    )
    $def = Get-GISettingsSectionDef $Section
    $f = @($def.Fields | Where-Object { $_.Key -eq $Key -and $_.Type -eq 'secret' }) | Select-Object -First 1
    if (-not $f) { throw "Section '$Section' has no secret field '$Key'." }
    $parts = Get-GISettingsFieldPath $def $f
    $n = Get-GISettingsNode $Config $parts
    if ($n.Found -and -not [string]::IsNullOrWhiteSpace([string]$n.Value)) { return [string]$n.Value }
    $name = Get-GISettingsAttr $f 'DefaultName'
    if (-not $name) { throw "Secret field '$Section.$Key' has no name configured and no default." }
    $null = Update-GISettingsOverlay -Config $Config -Set @(@{ Path = $parts -join '.'; Value = $name })
    Write-GIAudit -Config $Config -User $By -Action 'settings.save' -Target $Section -Detail @{ changes = @(@{ key = $Key; old = $null; new = $name }) }
    return $name
}
