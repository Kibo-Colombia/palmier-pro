# Timeline markers and `koma://play`

Two features for driving playback from outside the editor. Other tools depend on the URL format and tool names below, so treat them as a stable contract: add fields, don't rename or remove them.

## Markers

A marker has an `id`, a `name`, a `color`, a `startFrame` and a `durationFrames` (`0` is a point, more is a range), plus an optional `note`. Markers live in the project's `project.json` under `markers`. Projects without markers keep the exact previous file format, so their revision hashes don't change.

When a timeline has markers, an 18 pt lane appears above the ruler ticks. Ranges draw as tinted blocks with a solid left edge and their name; points draw as a flag with the name beside it. The name stays visible when a block starts left of the scrolled view. Clicking a marker moves the playhead to its start.

Colors are Resolve's: `blue` (default), `cyan`, `green`, `yellow`, `red`, `pink`, `purple`, `fuchsia`, `rose`, `lavender`, `sky`, `mint`, `lemon`, `sand`, `cocoa`, `cream`.

Changing the project frame rate rescales markers with the clips. Marker edits are undoable and don't rebuild the composition or stop playback.

### Finding a marker by name

Wherever a tool or URL takes a marker, it accepts, in order:

1. the marker's `id`;
2. its full `name`, case-insensitive;
3. a unique name prefix that ends at a word boundary: `HOOK 2` finds `HOOK 2 · The tiny clock` but never `HOOK 20`.

Several matches are an error that lists them.

### MCP tools

All timing is in frames, like the rest of the API. Responses include `startSeconds` and `endSeconds` too.

| Tool | Arguments | Result |
| --- | --- | --- |
| `add_markers` | `markers`: array of `{name, startFrame, durationFrames? \| endFrame?, color?, id?, note?}`; optional `expectedRevision` | `added` markers and the new `revision`. One undo for the batch. Duplicate ids, unknown colors and unknown fields reject the whole batch. |
| `list_markers` | none | `markers` in start order, `count`, `fps`. |
| `update_marker` | `marker` (id or name); any of `name`, `color`, `startFrame`, `durationFrames` or `endFrame`, `note` (`""` clears it); optional `expectedRevision` | The updated `marker`. |
| `remove_markers` | `markers` (ids or names) or `all: true`; optional `expectedRevision` | `removed` and `remaining`. |
| `get_timeline` | as before | Adds a `markers` array in the same shape as `list_markers`. |

Example, one range per hook:

```json
{"markers": [
  {"id": "hook-1", "name": "HOOK 1 · Three pulls", "startFrame": 12460, "endFrame": 13284, "color": "red"},
  {"id": "hook-2", "name": "HOOK 2 · The tiny clock", "startFrame": 13284, "endFrame": 13861, "color": "yellow"}
]}
```

## Playing a range from outside

```
koma://play?project=<absolute .palmier path>&start=<seconds>&end=<seconds>
koma://play?project=<absolute .palmier path>&marker=<id or name>
```

- `project`: percent-encoded absolute path. Omit it to use the project in front.
- `start`, `end`: seconds, decimals allowed. `end` is exclusive and optional; without it playback runs to the end.
- `marker`: instead of `start`/`end`, never with them. A range marker plays its range. A point marker plays until the next marker starts, or to the end.
- `+` in the query reads as a space, as in form encoding. Send a literal plus as `%2B`.

What happens: Koma launches if it isn't running. If the project is already open, its window comes forward; it is never opened twice. The playhead moves to `start`, playback begins once the preview is ready, and it pauses on the last frame before `end`. Any manual seek or pause cancels the stop. Failures (missing project, unknown marker, a range outside the timeline) show an alert in Koma.

From Terminal:

```bash
open "koma://play?project=%2FUsers%2Fme%2FFilm.palmier&start=442.8&end=462.03"
open "koma://play?project=%2FUsers%2Fme%2FFilm.palmier&marker=HOOK%202"
```

From JavaScript, `new URLSearchParams({project, marker})` produces a compatible query.

### `play_range` MCP tool

The same arguments as the URL: `project?`, `start?`, `end?` (seconds) or `marker?`. It works with no project open when `project` is set. It returns `path`, `fps`, `startFrame`/`startSeconds`, `endFrame`/`endSeconds` when there is a stop, `marker` when one was used, and `playing`.
