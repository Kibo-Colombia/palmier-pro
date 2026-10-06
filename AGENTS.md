# PalmierPro

AI-native macOS video editor. Swift 6.2, SwiftUI + AppKit, AVFoundation. macOS 26 only, arm64 only. Non-sandboxed Developer ID app.

## Build

```bash
swift build
swift run
```

## Code style

- Keep comments minimal. Only write one when the *why* is non-obvious. Don't restate what the code does, don't narrate the current change, don't leave `// removed X` breadcrumbs. One short line max — no multi-line comment blocks or paragraph docstrings.

## Design System

All UI styling MUST use `AppTheme` constants from `Sources/PalmierPro/UI/AppTheme.swift`. Never use hardcoded numeric values for:

- **Spacing/padding** → `AppTheme.Spacing.*` (xxs through xxl)
- **Font sizes** → `AppTheme.FontSize.*` (xxs through display)
- **Font weights** → `AppTheme.FontWeight.*` (regular, medium, semibold, bold)
- **Corner radii** → `AppTheme.Radius.*` (xs through xl)
- **Border widths** → `AppTheme.BorderWidth.*` (hairline, thin, medium, thick)
- **Opacity** → `AppTheme.Opacity.*` (subtle, faint, muted, medium, strong, prominent)
- **Icon frame sizes** → `AppTheme.IconSize.*` (xs through xl)
- **Shadows** → `AppTheme.Shadow.*` (sm, md, lg) via `.shadow(AppTheme.Shadow.md)`
- **Colors** → `AppTheme.Text.*`, `AppTheme.Border.*`, `AppTheme.Background.*`
- **Animation durations** → `AppTheme.Anim.*`

If a needed value doesn't exist in AppTheme, add it there first — don't hardcode it.

## Drag and drop

SwiftUI `.onDrop` on a parent view shadows every drop target inside its layout area on macOS 26 — even AppKit `NSDraggingDestination` children registered directly with the window. Inner `.onDrop` modifiers silently never fire while a parent `.onDrop` is active.

Rule: **any drop target that spans an area containing other drop targets must use native AppKit** (see `MediaPanelDropArea` in `Sources/PalmierPro/MediaPanel/`). Inner / leaf drops can stay SwiftUI `.onDrop`. Do not stack SwiftUI `.onDrop` modifiers in parent/child layouts.

## Voice

Palmier Pro speaks like a quietly capable native Mac app for filmmakers: direct, technical, calm, and 
confident. Prefer Apple HIG-style terseness over warmth. Never chatty or cute. Never marketing. When the
product needs to ask for action, lead with the action verb; when it reports state, name the thing.

## Log milestones back to the monorepo brain (single source of truth)

MiraiKibo's weekly/monthly cloud briefings clone ONLY `github.com/Kibo-Colombia/miraikibo` — this
repo is invisible to them. The status doc `miraikibo/brain/functions/lab/koma.md` is Koma's only voice in
those reports, so keeping it current is part of finishing a milestone here.

When you complete a Koma milestone in this repo (feature shipped, capability proven, disposition
changed), also update `/Users/nicurrego/workspace/miraikibo/brain/functions/lab/koma.md` — a bullet or two
in its "Status — what's built" section (and "Where it's going" if the next step changed) — then
commit it there by pathspec (`git add brain/functions/lab/koma.md`) and push `main`, per that repo's
commit cadence. Build/technical detail stays here in `docs/`; koma.md gets the plain-English "what
it can do now."
