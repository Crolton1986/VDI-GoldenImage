# UI redesign notes

Things found while working that are outside the current task.

- Task 01: `Global settings` is shown disabled ("Admins only") to non-admins until task 08 makes the page read-only for every role (the route still returns 403 for non-admins today).
- Task 01: existing pages still use `<h2>` for their page title; each page gets a real `h1` when its task rebuilds it.
- (resolved) the watcher and `guest/fixes` arrived upstream while task 01 was in progress; local checkout was stale and was merged.
- Pester: the 7 `Invoke-GISetupModules` tests fail on Linux (`Install-Module` dynamic parameter `Location`), unrelated to the UI. Upstream baseline has 12 failures on Linux (these 7 plus Horizon pool lookup, setup PowerCLI and one settings test); task 01 adds none.
