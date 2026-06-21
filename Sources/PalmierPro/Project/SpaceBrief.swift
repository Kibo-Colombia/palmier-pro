import Foundation

/// Turns a Space's understood footage into an editor handoff package (M3, "The Organizer"):
/// a per-clip `.md` (summary + labels on top, then a timecoded shot/speech log + full transcript)
/// and one `_SPACE.md` manifest that lets an editor orient in a single read. Everything is read
/// passively from the on-disk sidecars Koma already built (`LabelStore` scenes, `TranscriptCache`
/// segments, `SummaryStore`) — no model inference, no network. Pure formatting; the file I/O lives
/// in `SpaceMaterializer`.
///
/// Optional `rename` derives a human-readable output name from each clip's summary/labels so the
/// editor sees "01_morning-walk-wide.mp4" instead of "IMG_4821.mov" — applied ONLY to the copies,
/// never the originals. Each clip's `.md` shares its (possibly renamed) base, so file and brief
/// always travel as a pair.
@MainActor
enum SpaceBrief {
    /// One clip's place in the package: where it came from, what it's called on the way out, and
    /// the already-rendered markdown for its companion doc. `outBase` carries no extension and is
    /// unique within the package.
    struct FilePlan: Sendable {
        let source: URL
        let outBase: String
        let ext: String
        let markdown: String
        var mediaName: String { ext.isEmpty ? outBase : "\(outBase).\(ext)" }
        var docName: String { "\(outBase).md" }
    }

    struct Package: Sendable {
        let plans: [FilePlan]
        let manifestName: String
        let manifest: String
    }

