# Golden image maintenance pipeline

Runs the monthly golden image routine for Horizon instant-clone pools from a management server: patch the golden VM, snapshot it, test it on a test pool, wait for a human to approve, then push it to production in a maintenance window.

## What it does

```
Preflight -> Maintain -> Snapshot -> TestPush -> Validate -> Approval -> Promote -> PostCheck
   |            |           |           |           |           |           |          |
 checks,     Windows     GI-<RunId>  push to     Horizon,    approve /   schedule   production
 safety      Update +    snapshot,   test pool   guest and   reject      pool       pools on
 snapshot    agents in   retention               App Volumes (dashboard  pushes     new image,
 pre-maint-* guest       report                  checks      or script)  per window last-known-good
```

1. Preflight checks that the golden VM is powered off and that no pool has a push pending, then takes a safety snapshot named `pre-maint-<RunId>`.
2. Maintain powers the VM on and runs Windows Update passes and `VDI-GoldenImage.ps1 -Unattended` actions inside the guest through VMware Tools, then runs the finalize action and waits for power off.
3. Snapshot creates `GI-<RunId>` with a manifest of the installed agent versions, then applies the retention policy.
4. TestPush pushes the snapshot to the test pool.
5. Validate checks Horizon (machine state), the guest (required services on a sample of machines) and App Volumes (test packages attached).
6. Approval waits for a person. With `Promotion.AutoPromote = $true` it approves itself when validation passes.
7. Promote schedules the push for each production pool at the approved start time.
8. PostCheck runs after the window. When every production pool is on the new image, the snapshot becomes the last-known-good.

If something is wrong after promotion, `-Stage Rollback` pushes the last-known-good snapshot to a pool.

Each run has a state file in `state/`, an HTML report in `reports/` and a log in `logs/`. The file formats are in `docs/CONTRACT.md`.

## Requirements

On the management server:

* Windows, PowerShell 7.2 or later
* VMware.PowerCLI
* Microsoft.PowerShell.SecretManagement and Microsoft.PowerShell.SecretStore
* Pode 2.x, for the dashboard
* Network access on 443 to vCenter, the Horizon Connection Server and the App Volumes Manager

```powershell
Install-Module VMware.PowerCLI, Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore -Scope AllUsers
Install-Module Pode -MaximumVersion 2.99.99 -Scope AllUsers
```

The service account needs these permissions:

* vCenter: create and remove snapshots, power operations, and guest operations on the golden VM
* Horizon: an administrator role that can push images and read pools, machines and base images
* App Volumes: an administrator account with read access

The golden VM needs VMware Tools running and a local administrator account for the guest credential. The pipeline copies `VDI-GoldenImage.ps1` into the guest at `GoldenImage.ScriptPathInGuest` on every run, so you don't have to keep it there yourself. The guest script's own `.config` file and `Install` folder still live next to it as described in the top-level README.

The vault has to work without a prompt for the account that runs the scheduled tasks. Sign in as that account once and run:

```powershell
Register-SecretVault -Name SecretStore -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault
Set-SecretStoreConfiguration -Authentication None -Interaction None -Confirm:$false
```

A different SecretManagement vault works too, as long as it's readable by that account without interaction. The SecretStore vault is per user, so create the secrets as the service account as well.

## Secrets

The config file holds only secret names. Create these as the service account:

```powershell
Set-Secret -Name GI-vCenter    -Secret (Get-Credential -Message 'vCenter')
Set-Secret -Name GI-Horizon    -Secret (Get-Credential -Message 'Horizon administrator')
Set-Secret -Name GI-AppVol     -Secret (Get-Credential -Message 'App Volumes administrator')
Set-Secret -Name GI-GuestAdmin -Secret (Get-Credential -Message 'Golden VM local administrator')
```

## Configuration

Edit `pipeline.config.psd1`, or copy it and pass `-ConfigPath` to every script. Relative paths resolve against the Pipeline folder.

