import Foundation

/// Per-file human summary for the (i) popover (M4, "The Organizer"). Tier 0 is always-on and
/// fully on-device: it prefers a gist of the cached transcript (the "said" layer) and falls back
/// to the classification tokens (the "seen" layer). It's a *product* of the understanding +
/// organization layers, so it only reads what those already cached — it never triggers
/// transcription or classification itself. Tier 1 (an LLM synthesis, opt-in) lands next and will
/// persist its richer output in a sidecar; Tier 0 is cheap enough to keep in memory per session.
@Observable
@MainActor
final class SummaryService {
    static let shared = SummaryService()

    @ObservationIgnored private var memory: [String: String] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []

    /// A short summary of the file, or nil when neither a transcript nor labels exist yet. Only
    /// positive results are memoized, so a summary appears once its inputs (transcript/labels)
    /// land — even if an earlier call came up empty.
    func fileSummary(forURL url: URL, key: String) async -> String? {
        if let cached = memory[key] { return cached }
        guard !inFlight.contains(key) else { return nil }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        let summary = await Task.detached(priority: .utility) {
            SummaryTier0.fileSummary(url: url, key: key)
        }.value
        if let summary { memory[key] = summary }
        return summary
    }
}

/// Pure, on-device Tier-0 synthesis. No model, no network.
enum SummaryTier0 {
    static func fileSummary(url: URL, key: String) -> String? {
        saidGist(url: url) ?? seenPhrase(key: key)
    }

    /// A gist of the spoken content, if the file was already transcribed (disk-only read).
    private static func saidGist(url: URL) -> String? {
        guard let transcript = TranscriptCache.cachedOnDisk(for: url) else { return nil }
        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 8 else { return nil }
        return gist(text, max: 140)
    }

    /// The strongest classification tokens, one per facet, in reading order — the "seen" identity
    /// of silent footage ("outdoor · day · wide · establishing").
    private static func seenPhrase(key: String) -> String? {
        guard let labels = LabelStore.load(key: key), !labels.file.isEmpty else { return nil }
        let ranked = labels.file.sorted { $0.coverage * Double($0.peak) > $1.coverage * Double($1.peak) }
        var bestPerFacet: [String: String] = [:]
        for label in ranked {
            let facet = String(label.token.prefix { $0 != ":" })
            if bestPerFacet[facet] == nil { bestPerFacet[facet] = value(label.token) }
        }
        let ordered = ["subj", "act", "set", "shot", "mood", "use"].compactMap { bestPerFacet[$0] }
        let values = Array(ordered.prefix(4))
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    /// "set:night" → "night"
    private static func value(_ token: String) -> String {
        String(token.drop { $0 != ":" }.dropFirst())
    }

    /// Collapse whitespace and trim to `max`, breaking on a sentence end or word boundary.
    private static func gist(_ text: String, max: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if collapsed.count <= max { return collapsed }
        let slice = collapsed.prefix(max)
        if let end = slice.lastIndex(where: { ".!?".contains($0) }) {
            return String(slice[...end])
        }
        if let space = slice.lastIndex(of: " ") {
            return String(slice[..<space]) + "…"
        }
        return slice + "…"
    }
}
