# Multi-image model: the list of golden images, the per-image config view, constraints, migration and image CRUD.
# See docs/ADR-0001-multi-image.md. Pipeline stages keep working on a flat config: Get-GIImageConfig returns the
# global config with one image's blocks folded in (GoldenImage, Pools, Validation, Snapshots, Promotion,
# AppVolumes.TestPackages) and the state, log and report folders scoped to that image.

$script:GIImageBlocks = @('GoldenImage', 'Pools', 'Validation', 'Snapshots', 'Promotion')

function Test-GIRunId {
    # True only for yyyyMMdd-HHmmss. Call before using a RunId in any file path.
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string]$RunId)
    if ([string]::IsNullOrEmpty($RunId)) { return $false }
    return [regex]::IsMatch($RunId, '^\d{8}-\d{6}\z')
}

function ConvertTo-GISlug {
    # Lowercase slug usable in URLs and folder names: a-z, 0-9 and single hyphens.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Text)
    $s = ([string]$Text).ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    $s = $s.Trim('-')
    if ($s.Length -gt 60) { $s = $s.Substring(0, 60).Trim('-') }
    if (-not $s) { $s = 'image' }
    return $s
}

function Test-GIImageId {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string]$Id)
    if ([string]::IsNullOrEmpty($Id)) { return $false }
    return [regex]::IsMatch($Id, '^[a-z0-9][a-z0-9-]{0,62}\z')
}

function New-GIImageId {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name, [string[]]$Existing = @())
    $base = ConvertTo-GISlug $Name
    $id = $base; $n = 2
    while ($Existing -contains $id) { $id = "$base-$n"; $n++ }
    return $id
}

function Get-GIImageDefaults {
    # Non-identity defaults a new image starts from (no VM, pool or secret names).
    [CmdletBinding()]
    param()
    @{
        GoldenImage = @{
            ScriptPathInGuest = 'C:\ProgramData\VDI\VDI-GoldenImage.ps1'; InstallerSourceDir = ''; Actions = @()
            WindowsUpdate = @{ Enabled = $true; MaxPasses = 5 }; FinalizeAction = 'Finalize'; PowerOffTimeoutMin = 90
            ActionTimeoutMin = 60; GuestWorkDir = 'C:\ProgramData\VDI\Pipeline'
            Watcher = @{ LogPollSec = 10; IdlePollSec = 60; StatusPollSec = 60; WatchingWindowSec = 30; StaleHeartbeatSec = 180; MaxRelaunches = 3; MaxStepAttempts = 4; FixTimeoutSec = 600 }
        }
        Pools = @{ Test = @{ Name = ''; LogoffPolicy = 'FORCE_LOGOFF' }; Production = @(); PushTimeoutMin = 120 }
        Validation = @{ GuestSampleCount = 2; RequiredServices = @('wsnm', 'svservice', 'frxsvc'); MachineReadyTimeoutMin = 60 }
        Snapshots = @{ NamePrefix = 'Baseline'; Mode = 'Chain'; Keep = 2; MaxChainDepth = 10; Prune = $false; ProtectAncestors = $true; ConsolidateTimeoutMin = 60; MinFreeSpacePercent = 15; CleanupFailedRuns = $true }
        Promotion = @{ AutoPromote = $false; MaintenanceWindow = @{ Days = @('Saturday'); StartTime = '22:00' }; PipelineSchedule = @{ Day = 'Tuesday'; Time = '20:00' } }
        AppVolumes = @{ TestPackages = @() }
    }
}

