---
name: first-cut
description: Drive Koma over MCP to turn a locked brief + organized footage into a reviewable first cut on the timeline. Use when the user says "first cut", "run the Sunday edit", "cut this brief", or hands you a studio_plan/ClipSpec/brief file to execute in Koma. Stops before export — the human reviews in Koma's own UI.
---

# First Cut — brief → Koma timeline

Turn a locked plan into a draft edit sitting on Koma's timeline, ready for human review.
This is the local-agent bridge of the Studio Machine: the Creator (web) produces the brief;
you, running locally, drive Koma's MCP tools to execute it. You make the cut; you do NOT
ship it.

## Hard rules

1. **Never export or publish.** The deliverable is a timeline in Koma plus a short summary
   of the choices you made. The human reviews and exports in Koma's UI. Only export if the
   user explicitly asks in this session.
2. **Generation costs money (fal.ai BYOK).** At most ONE audio generation per run unless the
   brief explicitly budgets more. Image/video generation only if the brief asks for it.
   Everything else (cutting, keyframes, presets, grading, captions) is free and local.
3. **Don't fight the brief.** If footage the brief names can't be found, report what's
   missing and cut what you can — don't substitute silently.

## Pre-flight

1. Koma must be running: `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:19789/mcp`
   (any HTTP response means up). If down, tell the user to open Koma — don't launch it yourself.
2. Connect if this session has no Koma MCP tools yet:
   `claude mcp add --transport http palmier-pro http://127.0.0.1:19789/mcp` (or use the
   already-configured server). Tools to expect: get_timeline, add_clips, move_clips,
   split_clip, set_clip_properties, set_keyframes, search_media, import_media, get_media,
   generate_audio, add_captions, add_texts, list_presets, apply_preset, preview_presets,
   set_grade, apply_look, auto_color, import_reference, analyze_reference, inspect_timeline.
3. Read the brief. Accepted forms, in order of preference:
   - a path the user gives you (studio_plan / ClipSpec JSON / markdown brief);
   - a materialized Space folder — read `_SPACE.md` and the per-clip `.md` dossiers;
   - a plain-language description in the chat.
   Extract: target duration, format/aspect, beat or music intent, the ordered story beats,
   which clips/moments serve each beat, captions y/n, grade/mood, reference video if any.

## The loop

1. **Ground.** `get_timeline` for fps/canvas; `search_media` / `get_media` to resolve every
   clip the brief names. Import from the materialized Space folder with `import_media` when
   the project doesn't have the footage yet.
2. **Reference first, if the brief has one.** `import_reference` + `analyze_reference` and
   let its recipe (pacing, beat grid, caption cadence, color mood) set your defaults.
3. **Music before cuts when beat-synced.** `generate_audio` (one generation), read back its
   duration, and derive the cut grid from the BPM. Otherwise cut to the brief's pacing.
4. **Assemble.** `add_clips` in story order, trim with `set_clip_properties` / `split_clip`.
   Snap cuts to the beat grid. Strip source audio when the music carries the edit.
5. **Motion.** `set_keyframes` for the moves the brief or recipe calls for (zoom-punch on
   downbeats, final push-in, etc.). Prefer `apply_preset` (whip / zoom-in / flash / dissolve,
   shake / zoom-punch / glow) over hand-built keyframes when one fits; `preview_presets` to
   disambiguate a fuzzy request, showing the user the stills.
6. **Grade.** `apply_look` or `set_grade` toward the brief's mood; `auto_color` as a base
   when unspecified.
7. **Captions** only if the brief asks: `add_captions` from transcripts, style per recipe.
8. **Self-check.** `inspect_timeline` at 2–3 representative frames; verify duration against
   target (get_timeline). Fix what's off.

## Hand-off

End with a short report: what was cut (duration, cuts, music, presets, grade), what deviated
from the brief and why, what's missing, and the one or two decisions the reviewer should look
at first. The timeline stays open in Koma — that UI is the review surface.
