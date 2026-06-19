import Foundation

/// Per-file human summary for the (i) popover (M4, "The Organizer"). A *product* of the
/// understanding + organization layers — it only reads what those already cached, never triggering
/// transcription or classification itself.
///
/// - **Tier 0** (always-on, on-device): a gist of the cached transcript ("said"), else the
///   strongest classification tokens ("seen"). Free, offline, no account.
/// - **Tier 1** (opt-in, never auto-runs): an LLM (Haiku) synthesizes tags + transcript + a few
///   key frames into a real sentence. Gated behind a key/subscription; persisted so the paid call
///   happens once per clip.
@Observable
@MainActor
final class SummaryService {
    static let shared = SummaryService()

    @ObservationIgnored private var memory: [String: AssetSummary] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []

    /// Whether the opt-in LLM tier is available (BYO key, or signed in with credits). Self-gated
    /// rather than via the per-project `AgentService`, since summaries run on the home screen.
    var canUseLLM: Bool {
        if let key = AnthropicKeychain.load(), !key.isEmpty { return true }
        let account = AccountService.shared
        return account.isSignedIn && account.hasCredits
    }

    /// The current summary (Tier 0 unless an LLM summary was generated and is still valid), or nil
    /// when neither a transcript nor labels exist yet. Adopts a valid sidecar; otherwise computes
    /// Tier 0 and persists it.
    func fileSummary(forURL url: URL, key: String) async -> AssetSummary? {
        if let cached = memory[key] { return cached }
        guard !inFlight.contains(key) else { return nil }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        let result = await Task.detached(priority: .utility) { () -> AssetSummary? in
            let fingerprint = Self.fingerprint(url: url, key: key)
            if let disk = SummaryStore.load(key: key), disk.fingerprint == fingerprint {
                return disk
            }
            guard let text = SummaryTier0.fileSummary(url: url, key: key) else { return nil }
            let summary = AssetSummary(fingerprint: fingerprint, fileSummary: text, fileTier: 0, scenes: [])
            SummaryStore.save(summary, key: key)
            return summary
        }.value
        if let result { memory[key] = result }
        return result
    }

    /// Opt-in Tier 1: synthesize a one-line caption with the LLM and persist it. Returns nil and
    /// degrades silently if the tier is unavailable or the call fails.
    func generateLLMSummary(forURL url: URL, key: String) async -> AssetSummary? {
        guard canUseLLM, let client = makeClient() else { return nil }

        let tokens = topTokens(key: key)
        let transcript = transcriptExcerpt(url: url)
        let richTranscript = (transcript?.count ?? 0) >= 40
        // Frames carry the most signal for visual footage; fewer when there's real speech.
        let frames = await KeyframeThumbnailCache.shared.keyframes(forURL: url, key: key) ?? []
        let imageBlocks: [[String: Any]] = sampleFrames(frames, max: richTranscript ? 1 : 3).compactMap { frame in
            guard let data = ImageEncoder.encodeJPEG(frame.image, quality: 0.6) else { return nil }
            return ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]]
        }
        guard !imageBlocks.isEmpty || !tokens.isEmpty || transcript != nil else { return nil }

        var lines: [String] = []
        if !tokens.isEmpty { lines.append("Tags: " + tokens.joined(separator: ", ")) }
        lines.append("Transcript: " + (transcript.map { "\"\($0)\"" } ?? "none (silent or untranscribed)"))
        var content: [[String: Any]] = imageBlocks
        content.append(["type": "text", "text": lines.joined(separator: "\n")])
        let message = AnthropicMessage(role: .user, content: content)

        do {
            let raw = try await client.complete(system: Self.llmSystem, message: message)
            let text = Self.cleanLLM(raw)
            guard !text.isEmpty else { return nil }
            let summary = AssetSummary(
                fingerprint: Self.fingerprint(url: url, key: key),
                fileSummary: text, fileTier: 1, scenes: []
            )
            SummaryStore.save(summary, key: key)
            memory[key] = summary
            return summary
        } catch {
            Log.search.warning("LLM summary failed for \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - LLM plumbing

    private func makeClient() -> (any AgentClient)? {
        if let key = AnthropicKeychain.load(), !key.isEmpty {
            return AnthropicClient(apiKey: key, model: .haiku45)
        }
        if AccountService.shared.isSignedIn {
            // Free Palmier offers Haiku; paid offers Sonnet — pick what the account is allowed.
            return PalmierClient(model: AccountService.shared.isPaid ? .sonnet46 : .haiku45)
        }
        return nil
    }

    private static let llmSystem = """
    You caption video clips for an editor's media library. Given tags, a transcript excerpt, \
    and/or key frames, write ONE concrete sentence (max 140 characters) describing what the clip \
    shows — subject, action, setting. Present tense, no preamble, no quotes, no markdown.
    """

    private func topTokens(key: String) -> [String] {
        (LabelStore.load(key: key)?.file ?? [])
            .sorted { $0.coverage * Double($0.peak) > $1.coverage * Double($1.peak) }
            .prefix(8)
            .map { String($0.token.drop { $0 != ":" }.dropFirst()) }
    }

    private func transcriptExcerpt(url: URL) -> String? {
        guard let text = TranscriptCache.cachedOnDisk(for: url)?.text
            .trimmingCharacters(in: .whitespacesAndNewlines), text.count >= 8 else { return nil }
        return String(text.prefix(600))
    }

    /// First / middle / last (deduped, in order) up to `max`.
    private func sampleFrames(_ frames: [KeyframeThumbnailCache.Keyframe], max: Int) -> [KeyframeThumbnailCache.Keyframe] {
        guard frames.count > max, max > 0 else { return frames }
        let step = Double(frames.count - 1) / Double(max - 1)
        var picked: [Int] = []
        for i in 0..<max {
            let idx = Int((Double(i) * step).rounded())
            if picked.last != idx { picked.append(idx) }
        }
        return picked.map { frames[$0] }
    }

    private static func cleanLLM(_ text: String) -> String {
        var t = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        t = t.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count > 1 { t = String(t.dropFirst().dropLast()) }
        return String(t.prefix(180)).trimmingCharacters(in: .whitespaces)
    }

    /// The inputs a summary is derived from — re-index / re-classify / transcribe regenerates it.
    private nonisolated static func fingerprint(url: URL, key: String) -> String {
        let header = EmbeddingStore.header(key: key)
        let model = header?.model ?? "none"
        let modelVersion = header?.modelVersion ?? 0
        let sampler = header?.samplerVersion ?? 0
        let vocab = Vocabulary.current().fingerprint(model: model, modelVersion: modelVersion)
        let hasTranscript = TranscriptCache.hasCachedOnDisk(for: url)
        return "v1|\(vocab)|s\(sampler)|t\(hasTranscript ? 1 : 0)"
    }
}

/// Pure, on-device Tier-0 synthesis. No model, no network.
enum SummaryTier0 {
    static func fileSummary(url: URL, key: String) -> String? {
        saidGist(url: url) ?? seenPhrase(key: key)
    }

    private static func saidGist(url: URL) -> String? {
        guard let transcript = TranscriptCache.cachedOnDisk(for: url) else { return nil }
        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 8 else { return nil }
        return gist(text, max: 140)
    }

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

    private static func value(_ token: String) -> String {
        String(token.drop { $0 != ":" }.dropFirst())
    }

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