function Get-GIImageEntries {
    <#
    .SYNOPSIS
        The golden image entries of a loaded config (full, merged over defaults). A config in the old single-image
        shape yields one virtual entry marked Legacy = $true (state stays in the root folders until migrated).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][hashtable]$Config)
    $out = [System.Collections.Generic.List[object]]::new()
    $list = if ($Config.ContainsKey('GoldenImages') -and $null -ne $Config['GoldenImages']) { @($Config['GoldenImages']) } else { $null }
    if ($null -ne $list) {
        foreach ($e in $list) {
            if ($e -isnot [System.Collections.IDictionary]) { continue }
            $m = Merge-GIHashtable -Base (Get-GIImageDefaults) -Overlay $e
            if (-not $m.ContainsKey('Description')) { $m.Description = '' }
            if (-not $m.ContainsKey('Os')) { $m.Os = '' }
            $m.Paused = [bool]$m['Paused']
            $m.Legacy = $false
            $out.Add($m)
        }
        return $out.ToArray()
    }
    if ($Config.ContainsKey('GoldenImage') -and $Config['GoldenImage'] -is [System.Collections.IDictionary]) {
        $vm = [string]$Config.GoldenImage.VmName
        $m = Merge-GIHashtable -Base (Get-GIImageDefaults) -Overlay @{}
        foreach ($b in $script:GIImageBlocks) { if ($Config.ContainsKey($b)) { $m[$b] = Copy-GIValue $Config[$b] } }
        if ($Config.ContainsKey('AppVolumes') -and $Config.AppVolumes.ContainsKey('TestPackages')) { $m.AppVolumes = @{ TestPackages = @($Config.AppVolumes.TestPackages) } }
        $name = if ($Config.GoldenImage.ContainsKey('DisplayName') -and $Config.GoldenImage.DisplayName) { [string]$Config.GoldenImage.DisplayName } else { $vm }
        $m.Id = ConvertTo-GISlug $vm; $m.Name = $name; $m.Description = ''; $m.Os = ''; $m.Paused = $false; $m.Legacy = $true
        $out.Add($m)
    }
    return $out.ToArray()
}

function Get-GIImageEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Id)
    @(Get-GIImageEntries -Config $Config) | Where-Object { $_.Id -ceq $Id } | Select-Object -First 1
}

function Get-GIImageConfig {
    <#
    .SYNOPSIS
        A flat config for one image: what every pipeline function already expects. State, logs and reports live in
        <root>/<imageId> (the root folders themselves for an unmigrated legacy config). Paths.RootState keeps the
        shared state folder (audit log). Throws for an unknown id.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$ImageId)
    $e = Get-GIImageEntry -Config $Config -Id $ImageId
    if (-not $e) { throw "Golden image '$ImageId' not found." }
    $c = Copy-GIValue $Config
    $null = $c.Remove('GoldenImages')
    foreach ($b in $script:GIImageBlocks) { $c[$b] = Copy-GIValue $e[$b] }
    if (-not $c.ContainsKey('AppVolumes') -or $c.AppVolumes -isnot [System.Collections.IDictionary]) { $c.AppVolumes = @{} }
    $c.AppVolumes.TestPackages = @(@($e.AppVolumes.TestPackages) | Where-Object { $_ })
    $c.ImageId = $e.Id; $c.ImageName = $e.Name; $c.ImagePaused = [bool]$e.Paused
    $c.Paths.RootState = $Config.Paths.State
    if (-not $e.Legacy) {
        foreach ($k in 'State', 'Reports', 'Logs') {
            $d = Join-Path $Config.Paths[$k] $e.Id
            if (-not (Test-Path -LiteralPath $d)) { $null = New-Item -ItemType Directory -Path $d -Force }
            $c.Paths[$k] = $d
        }
    }
    return $c
}

function Get-GIImageConfigs {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][hashtable]$Config)
    foreach ($e in (Get-GIImageEntries -Config $Config)) { Get-GIImageConfig -Config $Config -ImageId $e.Id }
}

#----- Constraints -----

function Get-GIImagePoolNames {
    param($Entry)
    $names = [System.Collections.Generic.List[string]]::new()
    if ($Entry.Pools.Test.Name) { $names.Add([string]$Entry.Pools.Test.Name) }
    foreach ($p in @($Entry.Pools.Production)) { if ($p.Name) { $names.Add([string]$p.Name) } }
    return $names.ToArray()
}

