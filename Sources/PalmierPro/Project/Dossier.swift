import Foundation

/// The shared "what we understand about this footage" model, gathered passively from the on-disk
/// sidecars Koma already built (`LabelStore` + heard labels, `TranscriptCache`, `SummaryStore`,
/// `EmbeddingStore` shots) — no model inference, no network. Two renderers consume it and so can
/// never drift: the markdown editor-handoff (`SpaceBrief`) and the live SwiftUI Library inspector.
struct FileDossier: Sendable, Identifiable {
    let url: URL
    let index: Int
    let summary: String?
    let summaryIsAI: Bool
    let fileLabels: [String]          // seen (visual, fused), ranked
    let heardLabels: [String]         // heard (transcript): say:, topic:
    let scenes: [SceneLabels]         // timecoded shot labels
    let transcript: TranscriptionResult?

    var id: String { url.path }

    init(url: URL, index: Int = 0) {
        self.url = url
        self.index = index
        let key = EmbeddingStore.key(for: url)
        let labels = key.flatMap { LabelStore.load(key: $0) }
        let merged = LabelMerge.merged(visual: labels?.file ?? [], url: url, key: key)
        self.fileLabels = merged.filter { !HeardFacets.isHeard($0.token) }
            .sorted { ($0.coverage * Double($0.peak)) > ($1.coverage * Double($1.peak)) }
            .map(\.token)
        self.heardLabels = merged.filter { HeardFacets.isHeard($0.token) }.map(\.token)
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

    var language: String? {
        guard let lang = transcript?.language, !lang.isEmpty else { return nil }
        return lang
    }

    /// The say: content-type value (intro/explainer/story/silent), if classified.
    var sayValue: String? { heardLabels.first { $0.hasPrefix("say:") }.map(Self.value) }

    /// Best one-line description for tables/slugs: the summary if present, else the top labels.
    var oneLiner: String {
        if let summary, !summary.isEmpty { return summary }
        let vals = fileLabels.prefix(4).map(Self.value).joined(separator: ", ")
        return vals.isEmpty ? "—" : vals
    }

    /// Approx duration from the last shot's end (avoids loading the asset).
    var approxDuration: Double? { scenes.last?.shotEnd }

    static func value(_ token: String) -> String { token.split(separator: ":").last.map(String.init) ?? token }

    /// One merged, time-sorted log of shot markers + speech — the single source for both the inspector
    /// timeline and the handoff `.md`, so they can't diverge.
    struct TimelineEvent: Sendable, Identifiable {
        let time: Double
        let isSpeech: Bool
        let text: String              // shot: "wide · outdoor" ; speech: the quote
        var id: String { "\(isSpeech ? "s" : "v")-\(time)-\(text.prefix(12))" }
    }

    var timelineEvents: [TimelineEvent] {
        var events: [TimelineEvent] = []
        for scene in scenes {
            let vals = scene.tokens.prefix(4).map { Self.value($0.token) }.joined(separator: " · ")
            if !vals.isEmpty { events.append(TimelineEvent(time: scene.shotStart, isSpeech: false, text: vals)) }
        }
        for seg in transcript?.segments ?? [] {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { events.append(TimelineEvent(time: seg.start, isSpeech: true, text: text)) }
        }
        return events.sorted { $0.time < $1.time }
    }
}

/// A Space / folder / root as an understanding overview — the same data the `_SPACE.md` manifest exports.
struct SpaceDossier: Sendable {
    let name: String
    let files: [FileDossier]

    init(name: String, files: [URL]) {
        self.name = name
        self.files = files.enumerated().map { FileDossier(url: $1, index: $0 + 1) }
    }

    var clipCount: Int { files.count }
    var languages: [String] { Array(Set(files.compactMap(\.language))).sorted() }
}
