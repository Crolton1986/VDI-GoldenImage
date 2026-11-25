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
    "Maintain":  { "status": "Running",   "startedAt": "...", "endedAt": null,  "message": "", "data": {},
                   "steps": [ { "id": "Pkg:Horizon", "label": "Install Horizon Agent", "resumable": true,
                                "status": "Running", "startedAt": "...", "endedAt": null, "message": "Running 12 min (timeout 60 min)" } ] },
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
                  Endpoints = @{ Session = '/cv_api/sessions'; OnlineEntities = '/cv_api/online_entities'; Attachments = '/app_volumes/app_attachments' } }
  GoldenImage = @{
    VmName            = 'W11-GI-01'
    GuestCredentialSecret = 'GI-GuestAdmin'
    ScriptPathInGuest = 'C:\ProgramData\VDI\VDI-GoldenImage.ps1'
    InstallerSourceDir = ''   # optional host folder synced to <script dir>\Install in the guest
    Actions           = @('VmTools','Horizon','DEM','AppVolumes','FSLogix','MsTeams')   # run with -Unattended after updates
    WindowsUpdate     = @{ Enabled = $true; MaxPasses = 5 }
    FinalizeAction    = 'Finalize'
    PowerOffTimeoutMin = 90
    ActionTimeoutMin  = 60    # minutes per package install before it's stopped and the step fails
    GuestWorkDir      = 'C:\ProgramData\VDI\Pipeline'   # pipeline-owned guest folder; deleted by CleanupGuest
    Watcher = @{ LogPollSec = 10; IdlePollSec = 60; StatusPollSec = 60; WatchingWindowSec = 30
                 StaleHeartbeatSec = 180; MaxRelaunches = 3; MaxStepAttempts = 4; FixTimeoutSec = 600 }
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
    StuckMachineGraceMin = 10            # minutes a clone may sit in AGENT_UNREACHABLE / ERROR before it counts as stuck
    AutoRecreateStuckMachines = $true    # test pool only: delete stuck clones so Horizon provisions fresh ones
    MaxRecreateAttempts = 2
  }
  Snapshots = @{ NamePrefix = 'Baseline'; Mode = 'Chain'; Keep = 2; MaxChainDepth = 10; Prune = $false; ProtectAncestors = $true
                ConsolidateTimeoutMin = 60; MinFreeSpacePercent = 15; CleanupFailedRuns = $true }   # Prune=$false => report only
  Promotion = @{
    AutoPromote = $false
    MaintenanceWindow = @{ Days = @('Saturday'); StartTime = '22:00' }   # next window used when no -StartTime given
    PipelineSchedule  = @{ Day = 'Tuesday'; Time = '20:00' }               # weekly start of this image's scheduled task (VDI-GI-Pipeline-<id>)
  }
  Email = @{ Enabled = $false; SmtpServer = 'smtp.domain.local'; Port = 25; From = 'vdi-pipeline@domain.local'; To = @('vdi-team@domain.local'); UseSsl = $false }
  Dashboard = @{ Port = 8443; CertificateThumbprint = ''; ViewerGroup = 'DOMAIN\VDI-Pipeline-Viewers'; ApproverGroup = 'DOMAIN\VDI-Pipeline-Approvers'; AdminGroup = 'DOMAIN\VDI-Pipeline-Admins'; RefreshSeconds = 20 }
  # Optional Dashboard keys: AdDomain = 'corp.example.com' (default: the machine's domain), LegacyAdAuth = $true (Pode's own AD auth, no failed sign-in entries)
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
  `{ "action": "AppVolumes", "success": true, "errors": ["..."], "rebootRequired": false, "finishedAt": "...", "versions": { "VmTools": "...", "Horizon": "...", ... } }`
- `rebootRequired` is `true` when any installer in that run exited 3010 or 1641.

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
  - `packages`: string array chosen from `ItemValues` with one checkbox per item, saved in `ItemValues` order. The Packages
    section passes `Installers` (from `Get-GIInstallerStatus`) in its section data so the page can show each installer's host status,
  - `time`: `HH:mm`,
  - `secret`: the config value is the SecretManagement secret *name*. The form shows username +
    password for that secret; saving calls `Set-GISecretCredential`. The secret name itself is not
    editable in the UI. Password is never rendered back. Blank password = keep existing.
  - `table`: array of hashtables, `Columns = @( <field defs of type string|enum|int|bool> )`, add/remove rows.
- Optional on any field: `Help`, `Required`, `Warning` (shown next to the field, e.g. ProtectAncestors),
  `Confirm` (bool fields: a change needs confirmation, e.g. AutoPromote. The page asks in a dialog and the dialog ticks the
  `confirm_<Key>` checkbox, which stays in the page for browsers without JavaScript; the server still refuses the change without
  it), `Group = 'Advanced'` (the field goes into one collapsed "Advanced" block at the end of the form, opened when one of its
  fields has an error), `Inventory = 'vms'|'pools'` (string fields and table columns: a select filled from `GET /inventory` sits
  next to the text input; items used by another golden image are disabled; the text input stays the field, so typing always works).
- The Packages field shows `Check again` (a link to the same page, which reads the installer folder on every load) and a live line
  "Ticking X adds 1 step (Install X)". One ticked package is one Maintain step.

Settings API:

| Function | Behavior |
|---|---|
| `Get-GISettingsSchema` | Returns the schema |
| `Get-GISettingsSection -Config -Section` | `@{ Section; Values = @{ <Key> = <effective value> } }` read from merged Config (secret fields: `@{ Name; IsSet; UserName }` via `Get-GISecretStatus`) |
| `Test-GISettingsSection -Section -Values <hashtable>` | Returns `@{ <Key> = 'error text' }`, empty when valid. Values are already typed (see ConvertFrom-GISettingsForm) |
| `ConvertFrom-GISettingsForm -Section -Form <hashtable>` | Converts raw form strings to typed values per schema (`int`, bool from checkbox presence, list split on newlines and trimmed, days and packages from repeated checkbox values, table rows from `<Key>[<i>].<Col>` names). Secret fields are excluded. Returns `@{ Values; Errors }` |
| `Save-GISettingsSection -Config -Section -Values -By` | Validates, writes only the section's keys into settings.json (deep set), backup + atomic write, audit entry `settings.save` with field-level diff (`old`/`new`; secrets never included). Throws with all errors if invalid |