function Test-GIImageConstraints {
    <#
    .SYNOPSIS
        Returns error strings (empty = valid): ids and names unique and well formed, a pool belongs to at most one image,
        the test pool differs from every production pool, a VM belongs to at most one image.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries)
    $err = [System.Collections.Generic.List[string]]::new()
    $ids = @{}; $names = @{}; $vms = @{}; $pools = @{}
    foreach ($e in $Entries) {
        $id = [string]$e.Id; $label = if ($e.Name) { "'$($e.Name)'" } else { "'$id'" }
        if (-not (Test-GIImageId $id)) { $err.Add("Image $label has an invalid id '$id' (use lowercase letters, digits and hyphens).") }
        if ($ids.ContainsKey($id)) { $err.Add("Image id '$id' is used twice.") } else { $ids[$id] = $true }
        $nk = ([string]$e.Name).Trim().ToLowerInvariant()
        if (-not $nk) { $err.Add("Image '$id' has no name.") }
        elseif ($names.ContainsKey($nk)) { $err.Add("Image name '$($e.Name)' is used twice.") } else { $names[$nk] = $true }
        $vm = ([string]$e.GoldenImage.VmName).Trim()
        if (-not $vm) { $err.Add("Image $label has no VM name.") }
        elseif ($vms.ContainsKey($vm.ToLowerInvariant())) { $err.Add("VM '$vm' belongs to image '$($vms[$vm.ToLowerInvariant()])' and $label. A VM can belong to one image.") }
        else { $vms[$vm.ToLowerInvariant()] = $e.Name }
        $test = [string]$e.Pools.Test.Name
        if (-not $test) { $err.Add("Image $label has no test pool.") }
        $prod = @(@($e.Pools.Production) | ForEach-Object { [string]$_.Name } | Where-Object { $_ })
        if ($prod.Count -eq 0) { $err.Add("Image $label has no production pool.") }
        if ($test -and ($prod | Where-Object { $_ -ieq $test })) { $err.Add("Image $label uses '$test' as both test pool and production pool.") }
        foreach ($p in @(@($test) + $prod | Where-Object { $_ } | Select-Object -Unique)) {
            $k = $p.ToLowerInvariant()
            if ($pools.ContainsKey($k) -and $pools[$k] -ne $e.Id) { $err.Add("Pool '$p' belongs to image '$($pools[$k])' and $label. A pool can belong to one image.") }
            else { $pools[$k] = $e.Id }
        }
    }
    return $err.ToArray()
}

#----- Overlay access -----

function Read-GIImageOverlayList {
    # The GoldenImages list from the overlay, or the current effective entries (without runtime flags) when the overlay has none yet.
    param([hashtable]$Config)
    $ov = Read-GISettingsOverlay $Config
    if ($ov.ContainsKey('GoldenImages') -and $null -ne $ov['GoldenImages']) { return @($ov['GoldenImages']) }
    $list = foreach ($e in (Get-GIImageEntries -Config $Config)) { $c = Copy-GIValue $e; $c.Remove('Legacy'); $c }
    return @($list)
}

function Write-GIImageOverlayList {
    param([hashtable]$Config, [object[]]$List)
    $null = Update-GISettingsOverlay -Config $Config -Set @(@{ Path = 'GoldenImages'; Value = @($List) })
}

function Assert-GIImageEntryValid {
    # Throws one message listing every problem, using the same rules as the settings schema for the per-image sections.
    param([Parameter(Mandatory)][hashtable]$Entry, [object[]]$Others = @())
    $problems = [System.Collections.Generic.List[string]]::new()
    $merged = Merge-GIHashtable -Base (Get-GIImageDefaults) -Overlay $Entry
    foreach ($section in 'GoldenImage', 'Pools', 'Validation', 'Snapshots', 'Promotion') {
        if (-not $Entry.ContainsKey($section)) { continue }
        try { $def = Get-GISettingsSectionDef $section } catch { continue }
        if ($def.ReadOnly) { continue }
        $form = @{}
        foreach ($f in $def.Fields) {
            if ($f.Type -eq 'secret') { continue }
            $n = Get-GISettingsNode $merged (Get-GISettingsFieldPath $def $f)
            if ($n.Found) { $form[$f.Key] = $n.Value }
        }
        $errs = Test-GISettingsSection -Section $section -Values $form
        foreach ($k in $errs.Keys) { $problems.Add("${section}.${k}: $($errs[$k])") }
    }
    foreach ($m in (Test-GIImageConstraints -Entries (@($Others) + @($merged)))) { $problems.Add($m) }
    if ($problems.Count) { throw "Image not saved, $($problems.Count) problem(s): $($problems -join '; ')" }
}

