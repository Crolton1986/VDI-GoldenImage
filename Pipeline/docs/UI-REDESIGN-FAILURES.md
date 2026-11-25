# UI redesign: failure report and hand-off prompt

Branch `claude/practical-brown-xnoy5x`. Run the suite with PowerShell 7.4 and Pester 5.7.1:

```powershell
Import-Module Pester -RequiredVersion 5.7.1
Invoke-Pester ./Pipeline/tests -Output Detailed
```

Result after the hand-off steps 1 to 4: all tests pass (Linux, pwsh 7.4.6, Pester 5.7.1; run the suite for the current count).

## A. Known gaps in the redesign (not covered by tests, or only partly built)

Task 02 backend
1. The guest log script was parse-checked and its generated text is tested, but it has never run in a real Windows guest. DEM, Teams and OneDrive log paths are best guesses.
2. Failed sign-ins are written (`auth.signin.failed`), but the Active Directory call behind them (`Invoke-GIAdBind`) has never run against a real domain. See UI-REDESIGN-NOTES.md for what to check.
3. Per-image scheduled tasks exist, but have not been run on Windows. Adding an image does not create its task (needs the account password); re-run `Register-GIPipelineTasks.ps1`.
4. No guest log retention (the repository has no log retention to follow).

Task 03 and 05 (home and Overview)
7. Pool state "Failed" is guessed from the pending image state text.

Task 14 (review)
14. Keyboard and layout checks were done with a headless browser on the home page (tab order, focus rings) and for horizontal overflow at 800 and 1280 px on every page. There was no screen reader pass and no full contrast measurement beyond the tokens.
15. Only Admin was exercised in the running dashboard (lab mode). Viewer and Approver are covered by view and API tests.

Fixed in the hand-off: the 12 failing Linux tests, and gaps 5, 6, 8, 9, 10, 11, 12 and 13 (numbers as in the first version of this report). Their remaining limits are in UI-REDESIGN-NOTES.md.

## B. Prompt for an AI agent to fix these (steps 1 to 4 are done; kept for the next hand-off)

```text
You are working in the repository Crolton1986/VDI-GoldenImage on branch claude/practical-brown-xnoy5x.
Read Pipeline/docs/UI-REDESIGN-FAILURES.md, Pipeline/docs/UI-REDESIGN-NOTES.md,
Pipeline/docs/ADR-0001-multi-image.md and Pipeline/docs/CONTRACT.md first.

Setup: install PowerShell 7.4 (pwsh) and Pester 5.7.1 (Install-Module Pester -RequiredVersion 5.7.1)
and Pode. Run the suite with Invoke-Pester ./Pipeline/tests. Start the dashboard in lab mode with
Pipeline/Web/Start-GIDashboard.ps1 -ConfigPath <scratch config> -LocalAdmin -Port 18080 and use a
headless browser to look at pages. vCenter, Horizon and App Volumes are not reachable, so use mocks.

Work in this order and commit after each step with a message naming the step:
1. Fix the 12 failing tests listed in section A. Do not change product code to make a test pass unless
   the table says so. Re-run the whole suite; the target is 0 failures.
2. Close gaps 8, 9, 10 and 5 from section B (Packages step count and Check again, Guest VM select with
   typed fallback, pools used by another image shown disabled, per-image Test for Guest VM and Pools using
   the form values without saving, Connected / Not tested chips, greyed last known values on a failed live check).
3. Close gaps 6, 11, 12 and 13.
4. Gap 2: implement auth.signin.failed with a custom Pode authentication scheme that checks Active Directory
   and writes the audit entry with the attempted user name and never the password. Keep Windows-only code
   behind the existing Test-GIIsWindows style guards and test it with mocks.
5. Gap 3: register one scheduled task per image or pass the image id to the task, and update
   Set-GIPipelineScheduleTask and its tests.
6. Review every change for role checks on the server, secrets in HTML, JSON, logs and audit entries,
   and escaping. Add Pester tests for each backend change. Update README.md, Pipeline/docs/CONTRACT.md
   and Pipeline/docs/UI-REDESIGN-NOTES.md. Delete items from the failures report as they are fixed.

Rules: PowerShell 7 only, server rendered Pode pages, plain CSS with the tokens in Get-GICss (no hex
colors outside the :root block), small vanilla JS, no CDN assets. Do not widen scope. Say plainly what
you could not verify.
```
