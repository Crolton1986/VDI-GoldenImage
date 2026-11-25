# UI redesign notes

Things found while working that are outside the current task.

- Task 01: `Global settings` is shown disabled ("Admins only") to non-admins until task 08 makes the page read-only for every role (the route still returns 403 for non-admins today).
- Task 01: existing pages still use `<h2>` for their page title; each page gets a real `h1` when its task rebuilds it.
- The prompts mention `src/Watcher.ps1` and `guest/fixes/*.ps1`; neither exists in this repo yet (only `guest/Invoke-GIWindowsUpdate.ps1`). Task 02 sections 3 and 4 need a decision before they can be built as written.
- Pester: the 7 `Invoke-GISetupModules` tests fail on Linux (`Install-Module` dynamic parameter `Location`), unrelated to the UI. Baseline before this work was the same 7 failures.