## Audit log: `state/audit.jsonl`

One JSON object per line: `{ "at": "<o>", "user": "DOMAIN\\x", "action": "...", "target": "...", "detail": {...} }`.
Actions: `settings.save`, `credential.set`, `connection.test`, `run.request`, `run.request.cancel`, `approval.approve`, `approval.reject`, `rollback.request`, `schedule.task`, `auth.signin`, `auth.signin.failed`.
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
{ "id": "<guid>", "action": "All|FromStage|Stage|PostCheck|Rollback", "stage": "Validate", "step": null,
  "runId": "20261124-213005", "pool": "PRD-W11", "snapshotName": null, "forceLogoff": false,
  "requestedBy": "DOMAIN\\x", "requestedAt": "<o>" }
```

- `New-GIRunRequest -Config -Action [-Stage] [-Step] [-RunId] [-Pool] [-SnapshotName] [-ForceLogoff] -RequestedBy`
  (`step` only with stage Maintain; must match `^[A-Za-z]+(:[A-Za-z]+)?$` and be one of the run's Maintain step ids)
  validates (stage in stage list minus Approval/Promote; runId pattern + file exists for FromStage/Stage;
  pool must be the test pool or a production pool from config for Rollback) and refuses if a request is
  already pending or the lock is held. Writes atomically, audits `run.request`/`rollback.request`.
- `Read-GIRunRequest -Config`: reads, deletes, re-validates, returns the request or `$null`.
- The dashboard then calls `Start-GIRunnerTask` (wraps `Start-ScheduledTask -TaskName VDI-GI-Runner`).
- `Invoke-GIPipeline.ps1 -FromRequest` executes it. `-FromStage <name> -RunId` runs that stage through Validate;
  a request `step` becomes `-FromStep`.

## Dashboard roles

`Dashboard.AdminGroup`: settings, credentials, Test connection, run controls. `ApproverGroup`: approve/reject.
`ViewerGroup`: read. Login accepts all three. `-NoAuth`: read-only. `-LocalAdmin`: binds 127.0.0.1, no auth,
caller is admin + approver (lab/smoke tests only).

### Sign-in (`src/Auth.ps1`, `Web/AuthSetup.ps1`)

Authentication is a custom Pode scheme. `Add-GIDashboardAuth` registers the method `AD`: the scheme parses the Basic header
(`ConvertFrom-GIBasicAuthHeader`, ISO-8859-1 like Pode's own scheme; no header = 401 challenge, malformed = 400) and hands user and
password to the validator `Invoke-GIDashboardSignIn`, which calls `Test-GIAdSignIn` and, in Windows only, `Invoke-GIAdBind`
(`System.DirectoryServices.AccountManagement`: `ValidateCredentials`, nested groups through `GetAuthorizationGroups`).
The user needs one of the three dashboard groups. The user object has Pode's AD shape (`Username`, `Name`, `Domain` = first label of the
domain, `Groups` = short names), so the role checks are unchanged. The domain is `Dashboard.AdDomain` (optional), else
`USERDNSDOMAIN`, else the machine's domain.

A failed sign-in writes `auth.signin.failed` (result `Failed`): `user` is the attempted name as typed (control characters removed, 128
characters at most), `detail` is `{ reason, source }`, reason being `badCredentials`, `notAuthorised` (valid password, no dashboard group) or
`directoryError` (the domain could not be asked; the response is 503). `source` is the client address. The password is never written to the
audit log, to a log, to an exception message or to a return value; `Write-GISignInFailed` has no parameter that could take it. At most one
entry per user and source per minute, and 30 per source per minute. A request without credentials, or with a malformed header, is not a
failed sign-in and is not written. Successful sign-ins stay `auth.signin`, once per user per 8 hours.

`Dashboard.LegacyAdAuth = $true` in `pipeline.config.psd1` goes back to Pode's own Windows AD authentication (no failed sign-in entries).

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

## Maintain sub-steps

`run.stages.Maintain.steps` is rebuilt at the start of every Maintain attempt from the config:
`RevertFailedRun, SafetySnapshot, RemoveFailedRunSnapshots, PowerOn, CopyScript, CopyInstallers, StartWatcher, EnableUpdates, WindowsUpdate, Pkg:<Action>..., Reboot, Manifest, CleanupGuest, Finalize, PowerOff`.
EnableUpdates, WindowsUpdate and Pkg:* run inside the guest watcher (next section); the host mirrors them.
Steps that don't apply are `Skipped` with the reason as message. `resumable` steps (RevertFailedRun, SafetySnapshot, RemoveFailedRunSnapshots, EnableUpdates,
WindowsUpdate, Pkg:*) that succeeded before the resume point keep their result on a retry and aren't run again;
all other steps run on every attempt. Resume happens when the previous attempt left a step Failed or Running, or
when `-FromStep` is given. A snapshot revert task on the VM (vCenter event `VirtualMachine.revertToSnapshot` or
`revertToCurrentSnapshot`) since the earliest recorded step start forces a full restart.

- `Initialize-GIMaintainSteps -Config -Run -Plan [-ResumeFrom]` returns the step work resumes at ('' when fresh).
- `Set-GIStep -Config -Run -Id [-Status] [-Message]` updates one step and mirrors it into `run.progress`.
- `Get-GIStepList -Run`, `Get-GIStep -Run -Id` read them; `Set-GIProgress` also writes its message to the running step.
- Guest steps (EnableUpdates, WindowsUpdate, Pkg:*) run in the guest watcher; see "Guest watcher" below.
  `Invoke-GIGuestAction` without `-TimeoutMin` (synchronous) stays for Manifest and Finalize.
  `Wait-GIGuestScriptAsync` is removed.

### Failed-run safety snapshots

`Get-GIFailedRunSnapshots -Snapshots -RunStatus -CurrentRunId -ProtectedNames` (pure) treats `pre-maint-<RunId>[-HHmmss]`
as a leftover when its run is Failed, Rejected, RolledBack, Cancelled or its run file is missing, and it isn't the
current run's or a protected name. `RevertTo` is the oldest leftover in the unbroken chain of leftovers that ends at
the VM's current snapshot (`$null` when the current snapshot isn't a leftover). `Get-GIFailedRunSnapshotPlan` feeds it
from `Get-Snapshot` and the run files. With `Snapshots.CleanupFailedRuns` (default on), Maintain's `RevertFailedRun`
step reverts to `RevertTo` (VM must be off) and `RemoveFailedRunSnapshots` removes the leftovers oldest first after the
new safety snapshot, with consolidation and a Horizon re-check after each. Removal is skipped while Horizon usage
can't be read or a push is pending. When the setting is off, both steps only report. A safety snapshot is matched
to its run by snapshot id, not name. The revert check that forces a full restart ignores Maintain's own revert.

---

# Guest watcher (Maintain guest steps)

The host hands EnableUpdates, WindowsUpdate and every `Pkg:<Action>` to a watcher process in the guest. The watcher
runs them in order, writes one status file per step and a log, recognizes known failures and applies drop-in fix
scripts, and asks the host for reboots. Reboot, Manifest, Finalize and PowerOff stay host-driven.

## Files

Host repository:

```
Pipeline/guest/Invoke-GIWatcher.ps1       # watcher entry point (Windows PowerShell 5.1)
Pipeline/guest/GIWatcher.Core.ps1         # pure functions, dot-sourced by the watcher and by Pester
Pipeline/guest/Invoke-GIFixRunner.ps1     # runs one fix in a child process
Pipeline/guest/Invoke-GIWindowsUpdate.ps1 # one WU pass (unchanged contract, now started by the watcher)
Pipeline/guest/fixes/<FixId>.ps1          # one file per fix
Pipeline/src/Watcher.ps1                  # host: plan, launch, poll, mirror, cleanup
Pipeline/src/WatcherLog.ps1               # host: watcher log slices for the dashboard, "watching" marker
Pipeline/tests/GuestWatcher.Tests.ps1, Fixes.Tests.ps1, fixes/<FixId>.Tests.ps1, Watcher.Tests.ps1, WatcherLog.Tests.ps1
```

Guest, under `<W>` = `GoldenImage.GuestWorkDir` (default `C:\ProgramData\VDI\Pipeline`):

```
<W>\watcher\Invoke-GIWatcher.ps1, GIWatcher.Core.ps1, Invoke-GIFixRunner.ps1, Invoke-GIWindowsUpdate.ps1
<W>\fixes\*.ps1
<W>\plan.json
<W>\watcher.json
<W>\watcher.log
<W>\steps\<FileId>.json              # FileId = step id with ':' replaced by '_'  (Pkg:Horizon -> Pkg_Horizon)
<W>\steps\<FileId>.<attempt>.out.txt # child process stdout+stderr for that attempt
<W>\steps\<FileId>.<attempt>.result.json  # -ResultFile of VDI-GoldenImage.ps1 / WU result for that attempt
<W>\fixes-run\<FileId>.<attempt>.context.json / .result.json   # fix runner I/O
```

All guest JSON is UTF-8. Timestamps: ISO 8601 with offset (`(Get-Date).ToString('o')`), guest clock.

## Atomic writes and reads

Writer (`Write-GIWatcherJson -Path -InputObject`, guest core): serialize (`ConvertTo-Json -Depth 8`), write
`<Path>.tmp`, then `[System.IO.File]::Replace(tmp, Path, $null)` when `Path` exists, else
`[System.IO.File]::Move(tmp, Path)`. Retry up to 10 times, 100 ms apart, on IOException (a reader has it open).
`Move-Item -Force` is not used: on PS 5.1 it deletes the target first.

Reader (`Read-GIWatcherJson -Path`, guest core; host parses the same text): missing file, empty file, or JSON that
fails to parse returns `$null`. Never throws. The host keeps the last good value when a read returns `$null`.

## plan.json (host writes, watcher reads)

```json
{
  "schemaVersion": 1,
  "runId": "20261124-213005",
  "attemptId": "6f1c...",            // new GUID per Maintain attempt; same across relaunches within the attempt
  "launchId": "a93b...",             // new GUID per launch (first launch and every relaunch)
  "createdAt": "<o>",
  "scriptPath": "C:\\ProgramData\\VDI\\VDI-GoldenImage.ps1",
  "workDir": "C:\\ProgramData\\VDI\\Pipeline",
  "installDir": "C:\\ProgramData\\VDI\\Install",
  "logDir": "C:\\ProgramData\\VDI\\Logs",
  "settings": { "heartbeatSec": 15, "maxStepAttempts": 4, "fixTimeoutSec": 600 },
  "steps": [
    { "id": "EnableUpdates", "kind": "Action", "action": "Update" },
    { "id": "WindowsUpdate", "kind": "WindowsUpdate", "maxPasses": 5 },
    { "id": "Pkg:Horizon",   "kind": "Action", "action": "Horizon" }
  ]
}
```

`steps` lists only the guest steps the host wants run this attempt, in order (host leaves out steps that are Skipped
or already Succeeded in the run state). Step ids match `run.stages.Maintain.steps[].id` exactly.

## Step status file: steps\<FileId>.json (watcher writes, host reads)

```json
{
  "schemaVersion": 1,
  "runId": "20261124-213005",
  "attemptId": "6f1c...",
  "id": "Pkg:Horizon",
  "status": "Fixing",
  "attempt": 2,                       // 1-based; every start of the step's work counts (retries, interruptions)
  "attemptStartedAt": "<o>",
  "startedAt": "<o>",                 // first attempt in this attemptId
  "endedAt": null,
  "heartbeat": "<o>",                 // refreshed every settings.heartbeatSec while the step is active
  "exitCode": 1,                      // last finished attempt; null before one finishes
  "message": "Attempt 1 failed; applying fix RegistryKeyMarkedForDeletion",
  "originalError": "ERROR: Installation failed: This command cannot be run due to the error: Illegal operation attempted on a registry key that has been marked for deletion.",
  "fixApplied": [
    { "id": "RegistryKeyMarkedForDeletion", "fixAttempt": 1, "stepAttempt": 1, "at": "<o>", "outcome": "Applied", "message": "..." }
  ],
  "pendingFix": null,                 // { "id", "fixAttempt" } while waiting for a host reboot before the retry
  "rebootAfter": false,               // step Succeeded and wants a reboot before the next step
  "data": {}                          // Action: { "versions": {...}, "rebootRequired": bool }; WindowsUpdate: { "pass": 2, "passes": [ {pass,found,installed,failed,reboot} ] }
}
```

Status enum: `Pending | Running | Fixing | RebootRequired | Succeeded | Failed`.
`fixApplied[].outcome`: `Applied | FixFailed | TimedOut`.

## watcher.json (watcher writes, host reads)

```json
{ "schemaVersion": 1, "pid": 4242, "launchId": "a93b...", "attemptId": "6f1c...", "startedAt": "<o>",
  "heartbeat": "<o>", "currentStep": "Pkg:Horizon",
  "state": "Running", "exitReason": null, "endedAt": null }
