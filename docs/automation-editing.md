# Coordinated timeline editing

Read `get_capabilities`, then `get_timeline` and `get_media`. Discovery reports the actual bundled source revision, whether that build contained uncommitted changes, and a fingerprint of its advertised tool schemas. A matching marketing version alone does not identify the installed API.

`apply_edit` plans a complete change against a value snapshot. It validates every operation, source limit and collision before publishing the timeline once. A committed batch produces one undo step and one composition rebuild. Failed validation leaves the timeline unchanged. Existing property batches also coalesce their composition rebuilds.

The request requires `expectedRevision`, a unique `operationId`, and `operations`. Pass `projectId` as well when switching between projects. Revisions hash the full persisted timeline and media manifest, including human edits made through the inspector. Track and clip references use stable IDs rather than array positions. Use `dryRun: true` to inspect a proposed diff, then apply it with the same revision and operation ID.

Supported operations are `move_clip`, `resize_clip`, `set_clip`, `set_track`, `remove_clip` and `resize_beat`. Property edits cover gain, opacity, fades, volume-envelope removal and partial transforms. `set_track_properties` is a convenience wrapper for mute, visibility and sync lock. Two music tracks can be auditioned in one `apply_edit` batch without touching their envelopes.

An identical committed retry returns its original receipt. Reusing an operation ID for different arguments is rejected. Edit receipts last for the open editor session; after reopening, use a fresh revision and operation ID. Undoing a committed edit does not erase its retry receipt. Use a new ID to intentionally apply it again.

Collisions reject by default. Explicit `collisionPolicy: "overwrite"` uses the native trim/split behavior, with deterministic split IDs so a dry run matches its eventual commit. It refuses to trim linked or caption victims implicitly. Linked timing changes require explicit partner operations. Generic ripple is deliberately replaced by the explicit beat operation.

## Beat timing

`resize_beat` takes `startFrame`, `endFrame`, a new `durationFrames`, an explicit `clips` role list and `rippleTrackIds`. Roles determine how each clip follows the changed boundary:

| Role | Behavior |
| --- | --- |
| `hold` | Extend an image or text clip ending at the original boundary. |
| `sound_start` | Preserve a short sound's length and starting offset. |
| `sound_end` | Preserve a short sound's length and anchor its tail to the new boundary. |
| `span` | Extend a covering caption, background or sound bed, including one ending at the boundary. |

Later clips move only on declared ripple tracks. Every intersecting clip on those tracks needs an explicit role. Ambiguous or incomplete requests reject. Extending a music or ambience span consumes source headroom at its existing speed; it does not stretch the recording. An extension beyond available source frames rejects the whole change. Refresh beat ranges after each committed edit; an external role map is a draft plan rather than a persistent synchronization registry.

## Sound units

Static clip `volume` is linear gain. Native `volumeTrack` values, including those returned by `get_timeline`, are dB. `set_keyframes` defaults to `units: "linear"` for volume and converts endpoints to native dB; `units: "db"` accepts native values directly. −60 dB is silence and +15 dB is the native ceiling. Interpolation runs in native dB space. Setting scalar gain preserves the envelope; `clearVolumeAutomation: true` removes it explicitly. Opacity retains its existing scalar-replaces-envelope behavior.

Existing saved envelopes keep their native interpretation. There is no global migration that guesses whether old values were authored under the former, incorrect MCP description. A known authored fixture must be converted explicitly in a new copy.

## Calling without computer use

`python3 scripts/koma-call.py get_capabilities` connects to the running local MCP. Pass an argument file with `--args /absolute/path/request.json`. The client handles both JSON receipts and older successful plain-text replies, checks MCP error envelopes, suppresses image payloads and never retries a mutation automatically. Redirect large timeline/diff results to files and inspect the needed fields.

Project saving, portable packaging and asynchronous rendering are documented in [automation-lifecycle.md](automation-lifecycle.md). This API changes no vendor, generation authorization or runtime permissions.
