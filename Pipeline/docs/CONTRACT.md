# Pipeline contract (state schema, config keys, module layout)

Every component (pipeline stages, approval script, Pode dashboard) reads and writes the
same files. This document is the single definition. Change it before changing code.

## Module layout

```
Pipeline/
  VDI-GIPipeline.psm1      # dot-sources src/*.ps1, exports public functions
  Invoke-GIPipeline.ps1    # entry: -Stage All|Preflight|Maintain|Snapshot|TestPush|Validate|Promote|PostCheck|Rollback
  Approve-GIPromotion.ps1  # human gate
  pipeline.config.psd1     # environment config (no secrets)
  src/Config.ps1           # Get-GIConfig
  src/State.ps1            # run state persistence
  src/Logging.ps1          # Write-GILog
  src/Report.ps1           # HTML report + email
  src/Rest.ps1             # Horizon + App Volumes REST sessions
  src/Snapshot.ps1         # snapshot creation + retention
  src/Stages.ps1           # stage implementations
  src/Approval.ps1         # approval/promotion/rollback
  state/<RunId>.json       # one file per run
  state/lastKnownGood.json # last snapshot that passed validation AND was promoted
  reports/<RunId>.html
  logs/<RunId>.log
  Web/Start-GIDashboard.ps1
  tests/*.Tests.ps1        # Pester 5+
```

Target runtime: PowerShell 7.2+ on Windows. Code must also load on Linux pwsh for unit tests
(no Windows-only calls at module import time; PowerCLI/Pode only needed when functions run).

## Run state file: `state/<RunId>.json`

RunId format: `yyyyMMdd-HHmmss` (local time of run creation), e.g. `20261124-213005`.
All timestamps are ISO 8601 strings with offset (`(Get-Date).ToString('o')`). JSON depth 10.
Writes are atomic: write `<file>.tmp` then `Move-Item -Force` over the target.

```json
{
  "schemaVersion": 1,
  "runId": "20261124-213005",
  "goldenVm": "W11-GI-01",
  "createdAt": "2026-11-24T21:30:05.0000000-05:00",
  "updatedAt": "...",
  "status": "Running",
  "currentStage": "Maintain",
  "progress": "Windows Update pass 2: 3 updates pending, rebooting",
  "stages": {
    "Preflight": { "status": "Succeeded", "startedAt": "...", "endedAt": "...", "message": "", "data": {} },
    "Maintain":  { "status": "Running",   "startedAt": "...", "endedAt": null,  "message": "", "data": {} },
    "Snapshot":  { "status": "Pending",   "startedAt": null,  "endedAt": null,  "message": "", "data": {} },
    "TestPush":  { "status": "Pending", ... },
    "Validate":  { "status": "Pending", ... },
    "Approval":  { "status": "Pending", ... },
    "Promote":   { "status": "Pending", ... },
    "PostCheck": { "status": "Pending", ... }
  },
  "safetySnapshot": { "id": "VirtualMachineSnapshot-snapshot-123", "name": "pre-maint-20261124-213005" },
  "snapshot": {
    "id": "VirtualMachineSnapshot-snapshot-124",
    "name": "GI-20261124-213005",
    "createdAt": "...",
    "manifest": { "VmTools": "12.5.0", "Horizon": "2512.0.0", "AppVolumes": "4.17.0", "FSLogix": "2.9.8884", "MsTeams": "25.1.0" }
  },
  "validation": {
    "passed": false,
    "checks": [
      { "category": "Horizon", "name": "MachineState", "target": "TST-W11-001", "passed": true, "detail": "AVAILABLE" }
    ]
  },
  "approval": { "decision": null, "by": null, "at": null, "startTime": null, "comment": null },
  "promotion": {
    "pools": [ { "poolName": "PRD-W11", "poolId": "...", "scheduledStart": "...", "status": "Scheduled", "message": "" } ]
  },
  "error": null
}
```

### Enums

