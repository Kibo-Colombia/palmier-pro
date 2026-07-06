import CryptoKit
import Foundation

/// One-time re-key of every sidecar store from the legacy path-derived keys
/// (`SHA256(path|mtime|size)`) to content-based `AssetIdentity` keys, so already-indexed
/// footage — including paid Tier-1 summaries — survives the switch without re-indexing.
///
/// Runs inside `RootsRegistry.rescan()`'s enumeration (the one place that sees every
/// library file with access claimed), before the indexer gets the file list. Rename-only
/// and skip-if-done at every level, so it is idempotent, resumable after a crash, and
/// reversible from the pre-migration backup. Sidecars whose file no longer exists at its
/// old path are left orphaned in place — garbage collection is deliberately not this
/// code's job.
enum SidecarMigrator {
    private static let markerURL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(Log.subsystem)/identity-v2.done")

    static var isDone: Bool {
        FileManager.default.fileExists(atPath: markerURL.path)
    }

    /// Every store filed under `EmbeddingStore.key` and its per-store filename suffixes.
    private static var stores: [(directory: URL, suffixes: [String])] {
        let cacheRoot = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Log.subsystem, isDirectory: true)
        return [
            (cacheRoot.appendingPathComponent("Embeddings"), [".embed"]),
            (cacheRoot.appendingPathComponent("Labels"), [".labels.json"]),
            (cacheRoot.appendingPathComponent("HeardLabels"), [".heard.json"]),
            (cacheRoot.appendingPathComponent("Summaries"), [".summary.json"]),
            (cacheRoot.appendingPathComponent("Faces"), [".faces.json"]),
            (cacheRoot.appendingPathComponent("Transcripts"), [".json"]),
            (DiskCache.rootDirectory.appendingPathComponent("KeyframeThumbnails"),
             [".keyframes.json", ".keyframes.jpg"]),
        ]
    }

    /// Re-key sidecars for every current library file. `files` is the freshly-enumerated
    /// root contents, so each still sits at the path its legacy key was derived from.
    static func migrate(files: [URL]) {
        guard !isDone else { return }
        let fm = FileManager.default
        var renamed = 0
        for file in files {
            guard let legacy = legacyKey(for: file),
                  let content = AssetIdentity.key(for: file),
                  legacy != content else { continue }
            for store in stores {
                for suffix in store.suffixes {
                    let old = store.directory.appendingPathComponent(legacy + suffix)
                    let new = store.directory.appendingPathComponent(content + suffix)
                    guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { continue }
                    do {
                        try fm.moveItem(at: old, to: new)
                        renamed += 1
                    } catch {
                        Log.search.warning("sidecar re-key failed \(old.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
        }
        Log.search.notice("identity-v2 migration: re-keyed \(renamed) sidecars across \(files.count) files")
        try? fm.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: markerURL.path, contents: Data())
    }

    /// The pre-v2 key formula, kept verbatim so existing sidecars can be located.
    private static func legacyKey(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        let identity = "\(url.path)|\(mtime.timeIntervalSince1970)|\(size)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }
}