```

`state`: `Running | Exited | RebootRequested`. `exitReason` when not Running: `AllDone | StepFailed | RebootRequested | PlanError | Crashed`.

## watcher.log

Append-only, never truncated by the watcher, UTF-8 without BOM (`[System.IO.File]::AppendAllText` with
`New-Object System.Text.UTF8Encoding $false`). One line per entry, `\r\n` terminated, tab-separated:

```
<o timestamp>\t<LEVEL>\t<stepId or ->\t<message>
```

`LEVEL`: `INFO | WARN | ERROR | OUT` (`OUT` = a line of the step's child process output). Tabs and newlines inside a
message are replaced with a space. Watcher-level lines use `-` as step id.

## Watcher behavior (Invoke-GIWatcher.ps1 -WorkDir <W>)

1. Read plan.json. Invalid or missing: write watcher.json `state=Exited, exitReason=PlanError`, log, exit 2.
2. Write watcher.json (`Running`, own pid, launchId). Load the fix catalog from `<W>\fixes`.
3. For each plan step, in order, read its status file and decide (`Get-GIStepStartDecision`):
   - file `runId` = plan `runId` and status `Succeeded` -> skip (log "already succeeded").
     If it also has `rebootAfter = true` and it was the last step to run before this launch, nothing more: the
     host already rebooted (a launch always follows the requested reboot).
   - file `attemptId` != plan `attemptId` (or no file) -> reset: new file, `attempt = 0`, `fixApplied = []`.
   - same attemptId, status `Running` or `Fixing` -> interrupted (watcher died or the guest rebooted). Log a WARN,
     continue the step as a new attempt.
   - same attemptId, status `RebootRequired` -> the reboot happened; if `pendingFix` is set, run that fix's
     post-reboot part (`Invoke-GIFix` with `Context.Phase = 'AfterReboot'`), then retry. WindowsUpdate continues at `data.pass + 1`.
   - same attemptId, status `Failed` -> stop: watcher.json `Exited/StepFailed`, exit 1 (host decides).
4. Before each attempt: if `attempt + 1 > settings.maxStepAttempts`, the step is `Failed` with
   message `Gave up after <n> attempts: <originalError>`. Otherwise `attempt++`, `status = Running`,
   `attemptStartedAt = now`.
5. Run the attempt in a fresh child `powershell.exe -NoProfile -ExecutionPolicy Bypass` with stdout and stderr
   redirected to `<FileId>.<attempt>.out.txt`:
   - `Action`: `& <scriptPath> -Action <action> -Unattended -ResultFile <FileId>.<attempt>.result.json`
   - `WindowsUpdate`: `Invoke-GIWindowsUpdate.ps1 -ResultFile <FileId>.<attempt>.result.json` (one pass)
   While it runs, every `heartbeatSec`: refresh heartbeat in the step file and watcher.json, and copy new lines of the
   out file to watcher.log as `OUT` lines.
6. Evaluate (`Get-GIAttemptOutcome`):
   - Action success = exit code 0 and result `success` true (missing result file = failure). On success:
     `Succeeded`, `exitCode = 0`, `data.versions`, message `Installed version <v>` (or `Done`). If the result has
     `rebootRequired: true`: `rebootAfter = true`, watcher.json `RebootRequested`, exit 0 without starting the next step.
   - WindowsUpdate: result `error` set = failure. Else if `rebootRequired`: append pass to `data.passes`,
     `data.pass = n`, status `RebootRequired`, watcher.json `RebootRequested`, exit 0. Else if `found = 0` or
     `pass >= maxPasses`: `Succeeded` (message as today, with "Updates still pending after N passes." when found > 0).
     Else run the next pass in the same launch.
7. On failure, the error text is built from (`Get-GIStepErrorText`): `Errors` = result-file `errors` joined with
   `; ` (or WU `error`); `Output` = last 200 lines of the out file; `Log` = last 200 lines of the newest
   `*.log` in `logDir` modified since `attemptStartedAt`. `originalError` is set once, from the first failed
   attempt (`Errors`, falling back to the last non-empty `Output` line, then `exit code <n>`).
8. Fix selection (`Select-GIFix`, next section). No match, or the matched fix's attempts are used up for this step:
   `Failed`, message `In-guest action '<action>' exited <code>: <originalError>` (same wording as today), watcher
   exits 1 with `StepFailed`. Match: `status = Fixing`, run the fix (below), record `fixApplied`, then:
   - fix wants a reboot before the retry (`fixAttempt >= RebootFromAttempt`, RebootFromAttempt > 0): `pendingFix`
     set, `status = RebootRequired`, watcher.json `RebootRequested`, exit 0.
   - else retry at step 4.
   - fix outcome `FixFailed`/`TimedOut`: the step still retries (the attempt cap bounds this); the outcome is logged.
9. All plan steps Succeeded: watcher.json `Exited/AllDone`, exit 0.

The watcher catches everything at top level: unexpected error -> current step stays as is, watcher.json
`Exited/Crashed`, ERROR log line, exit 3.

## Fix scripts: Pipeline/guest/fixes/<FixId>.ps1

```powershell
$GIFix = @{
    Id                = 'RegistryKeyMarkedForDeletion'   # = file base name; ^[A-Za-z][A-Za-z0-9]+$
    Description       = 'One line, shown in the log and dashboard'
    Priority          = 100                               # lower runs first; ties by file name (ordinal)
    Actions           = @('*')                            # action names (Horizon, VmTools, Update ...), 'WindowsUpdate', or '*'
    MaxAttempts       = 2                                 # per step, per Maintain attempt; 1..5
    RebootFromAttempt = 2                                 # 0 = never; n = from the n-th time this fix is applied, reboot before the retry
    Match = @{
        ExitCodes = @(1)                                  # empty/absent = any non-zero
        Patterns  = @('registry key that has been marked for deletion')   # regex, case-insensitive; at least one required
        Sources   = @('Errors', 'Output', 'Log')          # where Patterns are searched; default all three
    }
}