- `stages.<name>.status`: `Pending | Running | Succeeded | Failed | Skipped`
- Stage order (fixed): `Preflight, Maintain, Snapshot, TestPush, Validate, Approval, Promote, PostCheck`
- `status` (run level):
  - `Running` — a stage is executing
  - `Failed` — a stage failed; `error` holds the message; `currentStage` is the failed stage
  - `AwaitingApproval` — Validate passed, Approval stage `Running`
  - `Rejected` — approver rejected; terminal
  - `Scheduled` — prod pushes scheduled, waiting for window
  - `Completed` — PostCheck succeeded; terminal
  - `RolledBack` — rollback executed; terminal
- `approval.decision`: `null | Approved | Rejected`
- `promotion.pools[].status`: `Scheduled | InProgress | Succeeded | Failed | Cancelled`

### `state/lastKnownGood.json`

```json
{ "goldenVm": "W11-GI-01", "snapshotId": "...", "snapshotName": "GI-...", "runId": "...", "promotedAt": "..." }
```

## State API (src/State.ps1)

| Function | Behavior |
|---|---|
| `New-GIRun -Config <hashtable> [-RunId <string>]` | Creates run object with all stages `Pending`, status `Running`, saves, returns `[pscustomobject]` |
| `Get-GIRun -Config -RunId` | Loads one run; throws if missing |
| `Get-GIRunList -Config [-Last <int>]` | All runs, newest first |
| `Save-GIRun -Config -Run` | Sets `updatedAt`, atomic write |
| `Set-GIStage -Config -Run -Stage <name> -Status <enum> [-Message] [-Data <hashtable>]` | Sets timestamps (`Running` sets startedAt, terminal statuses set endedAt), updates `currentStage`; `Failed` also sets run `status=Failed` and `error`; saves |
| `Set-GIProgress -Config -Run -Message` | Sets `progress`, saves (used for long waits so the dashboard shows live detail) |
| `Get-GILastKnownGood -Config` / `Set-GILastKnownGood -Config -Run` | Read/write lastKnownGood.json; Get returns `$null` if absent |

`-Config` is the hashtable from `Get-GIConfig`; state path = `Config.Paths.State` (relative paths resolve against the Pipeline folder).

## Config (`pipeline.config.psd1`)

```powershell
@{
  Paths      = @{ State = 'state'; Reports = 'reports'; Logs = 'logs' }
  vCenter    = @{ Server = 'vcsa01.domain.local'; CredentialSecret = 'GI-vCenter' }
  Horizon    = @{ Server = 'hzcs01.domain.local'; CredentialSecret = 'GI-Horizon'; Domain = 'DOMAIN'; SkipCertificateCheck = $false }
  AppVolumes = @{ Server = 'avm01.domain.local';  CredentialSecret = 'GI-AppVol'; SkipCertificateCheck = $false
                  TestPackages = @('Notepad++')            # packages assigned to the test pool's computer OU
                  Endpoints = @{ Session = '/app_volumes/sessions'; OnlineEntities = '/app_volumes/online_entities'; Attachments = '/app_volumes/app_attachments' } }
  GoldenImage = @{
    VmName            = 'W11-GI-01'
    GuestCredentialSecret = 'GI-GuestAdmin'
    ScriptPathInGuest = 'C:\ProgramData\VDI\VDI-GoldenImage.ps1'
    Actions           = @('VmTools','Horizon','DEM','AppVolumes','FSLogix','MsTeams')   # run with -Unattended after updates
    WindowsUpdate     = @{ Enabled = $true; MaxPasses = 5 }
    FinalizeAction    = 'Finalize'
    PowerOffTimeoutMin = 90
  }
  Pools = @{
    Test       = @{ Name = 'TST-W11'; LogoffPolicy = 'FORCE_LOGOFF' }
    Production = @( @{ Name = 'PRD-W11'; LogoffPolicy = 'WAIT_FOR_LOGOFF' } )
    PushTimeoutMin = 120
  }
  Validation = @{
    GuestSampleCount = 2
    RequiredServices = @('wsnm','svservice','frxsvc')
    MachineReadyTimeoutMin = 60
  }
  Snapshots = @{ Keep = 3; MaxChainDepth = 10; Prune = $false; ProtectAncestors = $true }   # Prune=$false => report only
  Promotion = @{
    AutoPromote = $false
    MaintenanceWindow = @{ Days = @('Saturday'); StartTime = '22:00' }   # next window used when no -StartTime given
    PipelineSchedule  = @{ Day = 'Tuesday'; Time = '20:00' }               # weekly start of the pipeline scheduled task
  }
  Email = @{ Enabled = $false; SmtpServer = 'smtp.domain.local'; Port = 25; From = 'vdi-pipeline@domain.local'; To = @('vdi-team@domain.local'); UseSsl = $false }
  Dashboard = @{ Port = 8443; CertificateThumbprint = ''; ViewerGroup = 'DOMAIN\VDI-Pipeline-Viewers'; ApproverGroup = 'DOMAIN\VDI-Pipeline-Approvers'; AdminGroup = 'DOMAIN\VDI-Pipeline-Admins'; RefreshSeconds = 20 }
}
```

