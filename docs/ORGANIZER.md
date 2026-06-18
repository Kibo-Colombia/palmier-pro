# The Organizer — Koma's Understanding + Organization system

> **Mission.** Make every frame Koma can see *understood once*, at every level
> (`Root › Folder › File › Scene › Second`), and let a human organize that
> understanding into per-project workspaces **without ever moving the raw footage** —
> the way Escritorio lets AI read a whole life's writing in seconds and spin projects
> off it. Built for a near future where AI understanding is instant and total: we own
> the *addressing* and the *organization*; the understanding *engine* is swappable.

This lives on the **home screen** (`Project/HomeView.swift`) — the surface *before* you
open a timeline. Today that screen is a flat grid of editor projects. It becomes: your
entire understood library + the temporal workspaces you carve from it.

---

## The two layers (never confuse them)

**Layer 1 — Understanding (AI's job, scan once, canonical source of truth).**
Every root the machine can see → folders → files → scenes → seconds, fully indexed.
Built once, updated incrementally. **Raw bytes never move.** The durable artifact is the
*index that describes* the footage — because video files are opaque gigabytes, unlike
Escritorio's self-describing text. The index is the thing AI and humans navigate in seconds.

**Layer 2 — Organization (human's job, non-destructive views).**
"Temporal folders" / **Spaces** = curated sets of *pointers* into Layer 1, optionally
materialized on disk as **symlinks (shortcuts)** or **copies**. Parallel projects, each
organized, zero duplication of the real gigabytes. This is Escritorio's `workspace/` for footage.

**The future-proofing rule:** design around a stable *addressing scheme* + the *view layer*,
and treat the understanding model as a rented hand. SigLIP2 today, something better tomorrow —
a moment stays addressable as `(root) / path / file @ scene / second` regardless. When AI gets
instant and omniscient, the data model doesn't change; it just fills in faster.

---

## What already exists (do NOT rebuild)

The hard, expensive parts are already in Koma — this is mostly *surfacing* them:

| Organ | File | Gives us |
|---|---|---|
| Shot / scene detection + key-moment frames | `Search/Indexing/FrameSampler.swift` | luma scene-change detection (`isNewShot`) + coverage floor → **the "key moments"** |
| Per-shot embeddings + timestamps | `Search/Indexing/VisualIndexer.swift`, `EmbeddingStore.swift` | per shot: `time`, `shotStart`, `shotEnd`, SigLIP vector — idempotent per (file, model, sampler) |
| **Image AND text encoder** | `Search/Models/VisualEmbedder.swift` | `encode(image:)` **and** `encode(text:)` — both SigLIP towers loaded |
| Embedding search | `Search/Query/VisualSearch.swift` | text/image → frame cosine match, best-per-shot |
| The "said" layer | `Transcription/{TranscriptCache,TranscriptSearch}.swift` | transcripts per file |
| The agent | `Agent/` (MCP, `ToolExecutor+Search`) | Kibo can already query the index |
| The home surface | `Project/{HomeView,ProjectCard,ProjectRegistry}.swift` | the screen we extend |

**The unlock:** because `encode(text:)` exists, *classification is search against a fixed
vocabulary* — no new model, no API, on-device, free, and it re-runs for free when the model improves.

---

## The four new pieces (in build order)

### M1 — Key-moment hover-scrub card (the atom)
The densest "understand a file without opening it." On hover over a library card, scrub the
cursor across it to cycle the file's **key moments** (the shot-start frames `FrameSampler`
already found). No new analysis — read shot timestamps from `EmbeddingStore`, generate/cache
one thumbnail per shot, map cursor-x → shot index.
- Reuse: `MediaPanel/MediaTab/AssetThumbnailView.swift` for thumb rendering.
- New: a per-file keyframe-thumbnail cache (one small image per shot-start) + the hover-scrub view.
- **Ships first; no model work; validates the whole direction.**

### M2 — The classification language (the "super quick language")
A terse, controlled vocabulary the AI assigns at every level. **A label is a text prompt;**
embed it once, cosine-match against each scene's existing embedding; a scene "is" a label if it
scores above threshold. File labels = aggregate of its scenes; folder labels = aggregate of its files.

**Grammar — namespaced facets, terse tokens:**
```
subj:  subject      person · hands · product · screen · food · landscape · animal …
act:   action       walking · talking · cooking · typing · driving · gesturing …
set:   setting       indoor · outdoor · night · day · studio · kitchen · street …
shot:  framing       wide · medium · closeup · aerial · pov · static · handheld …
mood:  feel          calm · energetic · tense · warm …
use:   usability     broll · talking-head · establishing · transition · unusable …
```
- Each label = `(token, [prompts])`. Token is the handle (`set:night`); prompts are SigLIP
  queries (ensemble allowed: "a frame at night", "dark outdoor lighting"). Stored in a
  **versioned vocabulary file** (JSON) + a cache of prompt embeddings.
- Classification: per scene, cosine vs each label's cached embedding; assign top-k per facet
  above a per-facet threshold. Aggregate up to file, then folder (cheap counts).
- **Controlled but extensible:** ship a seed vocabulary; the user (or Kibo) can add labels;
  re-embed on change. This is the language AI reads in seconds — a file's identity compresses
  to a handful of tokens, no pixels touched.
- **Unifies with search:** a free-text search is an ad-hoc label; a label is a saved search —
  same `VisualSearch` machinery.
- Surface: label chips on cards; filter/scope the library by label.
- Storage: a labels sidecar keyed like `EmbeddingStore` (per asset: scene → tokens + scores)
  + the vocabulary JSON. A `roots`/library model (canonical scan scope, path-portable per
  `(root label + relative path)`) lands here too.

### M3 — The organization layer (Spaces = temporal folders)
Non-destructive workspaces carved from the understood library.
- A **Space** = a saved set of moment/file *addresses* + an optional label filter, with a
  materialization mode: **pointers** (in-app only), **symlinks** (Finder-visible, default), or
  **copies** (isolation). Raw bytes never duplicated unless you choose `copy`.
- Addressable unit is the **moment** (`file @ shotStart..shotEnd`), not just the file — drag a
  hover-card moment into a Space.
- Library grid scopes to the selected Space; labels filter within it.
- Home screen IA: sidebar gains **Library** (everything understood) and **Spaces** (workspaces),
  alongside the existing **Projects** (editor outputs). A Space spins off timeline Projects.

### M4 — The summary (derived synthesis; last)
Per file/scene, synthesize **transcript + seen (labels/embeddings) + key moments** into a short
human summary. Shown on the hover card and in Space views. Built *after* understanding +
organization exist, because it's a *product* of them. Transcript is a free fallback for talking
footage; an LLM synthesis pass (Koma's agent already calls Anthropic) is the quality version.

---

## Addressing & data model (the durable core)

- **Moment address (portable):** `(rootLabel) / relativePath / file @ shotStart..shotEnd`.
  Survives drive rename/remount — never store raw absolute paths.
- **Label assignment:** `assetKey → [ shotStart : [ (token, score) ] ]`, aggregated to file & folder.
- **Vocabulary:** versioned JSON of `(token, prompts[])` + cached prompt embeddings.
- **Space:** `{ name, filter (labels/query), items: [moment address], materialization }`.
- The editor-project (existing `ProjectRegistry`) becomes an *output* of a Space, not the entry point.

---

## Principles (carry across every milestone)

1. **Own the brain, rent the hands** — applied to indexing. Own the addressing + organization
   model; the understanding engine (SigLIP → next) is swappable behind a stable schema.
2. **Non-destructive always.** Raw footage never moves; organization is pointers (+ optional
   symlink/copy). Local-first: nothing leaves the Mac.
3. **Each milestone is independently valuable.** M1 needs no model work; M2 is free zero-shot;
   M3 is filesystem + UI; M4 is the synthesis. Ship in order.
4. **Moment-level, not file-level.** The hover-card moment is the atom of organization.

---

*Created 2026-06-18. Home for the build: `github.com/Kibo-Colombia/palmier-pro` (the Koma fork —
its OWN repo, not the miraikibo monorepo). Relates to `miraikibo/brain/03_studio/CREATOR.md`
(the web-era Creator vision this supersedes for footage understanding) and the `video-use` skill.*