function Invoke-GIFix {
    param([Parameter(Mandatory)] $Context)
    # ... remediation ...
    return @{ Ok = $true; Message = 'what was done' }
}
```

- Metadata is read without running the file: `Read-GIFixCatalog -Path <dir>` parses each file with
  `[System.Management.Automation.Language.Parser]::ParseFile`, finds the top-level assignment to `$GIFix`, and
  evaluates it with `SafeGetValue()` (throws on anything but literals, arrays and hashtables). It validates the keys
  above (`Test-GIFixMetadata` returns error strings). Invalid files are returned with `Valid = $false` and the
  errors, logged as WARN and never selected. The file must also define `function Invoke-GIFix`.
- Matching (`Select-GIFix -Catalog -Action -ExitCode -ErrorText @{ Errors; Output; Log } -Applied <fixApplied[]>`):
  valid fixes sorted by Priority then file name; a fix matches when the action matches (`'*'` or listed;
  `'WindowsUpdate'` for the WU step), the exit code matches (`ExitCodes` empty means any non-zero), and at least one
  Pattern matches the text of at least one listed Source. First match wins, but a fix whose count in `Applied`
  (`fixAttempt` count for that id) has reached `MaxAttempts` is passed over and selection continues. Returns
  `@{ Fix; FixAttempt; RebootBeforeRetry }` or `$null`.
- Running: the watcher writes `fixes-run\<FileId>.<attempt>.context.json` and starts a child
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <W>\watcher\Invoke-GIFixRunner.ps1 -FixPath <file>
  -ContextPath <ctx> -ResultPath <res>`, waits up to `settings.fixTimeoutSec` (then kills that child only:
  outcome `TimedOut`). The runner dot-sources the fix and calls `Invoke-GIFix -Context`; any throw = `FixFailed`.
