import Foundation

/// A single face sighting in a clip: when it appears and where (normalized, top-left origin
/// `[x, y, w, h]`), plus Vision's capture-quality score (0…1, higher = clearer/more frontal).
struct FaceHit: Codable, Equatable, Sendable {
    let time: Double      // source seconds
    let box: [Double]     // normalized top-left [x, y, w, h]
    let quality: Float
}

/// A representative face crop's image feature print — the raw material for *identity*. Stored as a
/// plain `[Float]` so distance can be computed without rebuilding a `VNFeaturePrintObservation`
/// (which has no public initializer). Not a dedicated face-recognition embedding — a general image
/// feature print of the face crop — so it clusters recurring people well but isn't biometric ID.
struct FacePrint: Codable, Equatable, Sendable {
    let vector: [Float]
    let quality: Float
    let time: Double
    let box: [Double]     // normalized top-left [x, y, w, h]
}

/// Per-clip face understanding (M5 — the "people" layer), a sibling to the visual/label/transcript
/// sidecars. `fingerprint` folds the detector + sampler versions so a detector change re-runs it.
struct FaceRecord: Codable, Equatable, Sendable {
    let fingerprint: String
    let maxFaces: Int        // most faces seen in any single sampled frame (≈ people on screen)
    let hits: [FaceHit]      // presence + timing across the clip
    let prints: [FacePrint]  // top-quality crops, kept for identity clustering

    var hasFace: Bool { !hits.isEmpty }
}

/// Disk cache for `FaceRecord`s, keyed 1:1 with the embeddings via `EmbeddingStore.key` so a source
/// edit invalidates faces alongside everything else. Mirrors `SummaryStore` / `TranscriptCache`.
enum FaceStore {
    static let directory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(Log.subsystem)/Faces", isDirectory: true)

    static func diskURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).faces.json")
    }

    static func load(key: String) -> FaceRecord? {
        guard let data = try? Data(contentsOf: diskURL(key)) else { return nil }
        return try? JSONDecoder().decode(FaceRecord.self, from: data)
    }

    static func save(_ record: FaceRecord, key: String) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: diskURL(key), options: .atomic)
    }

    static func has(key: String) -> Bool {
        FileManager.default.fileExists(atPath: diskURL(key).path)
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Euclidean distance between two feature prints — smaller = more alike. Matches the metric
    /// `VNFeaturePrintObservation.computeDistance` uses (L2 over the normalized feature vector).
    /// Returns `.infinity` for mismatched/empty vectors so they never read as a match.
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var sum: Float = 0
        for i in a.indices { let d = a[i] - b[i]; sum += d * d }
        return sum.squareRoot()
    }
}
