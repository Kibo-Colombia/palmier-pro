import AVFoundation
import Foundation

/// Indexes + classifies the Library's footage (M2c) — the roots that aren't part of an open
/// project, so the per-project `SearchIndexCoordinator` never sees them. Reuses `VisualIndexer`
/// directly (no MediaAsset needed) and then `ClassificationService.classifyAll`, so library
/// cards light up with the same hover-scrub key moments and label chips as project media.
@Observable
@MainActor
final class LibraryIndexer {
    static let shared = LibraryIndexer()

    private(set) var done = 0
    private(set) var total = 0
    var isIndexing: Bool { done < total }

    private var task: Task<Void, Never>?

    /// Index any not-yet-indexed videos among `urls`, then classify the whole set. Idempotent —
    /// a second call while running is ignored; already-indexed files are skipped cheaply.
    func ensureIndexed(_ urls: [URL]) {
        guard task == nil, !urls.isEmpty else { return }
        task = Task { [weak self] in
            await self?.run(urls)
            self?.task = nil
        }
    }

    private func run(_ urls: [URL]) async {
        // The model loads a beat after launch; wait briefly rather than no-op.
        for _ in 0..<40 where !VisualModelLoader.shared.isReady {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
        }
        guard let model = VisualModelLoader.shared.embedder, VisualModelLoader.shared.isReady else { return }

        let pending = urls.filter { VisualIndexer.needsIndex(url: $0, spec: model.spec) }
        total = pending.count
        done = 0
        for url in pending {
            if Task.isCancelled { break }
            let duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            try? await VisualIndexer.index(url: url, duration: duration, model: model)
            done += 1
        }
        total = 0
        done = 0
        await ClassificationService.shared.classifyAll(urls: urls)
    }
}
