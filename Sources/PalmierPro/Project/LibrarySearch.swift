import Foundation

/// Library-wide search over everything Koma has understood — the same three layers the
/// editor's media panel searches, but across the whole corpus with no project open:
///   • **Moments** — semantic SigLIP text→frame match ("sunset over the city"), best-per-shot
///   • **Spoken** — keyword match inside the on-device transcripts
///   • **Files** — filename substring
/// The semantic pass streams file-by-file (one embedding sidecar in memory at a time), so a
/// 900-clip corpus searches in a couple of seconds without holding hundreds of MB of vectors.
@MainActor
@Observable
final class LibrarySearchModel {
    struct MomentHit: Identifiable, Equatable {
        let url: URL
        let time: Double
        let shotStart: Double
        let shotEnd: Double
        var id: String { "\(url.path)@\(shotStart)" }
    }

    struct SpokenHit: Identifiable, Equatable {
        let url: URL
        let start: Double
        let end: Double
        let text: String
        var id: String { "\(url.path)@\(start)" }
    }

    var query = ""
    private(set) var isSearching = false
    private(set) var moments: [MomentHit] = []
    private(set) var spoken: [SpokenHit] = []
    private(set) var files: [URL] = []
    /// True when the visual model isn't ready — spoken/file results still work.
    private(set) var visualUnavailable = false

    var isActive: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isEmpty: Bool { moments.isEmpty && spoken.isEmpty && files.isEmpty }

    private var task: Task<Void, Never>?

    func clear() {
        task?.cancel()
        query = ""
        moments = []
        spoken = []
        files = []
        isSearching = false
    }

    /// Debounced; cheap passes (filename + spoken) land first, the semantic pass streams in
    /// after. Cancelled wholesale by the next keystroke.
    func scheduleSearch() {
        task?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            moments = []; spoken = []; files = []; isSearching = false
            return
        }
        let candidates = RootsRegistry.shared.files
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.isSearching = true

            let quick = await Task.detached(priority: .userInitiated) { () -> (names: [URL], spoken: [TranscriptSearch.Hit]) in
                let names = candidates.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(trimmed) }
                let assets = candidates.map { (id: $0.path, url: $0) }
                return (names, TranscriptSearch.search(query: trimmed, assets: assets, limit: 24))
            }.value
            guard !Task.isCancelled, let self else { return }
            self.files = Array(quick.names.prefix(24))
            self.spoken = quick.spoken.map {
                SpokenHit(url: URL(fileURLWithPath: $0.assetID), start: $0.start, end: $0.end, text: $0.text)
            }

            let visual = await Self.visualSearch(query: trimmed, files: candidates)
            guard !Task.isCancelled else { return }
            self.visualUnavailable = (visual == nil)
            self.moments = visual ?? []
            self.isSearching = false
        }
    }

    /// Streamed semantic search: encode the query once, then score one file's embedding
    /// sidecar at a time and keep only its top shots. The global relative cutoff (same idea
    /// as `VisualSearch.search`) applies at the end so results stay proportional to the best
    /// match across the corpus. Returns nil while the visual model isn't loaded.
    private static func visualSearch(query: String, files: [URL]) async -> [MomentHit]? {
        guard let model = VisualModelLoader.shared.embedder, VisualModelLoader.shared.isReady else { return nil }
        let minScore = SearchIndexConfig.visualMatchCosineFloor
        return await Task.detached(priority: .userInitiated) { () -> [MomentHit]? in
            guard let vector = try? model.encode(text: query) else { return nil }
            var all: [VisualSearch.Hit] = []
            for url in files {
                if Task.isCancelled { return nil }
                guard let key = EmbeddingStore.key(for: url),
                      let index = try? EmbeddingStore.load(key: key) else { continue }
                all.append(contentsOf: VisualSearch.search(
                    query: vector, indexes: [(url.path, index)],
                    limit: 4, relativeCutoff: 0, minScore: minScore
                ))
            }
            guard let top = all.map(\.score).max(), top > 0 else { return [] }
            let floor = top * 0.85
            return all.filter { $0.score >= floor }
                .sorted { $0.score > $1.score }
                .prefix(24)
                .map { MomentHit(url: URL(fileURLWithPath: $0.assetID), time: $0.time, shotStart: $0.shotStart, shotEnd: $0.shotEnd) }
        }.value
    }
}