function New-GIImageFromPayload {
    <# Creates the image in the overlay. Payload: Name, Description, Os, plus any per-image blocks. Does not start a run. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][System.Collections.IDictionary]$Payload, [string]$By = 'unknown')
    $existing = @(Get-GIImageEntries -Config $Config)
    $name = ([string]$Payload['Name']).Trim()
    if (-not $name) { throw 'Image not saved, 1 problem(s): Name: required' }
    $entry = @{ Name = $name; Description = ([string]$Payload['Description']).Trim(); Os = ([string]$Payload['Os']).Trim(); Paused = $false }
    foreach ($b in ($script:GIImageBlocks + 'AppVolumes')) { if ($Payload.Contains($b)) { $entry[$b] = Copy-GIValue $Payload[$b] } }
    if (-not $entry.ContainsKey('GoldenImage')) { $entry.GoldenImage = @{} }
    $entry.Id = if ($Payload['Id']) { [string]$Payload['Id'] } else { New-GIImageId -Name $name -Existing @($existing | ForEach-Object { $_.Id }) }
    if (-not $entry.GoldenImage['GuestCredentialSecret']) { $entry.GoldenImage.GuestCredentialSecret = "GI-Guest-$($entry.Id)" }
    # Validate against the other images as they will be stored (a legacy virtual entry becomes a real one on first write)
    Assert-GIImageEntryValid -Entry $entry -Others @($existing | Where-Object { $_.Id -cne $entry.Id })
    $list = @(Read-GIImageOverlayList -Config $Config) + @($entry)
    Write-GIImageOverlayList -Config $Config -List $list
    Write-GIAudit -Config $Config -User $By -Action 'image.create' -Target $entry.Id -Detail @{ image = $entry.Id; name = $name; result = 'OK' }
    return $entry
}

function Save-GIImageSection {
    <# Saves one per-image section (GoldenImage, Pools, ...) or the identity fields ('General': Name, Description, Os). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$ImageId, [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values, [string]$By = 'unknown')
    $e = Get-GIImageEntry -Config $Config -Id $ImageId
    if (-not $e) { throw "Golden image '$ImageId' not found." }
    $list = @(Read-GIImageOverlayList -Config $Config)
    $idx = -1; for ($i = 0; $i -lt $list.Count; $i++) { if ($list[$i].Id -ceq $ImageId) { $idx = $i } }
    if ($idx -lt 0) { throw "Golden image '$ImageId' not found." }
    $entry = Copy-GIValue $list[$idx]
    $changed = [System.Collections.Generic.List[string]]::new()
    if ($Section -eq 'General') {
        foreach ($k in 'Name', 'Description', 'Os') {
            if ($Values.Contains($k) -and ([string]$Values[$k]).Trim() -cne [string]$entry[$k]) { $entry[$k] = ([string]$Values[$k]).Trim(); $changed.Add($k) }
        }
    } elseif ($Section -eq 'AppVolumes') {
        $new = @(@($Values['TestPackages']) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
        if (($new -join "`n") -cne (@($entry.AppVolumes.TestPackages) -join "`n")) { $entry.AppVolumes = @{ TestPackages = $new }; $changed.Add('TestPackages') }
    } else {
        $def = Get-GISettingsSectionDef $Section
        if ($def.ReadOnly) { throw "Settings section '$Section' is read only." }
        $block = ([string]$def.ConfigPath).Split('.')[0]
        if ($block -notin $script:GIImageBlocks) { throw "'$Section' is not a per-image section." }
        $cur = Get-GISettingsEffective -Config (Get-GIImageConfig -Config $Config -ImageId $ImageId) -Def $def
        # Validate the whole section as it would be after the save (the caller may send only the fields it changed)
        $whole = @{}; foreach ($k in $cur.Keys) { $whole[$k] = $cur[$k] }; foreach ($k in $Values.Keys) { $whole[$k] = $Values[$k] }
        $errors = Test-GISettingsSection -Section $Section -Values $whole
        if ($errors.Count) { throw "Settings '$Section' not saved, $($errors.Count) error(s): $((($errors.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name): $($_.Value)" }) -join '; '))" }
        if (-not $entry.ContainsKey($block)) { $entry[$block] = Copy-GIValue $e[$block] }
        foreach ($f in $def.Fields) {
            if ($f.Type -eq 'secret' -or -not $Values.Contains($f.Key)) { continue }
            $new = ConvertTo-GISettingsFieldValue $f $Values[$f.Key] $true
            if ((ConvertTo-Json -InputObject $cur[$f.Key] -Depth 5 -Compress) -ceq (ConvertTo-Json -InputObject $new -Depth 5 -Compress)) { continue }
            Set-GISettingsNode $entry @((Get-GISettingsFieldPath $def $f)) $new
            $changed.Add($f.Key)
        }
    }
    if ($changed.Count -eq 0) { return @{ Section = $Section; Changed = @() } }
    $others = @(Get-GIImageEntries -Config $Config | Where-Object { $_.Id -cne $ImageId })
    Assert-GIImageEntryValid -Entry $entry -Others $others
    $list[$idx] = $entry
    Write-GIImageOverlayList -Config $Config -List $list
    Write-GIAudit -Config $Config -User $By -Action 'image.update' -Target $ImageId -Detail @{ image = $ImageId; section = $Section; keys = @($changed); result = 'OK' }
    return @{ Section = $Section; Changed = @($changed) }
}

