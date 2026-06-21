import AVFoundation
import Foundation

/// Indexes the Library's footage (M2c) — the roots that aren't part of an open project, so the
/// per-project `SearchIndexCoordinator` never sees them. Two passes, both idempotent and resumable:
///   • **seeing** — `VisualIndexer` embeddings + `ClassificationService` labels (the "seen" layer),
///     so library cards get the same hover-scrub key moments and label chips as project media.
///   • **hearing** — on-device, per-clip auto-language transcription (the "said" layer) via
///     `TranscriptCache.libraryTranscript`. Free (Apple `SpeechTranscriber`); silent / no-audio
///     clips are persisted as empty so they aren't reprocessed.
@Observable
@MainActor
final class LibraryIndexer {
    static let shared = LibraryIndexer()

    enum Phase: String, Sendable { case idle, seeing, hearing }

    private(set) var phase: Phase = .idle
    private(set) var done = 0
    private(set) var total = 0
    var isIndexing: Bool { phase != .idle }

    /// Candidate spoken languages for the auto-detect transcription pass. Order is irrelevant —
    /// each clip is scored independently and the best-fitting language wins. Defaults to the
    /// creator's mix (Spanish + English); a single entry skips detection and forces that locale.
    var transcriptionLocales: [Locale] = [
        Locale(identifier: "es-419"),
        Locale(identifier: "en-US"),
    ]

    private var task: Task<Void, Never>?

    /// Index + transcribe any not-yet-processed videos among `urls`. Idempotent — a second call
    /// while running is ignored; already-processed files are skipped cheaply via on-disk sidecars.
    func ensureIndexed(_ urls: [URL]) {
        guard task == nil, !urls.isEmpty else { return }
        task = Task { [weak self] in
            await self?.run(urls)
            self?.task = nil
        }
    }

    private func run(_ urls: [URL]) async {
        await seeing(urls)
        await hearing(urls)
        phase = .idle
        total = 0
        done = 0
    }

    /// Visual embeddings + labels. Needs the SigLIP model; waits briefly for it to load.
    private func seeing(_ urls: [URL]) async {
        for _ in 0..<40 where !VisualModelLoader.shared.isReady {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
        }
        guard let model = VisualModelLoader.shared.embedder, VisualModelLoader.shared.isReady else { return }

        let pending = urls.filter { VisualIndexer.needsIndex(url: $0, spec: model.spec) }
        if !pending.isEmpty {
            phase = .seeing
            total = pending.count
            done = 0
            for url in pending {
                if Task.isCancelled { break }
                let duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
                try? await VisualIndexer.index(url: url, duration: duration, model: model)
                done += 1
            }
        }
        await ClassificationService.shared.classifyAll(urls: urls)
    }

    /// On-device transcription of any clip without a cached transcript. Sequential and low-key so it
    /// doesn't peg the machine; each clip persists (incl. silent) so the pass resumes where it left off.
    private func hearing(_ urls: [URL]) async {
        let pending = urls.filter { !TranscriptCache.hasCachedOnDisk(for: $0) }
        guard !pending.isEmpty else { return }
        phase = .hearing
        total = pending.count
        done = 0
        for url in pending {
            if Task.isCancelled { break }
            _ = await TranscriptCache.shared.libraryTranscript(for: url, candidates: transcriptionLocales)
            done += 1
        }
    }
}