- `Context`: `@{ StepId; Action; Phase = 'BeforeRetry'|'AfterReboot'; ExitCode; ErrorText = @{Errors;Output;Log};
  FixAttempt; StepAttempt; WorkDir; ScriptPath; InstallDir; LogDir; WatcherPid; ProtectedPids }`. The runner also
  defines helpers the fix may call:
  - `Stop-GIAllowedProcess -Name <name> | -InstallDirOnly` : stops only `msiexec` processes or processes whose
    image path is under `InstallDir`, and never `WatcherPid`, any pid in `ProtectedPids` (the watcher, its parent
    chain, the runner itself). Returns the stopped pids.
  - `Wait-GIMsiIdle -TimeoutSec` : waits until the `Global\_MSIExecute` mutex is free; returns `$true`/`$false`.
  - `Write-GIFixLog -Message` : appends a line to watcher.log under the step id.
- Rules every fix follows (enforced by `Fixes.Tests.ps1` with an AST scan): no calls to `Stop-Process`,
  `taskkill`, `Restart-Computer`, `Stop-Computer`, `shutdown`, `Unregister-ScheduledTask`, `Stop-ScheduledTask`,
  `Remove-Item` on `WorkDir`/`$Context.WorkDir`; no `Invoke-Expression`/`iex`, `wmic` or `.Kill()`; no PowerShell 7-only
  syntax (`??`, `?.`); only the `$GIFix` assignment and function definitions at top level; reboots are requested only through
  `RebootFromAttempt`. Adding a fix = one file in `guest/fixes` plus one test in `tests/fixes`. No edit to the
  watcher, the host or `VDI-GoldenImage.ps1`.

### Shipped fix: RegistryKeyMarkedForDeletion

Matches any action, exit code 1, pattern `registry key that has been marked for deletion` in Errors/Output/Log.
`MaxAttempts = 2`, `RebootFromAttempt = 2`. Fix attempt 1 (Phase BeforeRetry): stop leftover installer processes
from InstallDir through `Stop-GIAllowedProcess`, wait up to 60 s for `Wait-GIMsiIdle`; if still busy, stop msiexec
and wait up to 240 s more (Ok = false when it stays busy), then the step
retries in a fresh child process (fresh token and hive). Fix attempt 2: same cleanup, then the host reboots (unloads
every stale hive), Phase AfterReboot logs the boot time and returns, the step retries. A third failure fails the
step with the original error. Since the watcher runs as SYSTEM (no roaming user hive), the error should be rare;
the fix is the safety net.