function Set-GIImagePaused {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$ImageId, [Parameter(Mandatory)][bool]$Paused, [string]$By = 'unknown')
    $list = @(Read-GIImageOverlayList -Config $Config)
    $found = $false
    foreach ($e in $list) { if ($e.Id -ceq $ImageId) { $e.Paused = $Paused; $found = $true } }
    if (-not $found) { throw "Golden image '$ImageId' not found." }
    Write-GIImageOverlayList -Config $Config -List $list
    Write-GIAudit -Config $Config -User $By -Action $(if ($Paused) { 'image.pause' } else { 'image.resume' }) -Target $ImageId -Detail @{ image = $ImageId; result = 'OK' }
}

function Test-GIImageBusy {
    # True when the image's pipeline lock is held by a live process or a run is Running.
    param([Parameter(Mandatory)][hashtable]$ImageConfig)
    try { if (Get-GIPipelineLock -Config $ImageConfig) { return $true } } catch { Write-Verbose "Lock check failed: $($_.Exception.Message)" }
    return [bool](@(Get-GIRunList -Config $ImageConfig -Last 5) | Where-Object { $_.status -eq 'Running' })
}

function Remove-GIImageEntry {
    <# Removes the image from the config only. Never touches vCenter, Horizon, snapshots, pools, run state or logs. Refuses while a run is active. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$ImageId, [string]$By = 'unknown')
    $ic = Get-GIImageConfig -Config $Config -ImageId $ImageId
    if (Test-GIImageBusy -ImageConfig $ic) { throw "A run is active for '$ImageId'. Wait for it to finish before removing the image." }
    $list = @(Read-GIImageOverlayList -Config $Config)
    $keep = @($list | Where-Object { $_.Id -cne $ImageId })
    if ($keep.Count -eq $list.Count) { throw "Golden image '$ImageId' not found." }
    Write-GIImageOverlayList -Config $Config -List $keep
    Write-GIAudit -Config $Config -User $By -Action 'image.delete' -Target $ImageId -Detail @{ image = $ImageId; keptOnDisk = $ic.Paths.State; result = 'OK' }
}

#----- Migration -----

