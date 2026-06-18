import Foundation

/// Orchestrates classification for the UI (M2). Cards ask for a file's labels; this builds the
/// label vectors once per (model, vocabulary), classifies on demand from the existing
/// embeddings, caches the result in memory + as a sidecar, and returns the file-level tokens.
///
/// Lazy per-asset (mirrors `KeyframeThumbnailCache`): classifying an asset only loads its
/// embeddings and runs one SGEMM — no model inference per asset.
@Observable
@MainActor
final class ClassificationService {
    static let shared = ClassificationService()

    /// Per-file top label tokens keyed by file path — the observable lookup the library grid
    /// filters on. Populated as assets get classified (lazily per card and via `classifyAll`).
    private(set) var tokensByPath: [String: Set<String>] = [:]
    /// Ranked file labels keyed by path — used to pick a clip's strongest tag within a facet
    /// when grouping the library.
    private(set) var fileLabelsByPath: [String: [FileLabel]] = [:]

    /// The clip's strongest label within a facet ("set" → "set:indoor"), or nil if untagged there.
    func topToken(forPath path: String, facet: String) -> String? {
        (fileLabelsByPath[path] ?? [])
            .filter { $0.token.hasPrefix("\(facet):") }
            .max { $0.coverage * Double($0.peak) < $1.coverage * Double($1.peak) }?
            .token
    }

    @ObservationIgnored private var labelVectors: LabelVectors?
    @ObservationIgnored private var memory: [String: AssetLabels] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []

    /// File-level labels for a card. Returns nil while the model isn't ready or a classify is
    /// already running, so the caller simply shows no chips yet.
    func fileLabels(forURL url: URL, key: String) async -> [FileLabel]? {
        await assetLabels(forURL: url, key: key)?.file
    }

    /// Full label record (scenes + file). M4 consumes the per-scene tokens.
    func assetLabels(forURL url: URL, key: String) async -> AssetLabels? {
        guard let embedder = VisualModelLoader.shared.embedder, VisualModelLoader.shared.isReady else {
            Log.search.notice("classify skip: model not ready (state=\(String(describing: VisualModelLoader.shared.state)))")
            return nil
        }
        let vocab = Vocabulary.current()
        let fingerprint = vocab.fingerprint(model: embedder.spec.model, modelVersion: embedder.spec.version)

        if let cached = memory[key], cached.fingerprint == fingerprint {
            record(cached, path: url.path)
            return cached
        }

        // Valid sidecar on disk → adopt it.
        if let disk = LabelStore.load(key: key), disk.fingerprint == fingerprint {
            memory[key] = disk
            record(disk, path: url.path)
            return disk
        }

        guard !inFlight.contains(key) else { return nil }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        guard let vectors = await ensureLabelVectors(vocab: vocab, embedder: embedder, fingerprint: fingerprint) else {
            Log.search.warning("classify abort: label vectors failed to build")
            return nil
        }

        let result = await Task.detached(priority: .utility) { () -> AssetLabels? in
            guard let index = try? EmbeddingStore.load(key: key) else { return nil }
            return SceneClassifier.classify(index: index, vocab: vocab, vectors: vectors, fingerprint: fingerprint)
        }.value
        guard let result else {
            Log.search.warning("classify abort: no embedding index for key=\(key.prefix(8))")
            return nil
        }

        LabelStore.save(result, key: key)
        memory[key] = result
        record(result, path: url.path)
        Log.search.notice("classified \(url.lastPathComponent) scenes=\(result.scenes.count) fileLabels=\(result.file.count) top=[\(result.file.prefix(4).map(\.token).joined(separator: ", "))]")
        return result
    }

    /// Classify every video/image asset that isn't yet labelled, so the library filter (and
    /// later M4 summaries) have complete data — not just the cards that happened to be scrolled
    /// into view. Cheap: one SGEMM per asset over its existing embeddings.
    func classifyAll(urls: [URL]) async {
        for url in urls {
            guard let key = EmbeddingStore.key(for: url) else { continue }
            _ = await assetLabels(forURL: url, key: key)
        }
    }

    private func record(_ labels: AssetLabels, path: String) {
        tokensByPath[path] = Set(labels.file.map(\.token))
        fileLabelsByPath[path] = labels.file
    }

    private func ensureLabelVectors(vocab: Vocabulary, embedder: VisualEmbedder, fingerprint: String) async -> LabelVectors? {
        if let existing = labelVectors, existing.fingerprint == fingerprint { return existing }
        let built = await Task.detached(priority: .utility) {
            SceneClassifier.buildLabelVectors(vocab: vocab, embedder: embedder, fingerprint: fingerprint)
        }.value
        if let built { labelVectors = built }
        return built
    }
}
