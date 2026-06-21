import CryptoKit
import Foundation
import NaturalLanguage

/// Heard labels — transcript-derived facets (`topic:`, `say:`) in the SAME `facet:value` token model
/// as the seen (visual) labels, but kept in their OWN sidecar. They depend on the transcript, not the
/// pixels, so they regenerate when the transcript changes and NEVER re-run SigLIP. They are merged with
/// the visual labels only at read time (`LabelMerge`) — the visual `LabelStore` sidecar is never touched,
/// and the visual `Vocabulary`/fingerprint is unchanged (so adding these facets re-classifies nothing).

enum HeardFacets {
    static let topic = "topic"
    static let say = "say"
    static let ids = [topic, say]

    /// FacetDefs for the group-by menu only — deliberately NOT part of `Vocabulary` (the SigLIP
    /// fingerprint), so they cost zero re-classification.
    static let defs: [FacetDef] = [
        FacetDef(id: topic, mode: .multi, defaultMargin: 0, maxLabels: 3),
        FacetDef(id: say, mode: .exclusive, defaultMargin: 0, maxLabels: 1),
    ]

    static func isHeard(_ token: String) -> Bool { ids.contains { token.hasPrefix("\($0):") } }

    /// Bump to regenerate every heard sidecar (e.g. after changing the classifier).
    static let version = 1
}

struct HeardLabels: Codable, Equatable, Sendable {
    let fingerprint: String   // transcript content + heard-vocab version
    let file: [FileLabel]
}

enum HeardLabelStore {
    static let directory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(Log.subsystem)/HeardLabels", isDirectory: true)

    static func diskURL(_ key: String) -> URL { directory.appendingPathComponent("\(key).heard.json") }

    /// Generate-or-load the heard file labels. Returns [] when the clip isn't transcribed yet (pending).
    /// Pure read of the transcript + a regenerate-on-change cache; never touches the visual sidecar.
    static func fileLabels(url: URL, key: String?, transcript: TranscriptionResult?) -> [FileLabel] {
        guard let transcript else { return [] }
        let fp = fingerprint(transcript)
        if let key, let cached = load(key: key), cached.fingerprint == fp { return cached.file }
        let file = TranscriptClassifier.fileLabels(transcript)
        if let key { save(HeardLabels(fingerprint: fp, file: file), key: key) }
        return file
    }

    static func fingerprint(_ t: TranscriptionResult) -> String {
        var h = SHA256()
        h.update(data: Data(t.text.utf8))
        h.update(data: Data("|\(t.language ?? "")|v\(HeardFacets.version)".utf8))
        return h.finalize().map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    static func load(key: String) -> HeardLabels? {
        guard let data = try? Data(contentsOf: diskURL(key)) else { return nil }
        return try? JSONDecoder().decode(HeardLabels.self, from: data)
    }

    static func save(_ labels: HeardLabels, key: String) {
        guard let data = try? JSONEncoder().encode(labels) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: diskURL(key), options: .atomic)
    }

    static func clearAll() { try? FileManager.default.removeItem(at: directory) }
}

/// Transcript → heard facets, Tier 0 (free, on-device): a `say:` content-type from transcript shape
/// and a few `topic:` tags from NaturalLanguage named entities + salient nouns. (Tier-1 LLM refinement
/// is a deferred follow-up — same path SummaryService uses.)
enum TranscriptClassifier {
    static func fileLabels(_ t: TranscriptionResult) -> [FileLabel] {
        [sayLabel(t)] + topicLabels(t)
    }

    private static func sayLabel(_ t: TranscriptionResult) -> FileLabel {
        let trimmed = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split { $0.isWhitespace }.count
        let kind: String
        if trimmed.isEmpty { kind = "silent" }
        else if words < 15 { kind = "intro" }
        else if words < 60 { kind = "explainer" }
        else { kind = "story" }
        return FileLabel(token: "say:\(kind)", coverage: 1, peak: 1)
    }

    private static let stopwords: Set<String> = [
        "thing", "things", "time", "way", "people", "lot", "kind", "stuff", "guys", "guy",
        "something", "someone", "anything", "everything", "today", "video", "yeah", "okay",
        "bit", "part", "point", "place", "right", "sort", "type", "year", "day", "week",
    ]

    private static func topicLabels(_ t: TranscriptionResult, max: Int = 3) -> [FileLabel] {
        let text = t.text
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass])
        tagger.string = text
        if let lang = t.language { tagger.setLanguage(NLLanguage(lang), range: text.startIndex..<text.endIndex) }
        let opts: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .omitOther, .joinNames]
        let range = text.startIndex..<text.endIndex
        var counts: [String: Int] = [:]

        tagger.enumerateTags(in: range, unit: .word, scheme: .nameType, options: opts) { tag, r in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) {
                let w = text[r].lowercased()
                if w.count >= 3 { counts[w, default: 0] += 3 }   // entities weigh more
            }
            return true
        }
        tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass, options: opts) { tag, r in
            if tag == .noun {
                let w = text[r].lowercased()
                if w.count >= 4, !stopwords.contains(w) { counts[w, default: 0] += 1 }
            }
            return true
        }

        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(max)
            .compactMap { word, count in
                let slug = Self.slug(word)
                guard !slug.isEmpty else { return nil }
                return FileLabel(token: "topic:\(slug)", coverage: 1, peak: Float(min(1.0, Double(count) / 5)))
            }
    }

    private static func slug(_ s: String) -> String {
        let cleaned = s.folding(options: .diacriticInsensitive, locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ")).inverted)
            .joined()
            .split { $0.isWhitespace }
            .joined(separator: "-")
        return String(cleaned.prefix(24))
    }
}

/// Read-time overlay: seen labels (with the audio→visual fusion applied) + heard labels. Never written
/// back to `LabelStore`, so a transcript change regenerates heard labels without re-running SigLIP.
enum LabelMerge {
    enum Said { case unknown, silent, speech }

    static func merged(visual: [FileLabel], url: URL, key: String?) -> [FileLabel] {
        let transcript = TranscriptCache.cachedOnDisk(for: url)
        let fused = fuse(visual: visual, said: saidState(transcript))
        let heard = HeardLabelStore.fileLabels(url: url, key: key, transcript: transcript)
        return fused + heard
    }

    static func saidState(_ t: TranscriptionResult?) -> Said {
        guard let t else { return .unknown }
        return t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .silent : .speech
    }

    /// Sharpen the editor-critical `use:` (and `act:`) from what was said — the single highest-value
    /// fusion. Conservative and read-time only: speech + a person ⇒ talking-head; silence ⇒ b-roll.
    static func fuse(visual: [FileLabel], said: Said) -> [FileLabel] {
        guard said != .unknown else { return visual }
        var labels = visual
        let hasPerson = labels.contains { $0.token == "subj:person" || $0.token == "subj:hands" }

        func dropFacet(_ f: String) { labels.removeAll { $0.token.hasPrefix("\(f):") } }
        func ensure(_ token: String) {
            if !labels.contains(where: { $0.token == token }) {
                labels.append(FileLabel(token: token, coverage: 1, peak: 1))
            }
        }

        if said == .speech, hasPerson {
            dropFacet("use"); ensure("use:talking-head"); ensure("act:talking")
        } else if said == .silent {
            dropFacet("use"); ensure("use:broll")
        }
        return labels
    }
}
