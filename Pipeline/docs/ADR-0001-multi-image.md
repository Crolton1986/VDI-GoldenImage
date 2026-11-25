# ADR 0001: Multi-image config and state

Status: accepted (task 02 of the UI redesign).

## Context
The pipeline handled one golden image. Every stage reads a flat config (`$Config.GoldenImage`, `.Pools`, ...) and keeps state in one folder. The dashboard now needs a list of images, each with its own VM, pools, schedule and history.

## Decision
- **Config shape.** Global keys stay as they are (`Paths`, `vCenter`, `Horizon`, `AppVolumes` connection, `Email`, `Dashboard`). A new `GoldenImages` list holds one entry per image: `Id`, `Name`, `Description`, `Os`, `Paused`, plus the blocks `GoldenImage`, `Pools`, `Validation`, `Snapshots`, `Promotion` and `AppVolumes.TestPackages`. The list lives in the sparse overlay `config/settings.json` (arrays replace on merge, so the dashboard writes the whole list).
- **One flat view per image.** `Get-GIImageConfig -ImageId` returns the global config with that image's blocks folded in, so Preflight, Maintain, Snapshot, TestPush, Validate, Approval, Promote and PostCheck run unchanged. The view scopes `Paths.State`, `Paths.Logs` and `Paths.Reports` to `<root>/<imageId>` and keeps `Paths.RootState` for the single audit log.
- **State layout.** `state/<imageId>/<RunId>.json`, plus that image's `lastKnownGood.json`, `run-request.json` and `pipeline.lock`. Logs: `logs/<imageId>/<RunId>.log`, guest logs in `logs/<imageId>/<RunId>/guest/`. Reports: `reports/<imageId>/<RunId>.html`. Run ids stay `yyyyMMdd-HHmmss`; two images can use the same id because their folders differ. Runs carry `imageId`.
- **Concurrency.** The lock is per image (it lives in the image's state folder), so images run side by side and a second run on one image is refused. The constraints below make a shared pool or VM impossible.
- **Constraints (checked on every save):** ids and names unique, a pool belongs to one image, the test pool differs from every production pool, a VM belongs to one image.
- **Migration.** `Invoke-GIConfigMigration` runs at dashboard startup. A config without `GoldenImages` yields one virtual (Legacy) entry; migration writes it to the overlay, moves runs, approvals, logs and reports into the image's folders, stamps `imageId`, and writes `config/migration-backup-<timestamp>/` first. It is idempotent and the backup is never deleted. The CLI works on the legacy layout until the dashboard has migrated.
- **Ids.** Lowercase slug of the name, made unique with `-2`, `-3`.
- **Live state.** Never in the first paint. `Invoke-GILiveSource` runs each source (vCenter, Horizon) in its own long-lived runspace: one login reused across calls, a hard 15 second limit, and a discarded worker on timeout. Errors come back per source.

## Consequences
- Existing stage code and tests did not change. New code only adds the image layer and the API.
- The overlay holds the full image entries, so editing `GoldenImages` in the psd1 has no effect once the overlay has a list.
- One scheduled task (`PipelineSchedule`) starts every non-paused image in turn; per-image schedule times are stored but a per-image Windows task is future work.
