# UI components (task 01)

All helpers live in `Web/Components.ps1` and return HTML strings. Styling is in `Get-GICss` (`Web/DashboardViews.ps1`), behavior in `Get-GIUiScript`. Hex colors exist only in the `:root` token block; everything else uses `var(--token)`.

| Helper | Purpose |
|---|---|
| `New-GIButton` | pri / outline / sec / danger, `-Small`, `-Disabled -Reason` (tooltip + `aria-describedby`), `-Href`, `-OpensDialog` |
| `New-GIChip` | ok / warn / run / bad / idle pill, text required |
| `New-GICard`, `New-GITable`, `New-GITabs` | card, table with `th scope`, server-rendered tabs (real links) |
| `New-GIField` | label, helper, inline error, required marker |
| `New-GISaveBar` | sticky bar; wired to any `<form data-savebar id=...>` by the UI script |
| `New-GISubNav`, `New-GIStepper` | settings section list, wizard steps |
| `New-GIModal` | `role=dialog aria-modal`; open with `data-opens="<id>"`; Escape/Cancel closes, focus returns |
| `New-GIBanner`, `New-GISkeleton`, `New-GIStatusRegion` | banner, loading bar, `role=status` region |

Client helpers: `GI.poll(fn, seconds)` (only while the tab is visible, refreshes on return), `GI.getJson(url)` (15 s timeout, shows the session-expired banner on 401), `GI.live(msg)` (polite announcements).

## Shell
Top bar (title, user, role pill), sidebar (Golden images, Audit log, divider, Global settings, Setup, JSON API), `main#main` max 1180 px. Setup is hidden for non-admins. Below 900 px the sidebar becomes an overlay and grids stack.

## Roles
Server-side: `Get-GIPostRejection` returns 403 and writes an `auth.denied` audit entry (user, role, needed role, path) for a role failure.
