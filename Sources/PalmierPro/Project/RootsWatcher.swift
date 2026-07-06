import CoreServices
import Foundation

/// Live filesystem watching over the Library roots (M-C, "The Organizer"): one FSEvents
/// stream across every resolved root, so new footage dropped into `~/Movies/videos` (or
/// any root) is discovered and understood without the Library tab ever being opened.
/// Renames/moves fire the same path — the rescan is cheap and `AssetIdentity` makes a
/// moved file's re-discovery free (no re-index).
@MainActor
final class RootsWatcher {
    static let shared = RootsWatcher()

    private var stream: FSEventStreamRef?
    private var watchedPaths: [String] = []
    private var rescanTask: Task<Void, Never>?
    private var eventsWhileRescanning = false

    private init() {}

    /// Call once at launch. Kicks the first rescan+index cycle (which also builds the
    /// event stream over the current roots) — this is what makes indexing always-on
    /// instead of Library-tab-gated.
    func start() {
        scheduleRescan()
    }

    /// FSEvents batches changes for us (3 s latency), so one event burst = one rescan.
    /// Bursts that land mid-rescan coalesce into exactly one follow-up pass.
    private func scheduleRescan() {
        guard rescanTask == nil else {
            eventsWhileRescanning = true
            return
        }
        rescanTask = Task { [weak self] in
            await RootsRegistry.shared.rescan()
            guard let self else { return }
            self.syncStream()
            LibraryIndexer.shared.ensureIndexed(RootsRegistry.shared.files, trigger: .automatic)
            self.rescanTask = nil
            if self.eventsWhileRescanning {
                self.eventsWhileRescanning = false
                self.scheduleRescan()
            }
        }
    }

    /// (Re)build the stream when the set of resolved root folders changes — a root was
    /// added, removed, re-linked, or an external drive (un)mounted.
    private func syncStream() {
        let paths = RootsRegistry.shared.roots
            .compactMap { Bookmarks.resolve($0.bookmark)?.url.standardizedFileURL.path }
            .filter { FileManager.default.fileExists(atPath: $0) }
            .sorted()
        guard paths != watchedPaths else { return }
        stop()
        watchedPaths = paths
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<RootsWatcher>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in watcher.scheduleRescan() }
        }
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            3.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else {
            Log.search.warning("FSEvents stream creation failed for \(paths.count) roots")
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
        Log.search.notice("watching \(paths.count) roots for changes")
    }

    private func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