| Section | Keys | Notes |
|---|---|---|
| Paths | State, Reports, Logs | Where run files go. |
| vCenter | Server, CredentialSecret | Used for snapshots, power operations and guest operations. |
| Horizon | Server, CredentialSecret, Domain, SkipCertificateCheck | Connection Server REST API. Leave the certificate check on in production. |
| AppVolumes | Server, CredentialSecret, SkipCertificateCheck, TestPackages, Endpoints | TestPackages are the packages assigned to the test pool's computers. Endpoints are the REST paths and differ between releases. |
| GoldenImage | VmName, GuestCredentialSecret, ScriptPathInGuest, Actions, WindowsUpdate, FinalizeAction, PowerOffTimeoutMin | Actions run in order with `-Unattended` after Windows Update. WindowsUpdate has Enabled and MaxPasses. |
| Pools | Test, Production, PushTimeoutMin | Test is one pool, Production is a list. Each pool has Name and LogoffPolicy (FORCE_LOGOFF or WAIT_FOR_LOGOFF). |
| Validation | GuestSampleCount, RequiredServices, MachineReadyTimeoutMin | Services are checked on that many test machines. |
| Snapshots | Keep, MaxChainDepth, Prune, ProtectAncestors | Retention. See Safety behavior. |
| Promotion | AutoPromote, MaintenanceWindow | MaintenanceWindow has Days and StartTime. The next matching window is used when you don't pass `-StartTime`. |
| Email | Enabled, SmtpServer, Port, From, To, UseSsl | Run report by mail. |
| Dashboard | Port, CertificateThumbprint, ViewerGroup, ApproverGroup, RefreshSeconds | Web dashboard. |

## Running it

Run from the Pipeline folder on the management server.

```powershell
# Full run up to the approval gate
.\Invoke-GIPipeline.ps1 -Stage All

# Individual stages (newest run unless -RunId is given)
.\Invoke-GIPipeline.ps1 -Stage Preflight
.\Invoke-GIPipeline.ps1 -Stage Maintain  -RunId 20261124-213005
.\Invoke-GIPipeline.ps1 -Stage Snapshot  -RunId 20261124-213005
.\Invoke-GIPipeline.ps1 -Stage TestPush  -RunId 20261124-213005
.\Invoke-GIPipeline.ps1 -Stage Validate  -RunId 20261124-213005

# Recent runs
.\Invoke-GIPipeline.ps1 -Stage Status

# Check production after the window (safe to repeat)
.\Invoke-GIPipeline.ps1 -Stage PostCheck
```

Approval:

```powershell
# Next maintenance window from the config
.\Approve-GIPromotion.ps1 -RunId 20261124-213005

# A specific start time and a comment
.\Approve-GIPromotion.ps1 -RunId 20261124-213005 -StartTime '2026-11-28 22:00' -Comment 'CAB-1234'

# Reject
.\Approve-GIPromotion.ps1 -RunId 20261124-213005 -Reject -Comment 'Teams regression'

# See what would be scheduled without doing it
.\Approve-GIPromotion.ps1 -RunId 20261124-213005 -WhatIf
```

Rollback pushes the last-known-good snapshot, or a named one, to a pool:

```powershell
.\Invoke-GIPipeline.ps1 -Stage Rollback -PoolName PRD-W11
.\Invoke-GIPipeline.ps1 -Stage Rollback -PoolName PRD-W11 -SnapshotName GI-20261027-203000 -ForceLogoff
```

Exit codes for `Invoke-GIPipeline.ps1`:

| Code | Meaning |
|---|---|
| 0 | OK |
| 1 | A stage or the run failed |
| 3 | PostCheck isn't finished yet (a push is still running). Try again later. |

## Dashboard

```powershell
.\Web\Start-GIDashboard.ps1
.\Web\Start-GIDashboard.ps1 -ConfigPath D:\GI\prod.config.psd1 -Port 9443
```

It serves https on `Dashboard.Port` using the certificate in the LocalMachine store whose thumbprint is in `Dashboard.CertificateThumbprint`. The service account needs read access to that certificate's private key. Find the thumbprint with:

```powershell
Get-ChildItem Cert:\LocalMachine\My | Select-Object Thumbprint, Subject, NotAfter
```

Users sign in with HTTP Basic over https, checked against Active Directory. Members of `Dashboard.ViewerGroup` can look at runs, reports and logs. Members of `Dashboard.ApproverGroup` can also approve or reject. Approver membership implies viewer access.

`-NoTls` serves plain http and `-NoAuth` skips sign-in. Use them for a lab only. With `-NoAuth` the dashboard is strictly read-only and the approve and reject buttons are disabled. `-NoAuth` also works on a non-Windows host.

| Route | Purpose |
|---|---|
| `GET /` | Run list and last-known-good |
| `GET /runs/:runId` | Run detail with stages, checks and promotion status |
| `POST /runs/:runId/decision` | Approve or reject (approvers only) |
| `GET /reports/:runId` | HTML report |
| `GET /logs/:runId` | Run log |
| `GET /pools` | Pool status |
| `GET /api/runs` | Runs as JSON |
| `GET /api/runs/:runId` | One run as JSON |