`Get-GIConfig [-Path]` loads with `Import-PowerShellDataFile`, defaults to `pipeline.config.psd1`
next to the module, adds `Config.Root` (Pipeline folder), resolves `Paths.*` to absolute paths,
and validates required keys (throws listing every missing key).

Secrets: `Get-GISecretCredential -Name` wraps `Get-Secret -Name <n> -AsPlainText:$false` from
Microsoft.PowerShell.SecretManagement and returns a `[pscredential]`.

## In-guest script contract (`VDI-GoldenImage.ps1`)

- `-Unattended`: no prompts. Download prompts answer from `$VAR.UnattendedDownload` (default `$true`);
  "continue install?" prompts answer Yes; Horizon Recording registration is skipped with a warning.
- Exit code: `0` success, `1` if any `MsgFce -Output error` was emitted, `2` invalid/missing action when unattended.
- `-ResultFile <path>`: writes JSON
  `{ "action": "AppVolumes", "success": true, "errors": ["..."], "finishedAt": "...", "versions": { "VmTools": "...", "Horizon": "...", ... } }`

---

# Settings, run control, audit (dashboard v2)

## Settings overlay: `config/settings.json`

`pipeline.config.psd1` holds shipped defaults. Edits from the dashboard go to `config/settings.json`
(path: `<Config.Root>/config/settings.json`, gitignored). Same nested shape as the psd1, but only
the keys that were changed, e.g.

```json
{ "vCenter": { "Server": "vcsa02.domain.local" },
  "Pools": { "Production": [ { "Name": "PRD-W11", "LogoffPolicy": "WAIT_FOR_LOGOFF" } ] } }
```

`Get-GIConfig` loads the psd1, then deep-merges settings.json over it before validation:
dictionaries merge key by key (recursively), every other value (arrays included) replaces.
JSON objects become hashtables (`ConvertFrom-Json -AsHashtable`). Adds `Config.SettingsPath`.
Writes: `Write-GIJsonAtomic`; previous file copied to `settings.json.bak` first.

## Settings schema (`$script:GISettingsSchema` in src/Settings.ps1)

Ordered dictionary of sections. Each section:

```powershell
vCenter = @{
  Title = 'vCenter'; ConfigPath = 'vCenter'; Test = 'vCenter'   # Test: system name for Test-GIConnection, or $null
  ReadOnly = $false                                            # Dashboard section is ReadOnly
  Description = 'One line shown under the title.'
  Fields = @(
    @{ Key = 'Server'; Label = 'Server (FQDN)'; Type = 'string'; Required = $true; Help = '...' }
    @{ Key = 'CredentialSecret'; Label = 'Credential'; Type = 'secret' }
  )
}
```

- `Key` is relative to the section's `ConfigPath` and may be dotted (`WindowsUpdate.MaxPasses`).
- Field `Type`:
  - `string` (optional `Pattern` regex), `int` (`Min`, `Max`), `bool`,
  - `list`: string array, edited one per line,
  - `enum`: `Values = @(...)`,
  - `days`: subset of Monday..Sunday,
  - `time`: `HH:mm`,
  - `secret`: the config value is the SecretManagement secret *name*. The form shows username +
    password for that secret; saving calls `Set-GISecretCredential`. The secret name itself is not
    editable in the UI. Password is never rendered back. Blank password = keep existing.
  - `table`: array of hashtables, `Columns = @( <field defs of type string|enum|int|bool> )`, add/remove rows.
