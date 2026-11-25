# UI redesign notes

What differs from the mockups and the prompts, what is not built, and what was only checked in part. Written at the end of the redesign work (tasks 01 to 14) and updated after the hand-off steps (test fixes, gaps 2, 3, 5, 6, 8 to 13).

## Differences from the prompts (intentional)

- **Layout by text, mockups for look.** Pages follow the task text and the mockups where they agree. Mockup-only values (Port, Certificate check, Request timeout on vCenter) are not built (not in the schema).
- **Logs and reports are per image folders** (`logs/<imageId>/<RunId>/guest/`), not `logs/<RunId>/guest/`, so two images can share a run id.
- **The dashboard, not the CLI, runs the config migration.** The CLI keeps working on the old layout until the dashboard has migrated.
- **Event log export is always on** (limited to the run window). No guest log retention was added because the repository has no log retention yet.
- **Add golden image** shows all five steps in one page and moves between them in the browser. The browser checks the obvious things first; then every Next asks the server (`POST /api/images?dryRun=1&step=N`) and the Review step asks for everything.
- **Dashboard refresh** for the home page is `Dashboard.LiveRefreshSeconds` (default 60), read from the config file; it is not shown in the read-only dashboard section.
- **One weekly task per golden image** (`VDI-GI-Pipeline-<id>`), at that image's own `Promotion.PipelineSchedule`. The dashboard moves the trigger of an existing task when the schedule is saved, but cannot create the task of a new image (that needs the account password), so a new image waits for the next `Register-GIPipelineTasks.ps1` run and the page says so.
- **Sign-ins**: successful ones are audited once per user per 8 hours (first authenticated request). Failed ones (`auth.signin.failed`) are audited by the pipeline's own Pode authentication scheme, which checks Active Directory itself. `Dashboard.LegacyAdAuth = $true` goes back to Pode's built-in Windows AD authentication.
- **Global settings link** shows for every role; non-admins see disabled fields.
- **Rolled back run status.** The stored status stays `RolledBack` (existing); the UI shows "Rolled back".
- **Auto-promote confirmation** is a dialog; the plain tick box stays in the page for browsers without JavaScript and the server still refuses the change without it. Turning auto-promote *off* also asks, because the server rule is "any change".
- **Status chips for installers** are the chip set Found, Downloads automatically, Missing (red only when the package is ticked), Not checked. The mockup's exact set was not available to the work, so this is a mapping, not a copy.
- **Connection chip** is on each global section's page, not in the section list on the left.
- **Last pushed** comes from run history only; rollbacks are not counted.

## Not built / not verified

- The guest log collection script (`Get-GIGuestLogScript`) is generated and parse-checked but has never run inside a real Windows guest in this environment. Paths for DEM, Teams and OneDrive logs are best guesses and need a check on a real golden image.
- vCenter, Horizon and App Volumes were not reachable. Live state, power, revert, rollback, the wizard and settings inventory, the retention preview and the Guest VM and Pools tests are tested with mocks and by simulating timeouts and errors only.
- **Active Directory sign-in has never run against a real domain.** `Invoke-GIAdBind` (`PrincipalContext.ValidateCredentials`, `GetAuthorizationGroups`) is the only code that touches the directory and is untested here. Everything around it (header parsing, group check, audit entry, the Pode scheme and validator in a real Pode server) was run with the directory replaced by a test double. Check on a real domain before relying on it: a correct password, a wrong one, an account with no dashboard group, a nested group, a UPN and a `DOMAIN\user` login, and a locked account. `Dashboard.LegacyAdAuth = $true` is the way back. Non-ASCII passwords are decoded as ISO-8859-1, like Pode's own scheme, though browsers send UTF-8.
- **Scheduled tasks were not run on Windows.** `Get-GIPipelineTaskDefinition`, `Register-GIPipelineTask` (including removing the old and stale tasks), `Unregister-GIPipelineTask` and `Set-GIPipelineScheduleTask` are tested with stubbed ScheduledTasks cmdlets only.
- The three roles were tested through views, the API dispatcher and `Get-GIPostRejection`, not with real AD accounts. In lab mode the dashboard runs as Admin only.
- No screen reader pass. Keyboard order and focus rings were checked with a headless browser on the home page; contrast follows the tokens. A full WCAG audit still needs a person. The new dialogs trap focus like the existing ones; that was not tested with a screen reader.
- The pool state chips (New, Current, Behind, Failed) are derived in the browser from the live answer; "Failed" relies on the pending image state text from Horizon.
- Mockups for the Setup wizard are not matched pixel for pixel; Setup got the new shell, tokens and an `h1`.
- Copy settings from an existing image (wizard step 1) and a snapshot retention field in the wizard are deliberately not in this release.
- The "Outside retention" tag is only shown when both vCenter and Horizon answered, because pool usage protects snapshots. With one of them down the tag is simply absent, not "unknown".
- "Last known state" lives in the browser's session storage (per tab). A new tab that opens while vCenter is down has nothing to show and says Unknown.
- The `Save-GIApiImageSettings` API does not require the `confirm_<key>` field that the page requires for AutoPromote (existing behavior; an Admin can already change the setting).
- `GET /api/packages?folder=` lets an Admin point the pipeline host at any folder or UNC path, as the installer folder setting already does. It lists only file names that match the known installer masks.

## Tests

The full Pester suite runs with `pwsh` 7.4 and Pester 5.7: 0 failures on Linux (see the last commit for the current count). The Setup modules and PowerCLI tests mock plain stubs, so they do not depend on the real `Install-Module` or PowerCLI. The stubs have not been run on Windows. `tests/LiveFallback.Tests.ps1` runs the browser helpers in Node when `node` is installed and skips those tests otherwise.