## Scheduling

`Register-GIPipelineTasks.ps1` creates three scheduled tasks. Run it from an elevated PowerShell 7 session.

```powershell
$cred = Get-Credential DOMAIN\svc-vdi-gi
.\Register-GIPipelineTasks.ps1 -Credential $cred -WhatIf
.\Register-GIPipelineTasks.ps1 -Credential $cred -PipelineDay Tuesday -PipelineTime 20:00
.\Register-GIPipelineTasks.ps1 -Credential $cred -ConfigPath D:\GI\prod.config.psd1
.\Register-GIPipelineTasks.ps1 -Unregister
```

| Task | Runs | When |
|---|---|---|
| VDI-GI-Pipeline | `Invoke-GIPipeline.ps1 -Stage All` | Weekly, Tuesday 20:00 by default |
| VDI-GI-PostCheck | `Invoke-GIPipeline.ps1 -Stage PostCheck` | Every hour |
| VDI-GI-Dashboard | `Web\Start-GIDashboard.ps1` | At startup, restarted up to 3 times, 1 minute apart |

The tasks run whether or not the account is logged on, with highest privileges. Running the script again updates the tasks in place. PostCheck exits with 3 while a push is still running, and the task history shows that as a failure. That's expected. The account needs the "Log on as a batch job" right.

## Safety behavior

* Preflight stops the run if the golden VM is powered on or if any configured pool already has a push pending. It then takes the `pre-maint-<RunId>` safety snapshot, so a bad update pass can be reverted.
* Retention is report-only until you set `Snapshots.Prune = $true`. When it prunes, it keeps the newest `Snapshots.Keep` snapshots of each kind (`GI-*` and `pre-maint-*`), never touches snapshots it did not create, and never deletes a snapshot that is in use by any pool (current or pending), the last-known-good, the current run's snapshots, or an ancestor of any of those (`ProtectAncestors`). Horizon tracks the base image by snapshot path, so removing a parent can break provisioning for pools on its children. Test in the lab before turning `ProtectAncestors` off. If Horizon can't be read, retention deletes nothing.
* When the snapshot chain gets deeper than `Snapshots.MaxChainDepth`, the report warns you. Pruning can't flatten the chain. Plan a new golden image generation (a full clone of the VM) instead.
* Promotion schedules the pools one after another. If one fails, the pools already scheduled in that promotion are cancelled.
* `Promotion.AutoPromote` is `$false` by default, so a person has to approve every run.

## Confirm before first use

The Horizon and App Volumes calls were written from the documented APIs and haven't been run against your environment. Check these first.

Horizon REST paths used:

```
POST /rest/login            POST /rest/refresh          POST /rest/logout
GET  /inventory/v1/desktop-pools
GET  /inventory/v1/machines
GET  /config/v1/virtual-centers
GET  /external/v1/base-vms
GET  /external/v1/base-snapshots
POST /inventory/v1/desktop-pools/{id}/action/schedule-push-image
POST /inventory/v1/desktop-pools/{id}/action/cancel-scheduled-push-image
```

The pool fields read are listed in `Get-GIPoolImageInfo` in `src/Rest.ps1`: `provisioning_settings.parent_vm_id`, `provisioning_settings.base_snapshot_id`, and the `instant_clone_*` pending image and operation fields in `provisioning_status_data`. Compare all of it with `https://<connection-server>/rest/swagger-ui.html` for your Horizon version. A missing field reads as `$null`, which can make a push look finished or a pool look idle.

Other things to check:

* The App Volumes endpoints in `AppVolumes.Endpoints` are configurable and unverified. Compare them with your Manager's API documentation. The App Volumes check matches machine names in the response text, so a response that doesn't contain the machine name will fail the check.
* Windows Update runs through the Windows Update Agent COM API in a scheduled task running as SYSTEM inside the guest. If WSUS, SCCM or another tool manages updates, set `GoldenImage.WindowsUpdate.Enabled = $false` and patch with your own tool.

For the first rollout, run the stages one at a time against the lab pools with `Snapshots.Prune = $false`, read the report after each, and only then schedule the full run.

## Tests

Pester 5 and PSScriptAnalyzer, from the repository root:

```powershell
Invoke-Pester -Path Pipeline/tests -Output Detailed
Invoke-ScriptAnalyzer -Path Pipeline -Recurse -Settings Pipeline/PSScriptAnalyzerSettings.psd1
```

The tests don't need vCenter, Horizon or Windows.