## Host lifecycle (src/Watcher.ps1)

Functions (pure ones marked *, testable without PowerCLI):

| Function | Behavior |
|---|---|
| `New-GIWatcherPlan -Config -Run -AttemptId` * | plan object for the run's guest steps that are not Succeeded/Skipped |
| `Get-GIWatcherStepIds -Run [-All]` * | ids of the run's guest steps; membership via `Test-GIWatcherStep -Id`, defined in src/WatcherLog.ps1 |
| `Start-GIGuestWatcher -Config -Run -VM -Credential -AttemptId [-ResetSteps]` | copies `guest/Invoke-GIWatcher.ps1`, `GIWatcher.Core.ps1`, `Invoke-GIFixRunner.ps1`, `Invoke-GIWindowsUpdate.ps1` to `<W>\watcher\`, `guest/fixes/*.ps1` to `<W>\fixes\` (folder emptied first), writes plan.json (new launchId), with `-ResetSteps` deletes `<W>\steps\`; registers scheduled task `VDI-GI-Watcher` (SYSTEM, RunLevel Highest, priority 4, no trigger, `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <W>\watcher\Invoke-GIWatcher.ps1 -WorkDir <W>`, ExecutionTimeLimit 0) with `-Force`, starts it. Returns `@{ LaunchId; BootTime }` |
| `Get-GIWatcherPollScript -WorkDir -LogOffset -IncludeSteps` * | the guest script text for one tick |
| `ConvertFrom-GIWatcherPoll -Text` * | parses tick output: `@{ Now; BootTime; Watcher; PidAlive; TaskState; Steps; Log = @{ Offset; Size; Bytes } }` |
| `Split-GIWatcherLogChunk -Bytes -Offset` * | consumes complete lines only: `@{ Lines = string[]; NextOffset }`; bytes after the last `\n` are left for the next tick |
| `Test-GIWatcherDead -Watcher -PidAlive -Now -StaleSec` * | `$true` when heartbeat older than StaleSec (guest clock) and the pid is not alive; `$false` when Exited cleanly |
| `Test-GIStepTimedOut -Step -Now -TimeoutMin` * | guest now - attemptStartedAt > TimeoutMin, for Running/Fixing steps |
| `ConvertTo-GIRunStepUpdate -GuestStep` * | `@{ Status; Message; Attempt; Fixes }` per the mapping below |
| `Sync-GIWatcherSteps -Config -Run -GuestSteps` | applies the mapping with `Set-GIStep` only when status/message changed; adds `attempt` and `fixes` to the run step |
| `Get-GIWatcherPollInterval -Config -RunId` * | `LogPollSec` when `Get-GIRunWatchingAge` < `WatchingWindowSec`, else `IdlePollSec` |
| `Wait-GIGuestWatcher -Config -Run -VM -Credential -AttemptId` | the poll loop below; returns when every plan step Succeeded, throws on failure |
| `Stop-GIGuestWatcher -VM -Credential -WorkDir -Pid` | stop task, stop the watcher pid's process tree, stop msiexec and InstallDir processes |
| `Remove-GIGuestWatcher -Config -Run -VM -Credential` | CleanupGuest: copy log, unregister task, delete `<W>` (guarded) |

Guest scripts sent by the host are built from validated values only (paths from config, step ids matching
`^[A-Za-z]+(:[A-Za-z]+)?$`), single quotes doubled.

Status mapping (guest -> run step):

| Guest | Run step status | Message |
|---|---|---|
| Pending | Pending | '' |
| Running | Running | `Attempt <n>: <message>` (n > 1) or `<message>` |
| Fixing | Running | `Attempt <n>: applying fix <id>` |
| RebootRequired | Running | `Reboot requested (<fix id> / Windows Update pass <n> / installer)` |
| Succeeded | Succeeded | message (+ `; fixed by <ids>` when fixApplied is non-empty) |
| Failed | Failed | message |

Poll loop (`Wait-GIGuestWatcher`):

- Tick interval from `Get-GIWatcherPollInterval` (re-evaluated every tick). One `Invoke-VMScript` per tick: returns
  guest now, last boot time, watcher.json, whether its pid is alive, task state, and up to 64 KB of watcher.log
  from the stored offset (base64). Every `StatusPollSec` (and on the first tick, and whenever watcher.json changed
  state) the same call also returns every steps\*.json.
- Log: `Split-GIWatcherLogChunk`; lines appended to host `logs/<RunId>.watcher.log` unchanged; offset stored in
  `run.stages.Maintain.data.watcher = @{ logOffset; launchId; attemptId; bootTime; relaunches }`, saved each tick.
  Guest file size < offset (revert, new file): offset resets to 0.
- Guest call fails: tolerated (Tools restarting during VmTools); 10 consecutive failures throw
  `Lost contact with the guest watcher`.
- Mirror steps with `Sync-GIWatcherSteps`. Any guest step `Failed`: throw its message (Maintain fails, the step is
  already Failed in the run).
- watcher.json `RebootRequested`: `Restart-GIGuest`, then `Start-GIGuestWatcher` (same attemptId). Not counted
  against `MaxRelaunches` (each step's attempt cap bounds these).
- Boot time changed without a host reboot, or `Test-GIWatcherDead`, or watcher.json `Exited/Crashed`: relaunch,
  counted; more than `MaxRelaunches` throws `Guest watcher died <n> times`. Stale heartbeat with a live pid: WARN
  in the run log once per step attempt; the timeout handles a real hang.
- Timeout: `Test-GIStepTimedOut` with `GoldenImage.ActionTimeoutMin` (per attempt; WindowsUpdate uses
  `GoldenImage.WindowsUpdate.PassTimeoutMin`, default 120): `Stop-GIGuestWatcher`, step Failed
  `Timed out after <n> min (attempt <k>); installer processes were stopped. See the install logs in <logDir>.`, throw.
- Done when every plan step is Succeeded in the guest and watcher.json is `Exited/AllDone`. A step with
  `rebootAfter` that is the last plan step: the host reboots anyway before returning.

Maintain wiring (src/Stages.ps1):

- `StartWatcher` (not resumable): new attemptId per Maintain attempt (stored in `data.watcher.attemptId`);
  `-ResetSteps` when Maintain starts fresh or restarts from SafetySnapshot; then `Start-GIGuestWatcher`. Skipped with
  "No guest steps" when the plan is empty.
- The EnableUpdates / WindowsUpdate / Pkg:* blocks become one `Wait-GIGuestWatcher` call. `ctx.data.windowsUpdate`
  comes from the WU step's `data.passes`; `ctx.data.actions` as before.
- `CleanupGuest` (not resumable), after Manifest: `Remove-GIGuestWatcher`. Copies `<W>\watcher.log` to
  `logs/<RunId>.watcher.guest.log` (`Copy-VMGuestFile -GuestToLocal`; a copy failure is a WARN, not a failure),
  `Unregister-ScheduledTask VDI-GI-Watcher`, then `Remove-Item <W> -Recurse -Force`. Refuses (throws) when `<W>` is
  empty, a drive root, or equal to or a parent of the guest script folder. Manifest and Finalize still use
  `Invoke-GIGuestAction`, which writes `result-*.json` to `<W>`; Finalize recreates `<W>` as needed, and those
  leftovers are the only pipeline files left in the image (they hold versions, no secrets).

## Dashboard (src/WatcherLog.ps1, Web/)

- `Read-GIWatcherLogSlice -Path -StepId -Offset [-MaxBytes 262144]` *: reads host `logs/<RunId>.watcher.log` from
  byte `Offset`, complete lines only, returns `@{ Lines = @(@{ at; level; step; text }); Offset = <next> }` filtered
  to `StepId`. Missing file: no lines, offset unchanged.
- `Set-GIRunWatching -Config -RunId` touches `state/<RunId>.watching`; `Get-GIRunWatchingAge -Config -RunId`
  returns seconds since last touch or `[double]::MaxValue`.
- Route `GET /runs/:runId/steps/:stepId/log?offset=N` (viewer role): validates runId and stepId patterns, calls
  `Set-GIRunWatching`, returns JSON `{ lines: [...], offset: N, running: bool }`.
- Run page: each Maintain step for which `Test-GIWatcherStep` is true gets a `<details class="steplog">` row with the
  step's lines rendered server-side (last 200). While open and the step is Running, inline JS fetches the route every
  `LogPollSec` (10 s) from the last offset and appends. Works without JS (lines on reload).


## Multi-image model (UI redesign)

See `ADR-0001-multi-image.md`. `Get-GIImageEntries`, `Get-GIImageConfig`, `Test-GIImageConstraints`, `Invoke-GIConfigMigration`, `New-GIImageFromPayload`, `Save-GIImageSection`, `Set-GIImagePaused`, `Remove-GIImageEntry` live in `src/Images.ps1`. Run state has `imageId`. `Invoke-GIPipeline.ps1 -ImageId <id>` picks the image; without it one image is used, or All, PostCheck, Status and -FromRequest go through every image.

## Image API

All under `/api`, JSON. Errors: `{ "error": "text", "errorId": "8 hex chars" }` (errorId only for 500). Writes need the `X-GI-Token` header (or `token` in the body) and a same-origin request. Roles: Viewer (read), Approver (approve, reject), Admin (everything). A forbidden call returns 403 and writes an `auth.denied` audit entry. Implemented by `Invoke-GIApiRequest` in `src/ImageApi.ps1`.

| Method and path | Role | Result |
|---|---|---|
| `GET /images` | any | `{ images: [ { id, name, description, os, paused, vm, testPool, productionPools, packages, autoPromote, schedule, maintenanceWindow, lastRun, activeRun, lastKnownGood } ] }`. No live calls. |
| `GET /images/{id}/live` | any | `{ checkedAt, vm: { name, power, snapshots: [ { name, created, isCurrent } ], latestSnapshot, outsideRetention: [ { name, reason } ] or null } or null, pools: [ { pool, snapshot, pending, state, matchesLatest } ], lastKnownGood, errors: [ "vCenter did not answer within 15 seconds" ] }` |
| `GET /images/{id}/runs?status=&page=` | any | `{ runs, page, pageSize, total }`, newest first, 20 per page |
| `GET /images/{id}/runs/{runId}` | any | `{ run, imageId, steps: [ { id, label, status, startedAt, endedAt, message, logLines, fixApplied } ], approval: { decision, by, at, validation, poolsToUpdate, nextWindow }, logBundleUrl }` |
| `GET /images/{id}/runs/{runId}/steps/{stepId}/log?tail=N` | any | `{ lines, running, total }` |
| `GET /images/{id}/packages` | any | installer status per package: id, name, selected, state (Found, Download, Missing, NoFolder), file, version, sizeMB, modified |
| `GET /packages?folder=<path>` | Admin | installer status (same shape as `/images/{id}/packages`, without `selected`) for a folder on the pipeline host; the wizard uses it before the image exists. Read only. |
| `GET /fixes` | any | the fix catalog from `guest/fixes` (id, description, priority, actions, maxAttempts, rebootFromAttempt, match, lastUsedRunId). Never runs a fix. |
| `GET /runs/{runId}/logs.zip`, `GET /images/{id}/runs/{runId}/logs.zip` | any | log bundle, named `<imageName>-<RunId>-logs.zip` |
| `GET /images/{id}/settings/{section}`, `GET /settings/{section}` | any | `{ section, values }`; secret fields show names and status only |
| `POST /images` | Admin | 201 `{ id, name }`; validated with the settings rules and the constraints; starts no run |
| `POST /images?dryRun=1[&step=N]` | Admin | validates only, saves nothing. `step` 1 to 4 reports only the problems of that wizard step (1 Basics: name; 2 Guest VM and pools: VM, pools, constraints against other images; 3 Windows Update and packages; 4 Schedule and promotion); without `step` every problem. 200 `{ valid, step }` or 400 `{ error }`. The wizard calls it on every Next and on Review. |
| `POST /images/{id}/settings/{section}` | Admin | sections: General, GoldenImage, Pools, Validation, Snapshots, Promotion, AppVolumes (test packages). Saving Promotion with a changed `PipelineSchedule.Day` or `.Time` also moves the image's weekly task and adds `scheduleTask: { ok, code, detail }` (code: `updated`, `missing`, `failed`, `notwindows`) to the answer. The save itself succeeds either way. |
| `POST /images/{id}/settings/{section}/test` | Admin | GoldenImage or Pools only. Body: the page's form fields (`VmName`, `Test.Name`, `Production[0].Name` ...), unsaved values included, secrets ignored. Nothing is saved. `{ ok, detail, seconds }`; 400 with the field errors when the values are invalid. |
| `POST /settings/{section}` | Admin | vCenter, Horizon, AppVolumes, Email |
| `POST /settings/{section}/test` | Admin | tests the posted (unsaved) values; `{ ok, detail, seconds }`. The result and time (never the detail) are remembered per section in `state/connection-tests.json` and shown as a Connected / Failed / Not tested chip; saving the section or its credential resets it to Not tested. |
| `POST /images/{id}/pause`, `/resume` | Admin | |
| `DELETE /images/{id}` | Admin | removes the image from the config only; 409 while a run is active |
| `POST /images/{id}/runs` | Admin | 202; 409 when paused or a run is active |
| `POST /images/{id}/runs/{runId}/retry` | Admin | retry from the failed stage (optional `step`); 409 unless the run is Failed |
| `POST /images/{id}/runs/{runId}/approve` | Approver, Admin | optional `startTime`, `comment`; 409 "Already approved by X at HH:mm" |
| `POST /images/{id}/runs/{runId}/reject` | Approver, Admin | `comment` required |
| `POST /images/{id}/vm/power` | Admin | `{ action: "on" or "off" }`; 409 while a run is active |
| `POST /images/{id}/vm/revert` | Admin | `{ snapshot }`; 409 while a run is active |
| `POST /images/{id}/pools/{pool}/rollback` | Admin | `{ snapshot?, logoffPolicy, startTime?, runId? }`; marks the run RolledBack |

Audit entries (each has time, user, role, image, action, details, result): `image.create`, `image.update`, `image.pause`, `image.resume`, `image.delete`, `image.migrate`, `vm.power`, `vm.revert`, `pool.rollback`, `settings.update` (section and changed keys, never values of secrets), `run.start`, `run.retry`, `approval.approve`, `approval.reject`, `connection.test`, `schedule.task` (target = the task name, details = outcome code and message), `auth.denied`, `api.error`, and the sign-in entries `auth.signin` and `auth.signin.failed` (see Sign-in above).

Run steps in `GET /images/{id}/runs/{runId}` carry `resumed` (true when the step was kept from an earlier attempt; runs saved before the flag existed are recognised by the `(earlier attempt)` suffix of the message). `Get-GIPoolLastPushed` (src/Images.ps1) derives when each pool last received an image from the run history (TestPush for the test pool, a Succeeded promotion entry for production pools); rollbacks are not runs and are not counted.

## Scheduled tasks

`Get-GIPipelineTaskDefinition -Root -Config` returns one weekly task per golden image, `VDI-GI-Pipeline-<id>` running `Invoke-GIPipeline.ps1 -Stage All -ImageId <id>` at that image's `Promotion.PipelineSchedule` (`-PipelineDay` and `-PipelineTime` override every image), plus the shared `VDI-GI-PostCheck` (every image, hourly), `VDI-GI-Dashboard` and `VDI-GI-Runner`. Without a config that lists images it returns the old single `VDI-GI-Pipeline` (-Stage All, every image). `Register-GIPipelineTask` removes the old single task and the task of an image that no longer exists when it registers per-image tasks (results carry `Removed = $true` for those); `Unregister-GIPipelineTask` removes every `VDI-GI-Pipeline-*` task too. A paused image keeps its task; the script skips it.

`Set-GIPipelineScheduleTask -Config <image config> | -Config <root> -ImageId` sets the weekly trigger of that image's task and returns `@{ ok; code; detail }`. It never creates a task (that needs the account password): a new image has no task until `Register-GIPipelineTasks.ps1` runs again, and the Promotion page says so. `Update-GIImageScheduleTask` is the call the page and the API make after a save; it does nothing unless the day or time changed and writes `schedule.task`.

## Guest logs

Maintain has a step `CollectGuestLogs` ("Collect guest logs") right before `CleanupGuest`, and any failing Maintain step (or a failing guest step) triggers the same collection first, while the guest is still on. It runs a guest script (`Get-GIGuestLogScript`) that gathers the watcher log and step files, the guest script and installer logs, Windows Update, CBS and DISM logs, `Get-WindowsUpdateLog` output, `MSI*.LOG`, Horizon, DEM, App Volumes, FSLogix, Teams, OneDrive and VMware Tools logs, and an event log extract (errors and warnings, installer and update providers, from the run start). Each file is capped at 20 MB (last part kept, noted in `_collection-notes.txt`); files with credential-like names are skipped. The result is zipped in the guest, copied once and expanded to `<Logs>/<RunId>/guest/`. An unreachable guest marks the step Skipped with the reason; collection never fails a run. The bundle (`New-GILogBundle`) streams a zip with `host/`, `run.json`, `report.html`, `guest/` and a `README.txt` that lists what is inside and anything missing or truncated.