function Invoke-GIConfigMigration {
    <#
    .SYNOPSIS
        One time, idempotent: turns the old single-image config into one GoldenImages entry in the settings overlay and
        moves runs, approvals, logs and reports into the image's folders. A backup of the old overlay and state is
        written first and never deleted. Returns @{ Migrated; ImageId; Backup }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)
    if ($Config.ContainsKey('GoldenImages') -and $null -ne $Config['GoldenImages']) { return @{ Migrated = $false } }
    $entries = @(Get-GIImageEntries -Config $Config)
    if ($entries.Count -eq 0) { return @{ Migrated = $false } }
    $e = $entries[0]
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $backup = Join-Path (Join-Path $Config.Root 'config') "migration-backup-$stamp"
    $null = New-Item -ItemType Directory -Path $backup -Force
    $sp = Get-GISettingsFilePath $Config
    if (Test-Path -LiteralPath $sp -PathType Leaf) { Copy-Item -LiteralPath $sp -Destination (Join-Path $backup 'settings.json') -Force }
    $psd1 = Join-Path $Config.Root 'pipeline.config.psd1'
    if (Test-Path -LiteralPath $psd1) { Copy-Item -LiteralPath $psd1 -Destination (Join-Path $backup 'pipeline.config.psd1') -Force }
    $runFilter = '^\d{8}-\d{6}'
    $targets = @{ State = Join-Path $Config.Paths.State $e.Id; Logs = Join-Path $Config.Paths.Logs $e.Id; Reports = Join-Path $Config.Paths.Reports $e.Id }
    $moved = 0
    foreach ($k in 'State', 'Logs', 'Reports') {
        $src = $Config.Paths[$k]
        $files = @(Get-ChildItem -LiteralPath $src -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $runFilter -or ($k -eq 'State' -and $_.Name -in 'lastKnownGood.json', 'run-request.json') })
        $dirs = @(Get-ChildItem -LiteralPath $src -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $runFilter })
        if ($files.Count + $dirs.Count -eq 0) { continue }
        $bk = Join-Path (Join-Path $backup $k) ''
        $null = New-Item -ItemType Directory -Path $bk -Force
        $null = New-Item -ItemType Directory -Path $targets[$k] -Force
        foreach ($f in @($files) + @($dirs)) {
            Copy-Item -LiteralPath $f.FullName -Destination $bk -Recurse -Force
            Move-Item -LiteralPath $f.FullName -Destination $targets[$k] -Force
            $moved++
        }
    }
    # Stamp imageId into the moved runs
    foreach ($f in @(Get-ChildItem -LiteralPath $targets.State -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match '^\d{8}-\d{6}\z' })) {
        try {
            $run = Read-GIJsonFile -Path $f.FullName
            if (-not $run.PSObject.Properties['imageId']) { Add-Member -InputObject $run -NotePropertyName imageId -NotePropertyValue $e.Id; Write-GIJsonAtomic -Path $f.FullName -InputObject $run }
        } catch { Write-Warning "Could not stamp imageId into $($f.Name): $($_.Exception.Message)" }
    }
    $entry = Copy-GIValue $e; $entry.Remove('Legacy')
    Write-GIImageOverlayList -Config $Config -List @($entry)
    Write-GIAudit -Config $Config -User 'system' -Action 'image.migrate' -Target $e.Id -Detail @{ image = $e.Id; moved = $moved; backup = $backup; result = 'OK' }
    Write-Information "Migrated the single-image config to golden image '$($e.Id)'; moved $moved item(s). Backup: $backup" -InformationAction Continue
    return @{ Migrated = $true; ImageId = $e.Id; Backup = $backup; Moved = $moved }
}

#----- Summaries (no live calls) -----

function Get-GIRunSummary {
    param($Run)
    if (-not $Run) { return $null }
    $steps = @(); try { $steps = @(Get-GIStepList -Run $Run) } catch { Write-Verbose 'Run has no steps yet' }
    [ordered]@{
        runId = [string]$Run.runId; status = [string](Get-GIWatcherProp $Run 'status' ''); currentStage = [string](Get-GIWatcherProp $Run 'currentStage' '')
        createdAt = [string](Get-GIWatcherProp $Run 'createdAt' ''); updatedAt = [string](Get-GIWatcherProp $Run 'updatedAt' ''); progress = [string](Get-GIWatcherProp $Run 'progress' '')
        snapshot = [string](Get-GIWatcherProp (Get-GIWatcherProp $Run 'snapshot' $null) 'name' '')
        error = [string](Get-GIWatcherProp $Run 'error' '')
        approvedBy = [string](Get-GIWatcherProp (Get-GIWatcherProp $Run 'approval' $null) 'by' '')
        stages = @(foreach ($sn in 'Preflight', 'Maintain', 'Snapshot', 'TestPush', 'Validate', 'Approval', 'Promote', 'PostCheck') { [string](Get-GIWatcherProp (Get-GIWatcherProp (Get-GIWatcherProp $Run 'stages' $null) $sn $null) 'status' 'Pending') })
        stepsDone = @($steps | Where-Object { $_.status -in 'Succeeded', 'Skipped' }).Count; stepsTotal = $steps.Count
    }
}