- Optional on any field: `Help`, `Required`, `Warning` (shown next to the field, e.g. ProtectAncestors),
  `Confirm` (bool fields: turning it on needs a confirmation checkbox, e.g. AutoPromote).

Settings API:

| Function | Behavior |
|---|---|
| `Get-GISettingsSchema` | Returns the schema |
| `Get-GISettingsSection -Config -Section` | `@{ Section; Values = @{ <Key> = <effective value> } }` read from merged Config (secret fields: `@{ Name; IsSet; UserName }` via `Get-GISecretStatus`) |
| `Test-GISettingsSection -Section -Values <hashtable>` | Returns `@{ <Key> = 'error text' }`, empty when valid. Values are already typed (see ConvertFrom-GISettingsForm) |
| `ConvertFrom-GISettingsForm -Section -Form <hashtable>` | Converts raw form strings to typed values per schema (`int`, bool from checkbox presence, list split on newlines and trimmed, days from repeated checkbox values, table rows from `<Key>[<i>].<Col>` names). Secret fields are excluded. Returns `@{ Values; Errors }` |
| `Save-GISettingsSection -Config -Section -Values -By` | Validates, writes only the section's keys into settings.json (deep set), backup + atomic write, audit entry `settings.save` with field-level diff (`old`/`new`; secrets never included). Throws with all errors if invalid |

## Audit log: `state/audit.jsonl`

One JSON object per line: `{ "at": "<o>", "user": "DOMAIN\\x", "action": "...", "target": "...", "detail": {...} }`.
Actions: `settings.save`, `credential.set`, `connection.test`, `run.request`, `run.request.cancel`, `approval.approve`, `approval.reject`, `rollback.request`.
`Write-GIAudit -Config -User -Action -Target [-Detail <hashtable>]` (never throws; Write-Warning on failure),
`Get-GIAudit -Config [-Last 200]` newest first.

## Pipeline lock: `state/pipeline.lock`

`{ "pid": 1234, "host": "MGMT01", "runId": "...", "stage": "All", "startedAt": "<o>", "requestedBy": "..." }`

- `Enter-GIPipelineLock -Config -Stage [-RunId] [-RequestedBy]`: creates the lock with `FileMode.CreateNew`
  (atomic). If a lock exists and its PID is alive on this host, throws `Pipeline is busy: ...`.
  If the PID is gone it's stale: removed, then retried once.
- `Update-GIPipelineLock -Config -RunId` (sets runId once known), `Exit-GIPipelineLock -Config` (removes only if pid matches).
- `Get-GIPipelineLock -Config` returns the lock with an added `stale` bool, or `$null`.

## Run request: `state/run-request.json`

```json
{ "id": "<guid>", "action": "All|FromStage|Stage|PostCheck|Rollback", "stage": "Validate",
  "runId": "20261124-213005", "pool": "PRD-W11", "snapshotName": null, "forceLogoff": false,
  "requestedBy": "DOMAIN\\x", "requestedAt": "<o>" }
```

- `New-GIRunRequest -Config -Action [-Stage] [-RunId] [-Pool] [-SnapshotName] [-ForceLogoff] -RequestedBy`
  validates (stage in stage list minus Approval/Promote; runId pattern + file exists for FromStage/Stage;
  pool must be the test pool or a production pool from config for Rollback) and refuses if a request is
  already pending or the lock is held. Writes atomically, audits `run.request`/`rollback.request`.
- `Read-GIRunRequest -Config`: reads, deletes, re-validates, returns the request or `$null`.
- The dashboard then calls `Start-GIRunnerTask` (wraps `Start-ScheduledTask -TaskName VDI-GI-Runner`).
- `Invoke-GIPipeline.ps1 -FromRequest` executes it. `-FromStage <name> -RunId` runs that stage through Validate.

## Dashboard roles

