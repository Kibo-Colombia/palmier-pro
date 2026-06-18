import Foundation

/// Per-asset classification labels (M2, "The Organizer"), persisted as a JSON sidecar keyed
/// 1:1 with the embeddings via `EmbeddingStore.key`, so a source edit invalidates both
/// together. A label IS a text prompt; classification is search against the fixed vocabulary.

struct TokenScore: Codable, Equatable, Sendable {
    let token: String          // "set:night"
    let score: Float           // peak cosine within the scene
}

struct SceneLabels: Codable, Equatable, Sendable {
    let shotStart: Double
    let shotEnd: Double
    let tokens: [TokenScore]
}

struct FileLabel: Codable, Equatable, Sendable {
    let token: String
    let coverage: Double        // fraction of the file's scenes carrying the label
    let peak: Float             // best score across scenes
}

/// The full label record for one asset. `fingerprint` ties it to a specific
/// (embedding model + vocabulary); a mismatch means re-classify.
struct AssetLabels: Codable, Equatable, Sendable {
    let fingerprint: String
    let scenes: [SceneLabels]
    let file: [FileLabel]
}

enum LabelStore {
    static let directory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(Log.subsystem)/Labels", isDirectory: true)

    static func diskURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).labels.json")
    }

    /// Sidecars are tiny (a few scenes × a few tokens), so a full decode is cheap enough
    /// to double as the staleness check (compare `fingerprint`).
    static func load(key: String) -> AssetLabels? {
        guard let data = try? Data(contentsOf: diskURL(key)) else { return nil }
        return try? JSONDecoder().decode(AssetLabels.self, from: data)
    }

    static func isCurrent(key: String, fingerprint: String) -> Bool {
        load(key: key)?.fingerprint == fingerprint
    }

    static func save(_ labels: AssetLabels, key: String) {
        guard let data = try? JSONEncoder().encode(labels) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: diskURL(key), options: .atomic)
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
