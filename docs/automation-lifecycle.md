# Project lifecycle and export jobs

Use `get_capabilities` before editing to identify the running build and supported schema. These tools use absolute paths and return JSON receipts. They work through the same executor as the native agent and MCP.

| Tool | Inputs | Receipt |
| --- | --- | --- |
| `create_project` | `path` ending in `.palmier`; optional `width`, `height`, `fps`, `overwrite` | Opens the saved empty project; reports its registry identity, revision, dimensions and readiness. |
| `open_project` | `path` ending in `.palmier` | Opens or activates the existing native document; reports missing media explicitly. |
| `save_project` | Optional `projectId`, `expectedRevision` | Waits for native save, reads the saved JSON back and reports `requestedRevision`, `savedRevision` and `currentRevision`. |
| `export_project_package` | `path` ending in `.palmier`; optional guards, `overwrite`, `strictMissingMedia` | Writes a portable copy; reports its source revision, collected files, bytes and missing media. |
| `start_export` | `path`; optional `format`, `resolution`, `overwrite`, `expectedRevision`, `idempotencyKey` | Returns a `jobId` immediately. |
| `get_export_job` | `jobId` | Reports progress, frozen source revision, state, output bytes or failure. |
| `cancel_export` | `jobId` | Requests cancellation; poll until `cancelled` or another terminal state. |

Dimensions are 16–8192 pixels and frame rates are 1–240 fps. New projects default to 1920×1080 at 30 fps. Set 1080×1920 explicitly for vertical work. Readiness distinguishes a decoded document (`documentReady`) from a document whose manifest sources all exist (`mediaReady`). `ready` requires both. Preview generation and indexing can continue asynchronously.

Project identity comes from the existing native project registry. Registry lookup uses the canonical file path, so file URLs, package directory URLs and symlink aliases find the same UUID. Revisions hash the timeline and media manifest using the same contract as `apply_edit`. Pass both identity and revision when a save must target the project you inspected. A save receipt reports the disk snapshot separately from a later edit made while saving.

Exports default to H.264, 1080p short side. H.265, ProRes, 720p and 4K are supported. The long side follows the project aspect ratio. Existing output paths are rejected unless `overwrite: true` is explicit, including for the synchronous `export_video` tool. An overwrite becomes visible only after a successful export; cancellation or failure preserves the previous file.

An export job freezes the timeline, manifest and resolved source paths before rendering. Later timeline edits do not change that job. Source files must remain available while rendering. Non-text sources used on visible, audible tracks are checked before a job starts. A strict portable export checks the whole manifest and fails before replacing a destination if media is missing. Project-relative sources cannot escape the package through parent paths or symlinks.

Only one unfinished job can own an output path. Repeating an identical request with the same `idempotencyKey` returns the original job, including a completed or failed job. Changing that request under the same key is rejected. To intentionally render again, use a new key.

Receipts are stored in the existing local Koma cache under `export-jobs`. Queued, running or cancelling jobs found after a restart become failed receipts with an explicit interruption error. Renders do not resume after restart. Clearing the cache also clears those receipts.

Native saving snapshots JSON synchronously and uses an existing cached thumbnail. Thumbnail rendering runs separately: image sources use ImageIO; video generation has a three-second deadline. A thumbnail can appear on a subsequent save without holding the document save or MCP request open.

Validation covers actual image-only native saves, exact timeline round trips, strict portable collection, destination preservation on packaging and promotion failures, source-path containment, export retries and path leases, cancellation, restart interruption, and a real portrait H.264 export whose duration and frozen revision are checked.