`Dashboard.AdminGroup`: settings, credentials, Test connection, run controls. `ApproverGroup`: approve/reject.
`ViewerGroup`: read. Login accepts all three. `-NoAuth`: read-only. `-LocalAdmin`: binds 127.0.0.1, no auth,
caller is admin + approver (lab/smoke tests only).

---

# First-run setup (launcher + /setup)

Entry point for people: `Start-GIPipeline.ps1` (runs in Windows PowerShell 5.1 or 7). It installs PowerShell 7
if needed (asks first), elevates for Production, installs Pode only, then starts
`Web/Start-GIDashboard.ps1 -Setup` on `http://127.0.0.1:<port>` and opens `/setup` until setup is complete.
Everything (vault, tasks, dashboard) runs as the logged-in user who ran setup.

## State: `config/setup.json` (gitignored)

```json
{
  "schemaVersion": 1,
  "mode": "Lab",                 // null until chosen, then Lab | Production
  "modeLocked": true,            // true when launched with -LocalAdmin (Lab forced)
  "startedAt": "<o>", "completedAt": null,
  "options": { "invalidCertAction": "Warn" },
  "steps": {
    "Mode":            { "status": "done", "message": "Lab", "startedAt": "<o>", "endedAt": "<o>", "pid": null, "detail": [], "data": {} },
    "Prerequisites":   { "status": "pending", ... },
    "Modules":         { "status": "running", "pid": 4242, "detail": ["Installing VMware.PowerCLI 13.3.0 (CurrentUser)..."],
                         "data": { "items": [ { "name": "Pode", "required": "2.10.0", "installed": "2.14.2", "status": "ok" } ] } },
    "PowerCLI":        { ... }, "Vault": { ... }, "DashboardAccess": { ... }, "Tasks": { ... }, "Finish": { ... }
  }
}
```

- Step order (fixed): `Mode, Prerequisites, Modules, PowerCLI, Vault, DashboardAccess, Tasks, Finish`.
- Step status: `pending | running | done | failed | skipped`. Lab mode marks `DashboardAccess` and `Tasks` skipped.
- `detail` is a rolling list of progress lines (last 50 kept). `data` is step-specific.
- Only one step runs at a time. A `running` step whose `pid` is no longer alive is treated as `failed` ("interrupted").
- Writes are atomic (`Write-GIJsonAtomic`). Secrets (task password) are never written here.

## Module list: `$script:GIRequiredModules` (src/SetupModules.ps1)

`@{ Name; MinimumVersion; MaximumVersion (optional); Required = $true|$false; Note }` for Pode (2.x), VMware.PowerCLI,
Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore (required) and Pester 5.5+, PSScriptAnalyzer
(optional: a failure is reported but doesn't fail the step). Scope: AllUsers in Production, CurrentUser in Lab.

## Step functions

Every step function: `Invoke-GISetup<Step> -Config <hashtable> -State <setup state object>` returns
`@{ Message = '...'; Data = @{...} }` or throws. Progress lines go through
`Write-GISetupProgress -Config -Step -Line` (appends to `detail`, saves). Steps are idempotent: check first, skip
what's already in place, and say so in the message.

| Step | Function | Runs |
|---|---|---|
| Mode | `Set-GISetupMode -Config -Mode -By` | in the web request |
| Prerequisites | `Invoke-GISetupPrerequisites` | background process |
| Modules | `Invoke-GISetupModules` | background process |
| PowerCLI | `Invoke-GISetupPowerCLI` | background process |
| Vault | `Invoke-GISetupVault` | background process |
| DashboardAccess | `Invoke-GISetupDashboardAccess -Options @{ Port; CertThumbprint or CreateSelfSigned; ViewerGroup; ApproverGroup; AdminGroup }` | in the web request |
| Tasks | `Invoke-GISetupTasks -Credential` or `-Skip` | in the web request (password never leaves memory) |
| Finish | `Complete-GISetup` | in the web request |

Background steps run as `pwsh -NoProfile -File Pipeline/Invoke-GISetupStep.ps1 -Step <name> [-ConfigPath]`
(a separate process, so installing modules doesn't collide with modules loaded inside Pode), started by
`Start-GISetupStep -Config -Step`, which refuses if another step is running or the step isn't the next one
(a failed step can be retried).