    /// Build the handoff package for `files` (the Space's unique source clips, in first-seen order).
    static func build(spaceName: String, files: [URL], rename: Bool) -> Package {
        var usedBases = Set<String>()
        var dossiers: [Dossier] = []
        var plans: [FilePlan] = []

        for (i, url) in files.enumerated() {
            let d = Dossier(url: url, index: i + 1)
            let desired = rename ? slug(for: d, index: i + 1) : url.deletingPathExtension().lastPathComponent
            let base = uniqueBase(desired.isEmpty ? "clip-\(i + 1)" : desired, used: &usedBases)
            dossiers.append(d)
            plans.append(FilePlan(source: url, outBase: base, ext: url.pathExtension, markdown: fileMarkdown(d, mediaName: base + (url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"))))
        }

        let manifest = manifestMarkdown(spaceName: spaceName, dossiers: dossiers, plans: plans)
        return Package(plans: plans, manifestName: "_SPACE.md", manifest: manifest)
    }

    // MARK: - Dossier (passive reads of the sidecars)

    /// Everything we know about one clip, gathered from the caches. No inference.
    private struct Dossier {
        let url: URL
        let index: Int
        let summary: String?
        let summaryIsAI: Bool
        let fileLabels: [String]          // "shot:wide", ranked
        let scenes: [SceneLabels]         // timecoded shot labels
        let transcript: TranscriptionResult?

        init(url: URL, index: Int) {
            self.url = url
            self.index = index
            let key = EmbeddingStore.key(for: url)
            let labels = key.flatMap { LabelStore.load(key: $0) }
            self.fileLabels = (labels?.file ?? [])
                .sorted { ($0.coverage * Double($0.peak)) > ($1.coverage * Double($1.peak)) }
                .map(\.token)
            self.scenes = (labels?.scenes ?? []).sorted { $0.shotStart < $1.shotStart }
            let summary = key.flatMap { SummaryStore.load(key: $0) }
            self.summary = summary?.fileSummary
            self.summaryIsAI = (summary?.fileTier ?? 0) >= 1
            self.transcript = TranscriptCache.cachedOnDisk(for: url)
        }

        var said: String {
            guard let transcript else { return "not transcribed" }
            return transcript.text.isEmpty ? "silent" : "speech"
        }

        /// Best one-line description for tables/slugs: the summary if present, else the top labels.
        var oneLiner: String {
            if let summary, !summary.isEmpty { return summary }
            let vals = fileLabels.prefix(4).map(Self.value).joined(separator: ", ")
            return vals.isEmpty ? "—" : vals
        }

        /// Approx duration from the last shot's end (avoids loading the asset).
        var approxDuration: Double? { scenes.last?.shotEnd }

        static func value(_ token: String) -> String { token.split(separator: ":").last.map(String.init) ?? token }
    }

    // MARK: - Per-file markdown

    private static func fileMarkdown(_ d: Dossier, mediaName: String) -> String {
        var out = "# \(prettyTitle(d))\n\n"
        out += "**File:** `\(mediaName)`  \n"
        out += "**Original:** `\(d.url.lastPathComponent)`  \n"
        if let dur = d.approxDuration { out += "**Length:** ~\(timecode(dur))  \n" }
        if let lang = d.transcript?.language, !lang.isEmpty { out += "**Audio:** \(lang)  \n" }
        out += "\n"

        if let s = d.summary, !s.isEmpty {
            out += "**Summary:** \(s)\(d.summaryIsAI ? " ✨" : "")\n\n"
        }
        if !d.fileLabels.isEmpty {
            out += "**Labels:** " + d.fileLabels.prefix(8).map { "`\($0)`" }.joined(separator: " · ") + "\n\n"
        }

        let timeline = timelineLines(d)
        if !timeline.isEmpty {
            out += "## Timeline\n\n"
            out += timeline.joined(separator: "\n") + "\n\n"
        }

        if let t = d.transcript, !t.text.isEmpty {
            out += "## Transcript\n\n\(t.text)\n"
        } else if d.said == "silent" {
            out += "_No speech detected._\n"
        }

        if d.summary == nil && d.fileLabels.isEmpty && timeline.isEmpty {
            out += "_Not yet analyzed by Koma — open the Library and let it index to add a summary, labels, and a shot log._\n"
        }
        return out
    }

    /// Merge timecoded shot labels and speech segments into one source-relative timeline (clip
    /// start = 0:00). Shot markers read "▸ wide · outdoor · walking"; speech lines quote the words.
    private static func timelineLines(_ d: Dossier) -> [String] {
        var events: [(time: Double, line: String)] = []
        for scene in d.scenes {
            let vals = scene.tokens.prefix(4).map { Dossier.value($0.token) }.joined(separator: " · ")
            guard !vals.isEmpty else { continue }
            events.append((scene.shotStart, "- `\(timecode(scene.shotStart))`  ▸ \(vals)"))
        }
        for seg in d.transcript?.segments ?? [] {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            events.append((seg.start, "- `\(timecode(seg.start))`  \u{201C}\(truncate(text, 90))\u{201D}"))
        }
        return events.sorted { $0.time < $1.time }.prefix(400).map(\.line)
    }

    // MARK: - Manifest markdown

    private static func manifestMarkdown(spaceName: String, dossiers: [Dossier], plans: [FilePlan]) -> String {
        let name = spaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = "# \(name.isEmpty ? "Space" : name) — editor handoff\n\n"
        out += "\(dossiers.count) clip\(dossiers.count == 1 ? "" : "s") · prepared by Koma · **originals were never modified.**\n\n"
        out += "Each clip has a matching `.md` with its summary, labels, full transcript, and a timecoded shot log. Timecodes are clip-relative (each clip starts at 0:00).\n\n"

        out += "| # | File | What it is | Labels | Audio |\n"
        out += "|---|------|-----------|--------|-------|\n"
        for (d, plan) in zip(dossiers, plans) {
            let labels = d.fileLabels.prefix(4).map(Dossier.value).joined(separator: ", ")
            out += "| \(String(format: "%02d", d.index)) | `\(plan.mediaName)` | \(escapeCell(truncate(d.oneLiner, 80))) | \(escapeCell(labels)) | \(d.said) |\n"
        }

        out += "\n## For the editor\n\n"
        out += "- These are **copies** — cut, rename, and reorganize freely; the originals stay untouched in Koma.\n"
        out += "- Open any clip's `.md` for its shot log and transcript.\n"
        return out
    }

    // MARK: - Naming

    /// Human-readable, filesystem-safe base derived from the clip's summary (preferred) or labels.
    private static func slug(for d: Dossier, index: Int) -> String {
        let source: String
        if let s = d.summary, !s.isEmpty {
            source = s
        } else if !d.fileLabels.isEmpty {
            source = d.fileLabels.prefix(3).map(Dossier.value).joined(separator: " ")
        } else {
            source = d.url.deletingPathExtension().lastPathComponent
        }
        let words = source
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(6)
        let body = words.joined(separator: "-")
        let trimmed = String(body.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let prefix = String(format: "%02d", index)
        return trimmed.isEmpty ? "clip-\(prefix)" : "\(prefix)_\(trimmed)"
    }

    private static func uniqueBase(_ base: String, used: inout Set<String>) -> String {
        var candidate = base
        var n = 2
        while used.contains(candidate.lowercased()) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    // MARK: - Formatting helpers

    private static func prettyTitle(_ d: Dossier) -> String {
        if let s = d.summary, !s.isEmpty { return truncate(s, 70) }
        let vals = d.fileLabels.prefix(3).map(Dossier.value).joined(separator: " · ")
        return vals.isEmpty ? d.url.deletingPathExtension().lastPathComponent : vals
    }

    private static func timecode(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// Keep table cells from breaking the markdown grid.
    private static func escapeCell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
