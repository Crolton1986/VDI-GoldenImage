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
  }
  Email = @{ Enabled = $false; SmtpServer = 'smtp.domain.local'; Port = 25; From = 'vdi-pipeline@domain.local'; To = @('vdi-team@domain.local'); UseSsl = $false }
  Dashboard = @{ Port = 8443; CertificateThumbprint = ''; ViewerGroup = 'DOMAIN\VDI-Pipeline-Viewers'; ApproverGroup = 'DOMAIN\VDI-Pipeline-Approvers'; RefreshSeconds = 20 }
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
