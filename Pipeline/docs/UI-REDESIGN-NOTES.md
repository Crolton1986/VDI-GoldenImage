# UI redesign notes

What differs from the mockups and the prompts, what is not built, and what was only checked in part. Written at the end of the redesign work (tasks 01 to 14).

## Differences from the prompts (intentional)

- **Layout by text, mockups for look.** Pages follow the task text and the mockups where they agree. Mockup-only values (Port, Certificate check, Request timeout on vCenter) are not built (not in the schema).
- **Logs and reports are per image folders** (`logs/<imageId>/<RunId>/guest/`), not `logs/<RunId>/guest/`, so two images can share a run id.
- **The dashboard, not the CLI, runs the config migration.** The CLI keeps working on the old layout until the dashboard has migrated.
- **Event log export is always on** (limited to the run window). No guest log retention was added because the repository has no log retention yet.
- **Add golden image** shows all five steps in one page and moves between them in the browser. Steps are checked in the browser on Next; the server validates everything on the Review step (`POST /api/images?dryRun=1`) and again on create. The prompt asked for server validation on every Next.
- **Dashboard refresh** for the home page is `Dashboard.LiveRefreshSeconds` (default 60), read from the config file; it is not shown in the read-only dashboard section.
- **One scheduled task for all images.** `Promotion.PipelineSchedule` is stored per image, but the `VDI-GI-Pipeline` task is still one weekly task that runs every non-paused image in turn. Per-image schedule tasks are future work.
- **Sign-ins** are audited once per user per 8 hours (first authenticated request). **Failed sign-ins are not audited**: Pode's AD authentication rejects the request before the dashboard code runs. Needs a custom Pode authentication scheme.
- **Global settings link** shows for every role; non-admins see disabled fields.
- **Rolled back run status.** The stored status stays `RolledBack` (existing); the UI shows "Rolled back".

## Not built / not verified

- The guest log collection script (`Get-GIGuestLogScript`) is generated and parse-checked but has never run inside a real Windows guest in this environment. Paths for DEM, Teams and OneDrive logs are best guesses and need a check on a real golden image.
- vCenter, Horizon and App Volumes were not reachable. Live state, power, revert, rollback and the wizard inventory are tested with mocks and by simulating timeouts and errors only.
- Active Directory sign-in and the three roles were tested through views, the API dispatcher and `Get-GIPostRejection`, not with real AD accounts. In lab mode the dashboard runs as Admin only.
- No screen reader pass. Keyboard order and focus rings were checked with a headless browser on the home page; contrast follows the tokens. A full WCAG audit still needs a person.
- The pool state chips (New, Current, Behind, Failed) are derived in the browser from the live answer; "Failed" relies on the pending image state text from Horizon.
- Mockups for the Setup wizard are not matched pixel for pixel; Setup got the new shell, tokens and an `h1`.
- Copy settings from an existing image (wizard step 1) and a snapshot retention field in the wizard are deliberately not in this release.

## Tests

The full Pester suite runs with `pwsh` 7.4 and Pester 5.7. On Linux 12 tests fail that also fail on the branch before this work (Setup modules, Horizon pool lookup, setup PowerCLI, one settings test). See the final report for the list.