function Get-GIImageSummary {
    <# Config-derived image summary with the last and the active run. Reads files only; never calls vCenter or Horizon. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$ImageId)
    $e = Get-GIImageEntry -Config $Config -Id $ImageId
    $ic = Get-GIImageConfig -Config $Config -ImageId $ImageId
    $runs = @(Get-GIRunList -Config $ic -Last 20)
    $active = $runs | Where-Object { $_.status -in 'Running', 'AwaitingApproval' } | Select-Object -First 1
    $last = $runs | Select-Object -First 1
    $lkg = Get-GILastKnownGood -Config $ic
    [ordered]@{
        id = $e.Id; name = $e.Name; description = $e.Description; os = $e.Os; paused = [bool]$e.Paused
        vm = [string]$e.GoldenImage.VmName; testPool = [string]$e.Pools.Test.Name
        productionPools = @(@($e.Pools.Production) | ForEach-Object { [string]$_.Name })
        packages = @($e.GoldenImage.Actions)
        autoPromote = [bool]$e.Promotion.AutoPromote
        schedule = [ordered]@{ day = [string]$e.Promotion.PipelineSchedule.Day; time = [string]$e.Promotion.PipelineSchedule.Time }
        maintenanceWindow = [ordered]@{ days = @($e.Promotion.MaintenanceWindow.Days); startTime = [string]$e.Promotion.MaintenanceWindow.StartTime }
        lastRun = Get-GIRunSummary $last
        activeRun = Get-GIRunSummary $active
        lastKnownGood = if ($lkg) { [ordered]@{ snapshotName = [string]$lkg.snapshotName; runId = [string]$lkg.runId; promotedAt = [string]$lkg.promotedAt } } else { $null }
    }
}

function Set-GIImageSecretName {
    <# Makes sure a secret field of one image names a vault secret; returns the name (existing, or the default recorded now). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$ImageId, [Parameter(Mandatory)][string]$Section, [Parameter(Mandatory)][string]$Key, [string]$By = 'unknown')
    $def = Get-GISettingsSectionDef $Section
    $f = @($def.Fields | Where-Object { $_.Key -eq $Key -and $_.Type -eq 'secret' }) | Select-Object -First 1
    if (-not $f) { throw "Section '$Section' has no secret field '$Key'." }
    $ic = Get-GIImageConfig -Config $Config -ImageId $ImageId
    $n = Get-GISettingsNode $ic (Get-GISettingsFieldPath $def $f)
    if ($n.Found -and -not [string]::IsNullOrWhiteSpace([string]$n.Value)) { return [string]$n.Value }
    $name = Get-GISettingsAttr $f 'DefaultName' "GI-Guest-$ImageId"
    $list = @(Read-GIImageOverlayList -Config $Config)
    foreach ($e in $list) {
        if ($e.Id -ceq $ImageId) {
            $block = ([string]$def.ConfigPath).Split('.')[0]
            if (-not $e.ContainsKey($block)) { $e[$block] = Copy-GIValue $ic[$block] }
            Set-GISettingsNode $e @((Get-GISettingsFieldPath $def $f)) $name
        }
    }
    Write-GIImageOverlayList -Config $Config -List $list
    Write-GIAudit -Config $Config -User $By -Action 'settings.update' -Target $Section -Detail @{ image = $ImageId; section = $Section; keys = @($Key) } -Result 'OK'
    return $name
}
