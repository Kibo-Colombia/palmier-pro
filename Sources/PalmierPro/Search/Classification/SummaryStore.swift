import Foundation

/// Persisted per-asset summary sidecar (M4), keyed 1:1 with the embeddings via `EmbeddingStore.key`
/// so a source edit invalidates it alongside everything else. `fingerprint` folds the inputs a
/// summary is derived from (embedding model + sampler, vocabulary, whether a transcript exists),
/// so re-indexing, re-classifying, or transcribing regenerates it. Tier 0 (local) and Tier 1
/// (LLM) both land here; persisting matters most for Tier 1 — an LLM call is paid, so it's a
/// one-time cost per clip.
struct SceneSummary: Codable, Equatable, Sendable {
    let shotStart: Double
    let shotEnd: Double
    let text: String
    let tier: Int
}

struct AssetSummary: Codable, Equatable, Sendable {
    let fingerprint: String
    let fileSummary: String
    let fileTier: Int          // 0 = local, 1 = LLM
    let scenes: [SceneSummary] // reserved for per-scene summaries; empty for now
}

enum SummaryStore {
    static let directory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(Log.subsystem)/Summaries", isDirectory: true)

    static func diskURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).summary.json")
    }

    static func load(key: String) -> AssetSummary? {
        guard let data = try? Data(contentsOf: diskURL(key)) else { return nil }
        return try? JSONDecoder().decode(AssetSummary.self, from: data)
    }

    static func save(_ summary: AssetSummary, key: String) {
        guard let data = try? JSONEncoder().encode(summary) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: diskURL(key), options: .atomic)
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
