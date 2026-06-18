import Foundation

/// Orchestrates classification for the UI (M2). Cards ask for a file's labels; this builds the
/// label vectors once per (model, vocabulary), classifies on demand from the existing
/// embeddings, caches the result in memory + as a sidecar, and returns the file-level tokens.
///
/// Lazy per-asset (mirrors `KeyframeThumbnailCache`): classifying an asset only loads its
/// embeddings and runs one SGEMM — no model inference per asset.
@MainActor
final class ClassificationService {
    static let shared = ClassificationService()

    private var labelVectors: LabelVectors?
    private var memory: [String: AssetLabels] = [:]
    private var inFlight: Set<String> = []

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

        if let cached = memory[key], cached.fingerprint == fingerprint { return cached }

        // Valid sidecar on disk → adopt it.
        if let disk = LabelStore.load(key: key), disk.fingerprint == fingerprint {
            memory[key] = disk
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
        Log.search.notice("classified \(url.lastPathComponent) scenes=\(result.scenes.count) fileLabels=\(result.file.count) top=[\(result.file.prefix(4).map(\.token).joined(separator: ", "))]")
        return result
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
