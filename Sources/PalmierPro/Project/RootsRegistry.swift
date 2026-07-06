import Foundation

/// A user-granted footage folder (M2c). The library is built from these roots — Koma reads them
/// in place; raw bytes never move. No whole-Mac scan: the user adds folders explicitly.
struct Root: Codable, Identifiable, Sendable {
    let id: UUID
    var label: String
    var bookmark: Data
}

@Observable
@MainActor
final class RootsRegistry {
    static let shared = RootsRegistry()

    private(set) var roots: [Root] = []
    /// Video files discovered across all roots (the Library's contents). Observable.
    private(set) var files: [URL] = []
    /// Roots whose bookmark no longer resolves to an existing folder (drive unplugged, folder
    /// moved or deleted). Recomputed on every rescan; drives the re-link affordance in the Library.
    private(set) var brokenRootIDs: Set<UUID> = []

    private let fileURL = Project.storageDirectory.appendingPathComponent(Project.rootsRegistryFilename)

    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "mts", "m2ts", "webm"]

    private init() {
        load()
        ensureDefaultRoot()
        Task { await rescan() }
    }

    /// The permanent internal library root. Ensured on every launch: `~/Movies/videos`
    /// is where footage lives to be understood — the user drops files there in Finder
    /// and they simply become part of the Library.
    private func ensureDefaultRoot() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/videos", isDirectory: true)
        let path = url.standardizedFileURL.path
        let existing = roots.compactMap { Bookmarks.resolve($0.bookmark)?.url.standardizedFileURL.path }
        guard !existing.contains(path) else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let bookmark = Bookmarks.create(for: url) else { return }
        roots.insert(Root(id: UUID(), label: url.lastPathComponent, bookmark: bookmark), at: 0)
        save()
    }

    // MARK: - Mutations

    func addFolder(_ url: URL) {
        let resolvedPaths = roots.compactMap { Bookmarks.resolve($0.bookmark)?.url.standardizedFileURL.path }
        guard !resolvedPaths.contains(url.standardizedFileURL.path),
              let bookmark = Bookmarks.create(for: url) else { return }
        roots.append(Root(id: UUID(), label: url.lastPathComponent, bookmark: bookmark))
        save()
        Task { await rescan() }
    }

    func remove(_ id: UUID) {
        roots.removeAll { $0.id == id }
        save()
        Task { await rescan() }
    }

    /// Point an existing root at a new folder (footage moved to another disk or path). The label
    /// is preserved — it's the stable half of every MomentAddress — so Spaces resolve again as
    /// long as the relative structure inside the folder is unchanged.
    func relink(_ id: UUID, to url: URL) {
        guard let idx = roots.firstIndex(where: { $0.id == id }),
              let bookmark = Bookmarks.create(for: url) else { return }
        roots[idx].bookmark = bookmark
        save()
        Task { await rescan() }
    }

    // MARK: - Scan

    /// Re-enumerate every root for video files. Off-main; publishes `files` on completion.
    func rescan() async {
        let roots = self.roots
        let exts = Self.videoExtensions
        let result: (files: [URL], broken: Set<UUID>, refreshed: [UUID: Data]) = await Task.detached(priority: .utility) {
            var out: [URL] = []
            var broken: Set<UUID> = []
            var refreshed: [UUID: Data] = [:]
            for root in roots {
                var isDirectory: ObjCBool = false
                guard let resolved = Bookmarks.resolve(root.bookmark),
                      FileManager.default.fileExists(atPath: resolved.url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    broken.insert(root.id)
                    continue
                }
                // A stale bookmark still resolves this launch but may not next time (e.g. the
                // folder was moved) — re-mint it against the current location while we can.
                if resolved.isStale, let fresh = Bookmarks.create(for: resolved.url) {
                    refreshed[root.id] = fresh
                }
                // Claim access for later reads (indexing, playback). No-op while unsandboxed;
                // intentionally not released for the app's lifetime. TODO: scope per use if sandboxed.
                _ = resolved.url.startAccessingSecurityScopedResource()
                guard let enumerator = FileManager.default.enumerator(
                    at: resolved.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ) else { continue }
                for case let file as URL in enumerator.allObjects where exts.contains(file.pathExtension.lowercased()) {
                    out.append(file)
                }
            }
            // One-time: re-key legacy path-keyed sidecars to content keys while every
            // file still sits at the path its old key was derived from.
            if !SidecarMigrator.isDone { SidecarMigrator.migrate(files: out) }
            return (out.sorted { $0.lastPathComponent < $1.lastPathComponent }, broken, refreshed)
        }.value
        for (id, bookmark) in result.refreshed {
            if let idx = self.roots.firstIndex(where: { $0.id == id }) { self.roots[idx].bookmark = bookmark }
        }
        if !result.refreshed.isEmpty { save() }
        brokenRootIDs = result.broken
        self.files = result.files
        reverseKeyCache = nil
        SpaceRegistry.shared.stampMissingContentKeys(using: self)
    }

    // MARK: - Portable addressing (M3)

    /// Lazy `contentKey → URL` over the current `files` — the recovery index for moments
    /// whose stored relativePath no longer exists (in-root rename/move). Invalidated on
    /// every rescan; built only when a moment actually fails to resolve.
    private var reverseKeyCache: [String: URL]?

    private func reverseKeyMap() -> [String: URL] {
        if let reverseKeyCache { return reverseKeyCache }
        var map: [String: URL] = [:]
        for file in files {
            if let key = AssetIdentity.key(for: file) { map[key] = file }
        }
        reverseKeyCache = map
        return map
    }

    /// Resolve a portable moment address to a concrete file URL via its root's bookmark.
    /// Claims security-scoped access (a no-op while unsandboxed) so the file is readable.
    /// When the stored relativePath is gone but the address carries a contentKey, the file
    /// is re-found by content identity and the Space's address self-heals for next time.
    func fileURL(for address: MomentAddress) -> URL? {
        if let root = roots.first(where: { $0.label == address.rootLabel }),
           let resolved = Bookmarks.resolve(root.bookmark) {
            _ = resolved.url.startAccessingSecurityScopedResource()
            let url = resolved.url.appendingPathComponent(address.relativePath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        guard let contentKey = address.contentKey,
              let healed = reverseKeyMap()[contentKey],
              var repaired = self.address(for: healed) else { return nil }
        repaired.shotStart = address.shotStart
        repaired.shotEnd = address.shotEnd
        let old = address
        Task { @MainActor in SpaceRegistry.shared.repairAddress(old, to: repaired) }
        return healed
    }

    /// Build a portable address for a Library file URL, choosing the root that contains it.
    /// Returns nil for files outside every registered root.
    func address(for fileURL: URL, shotStart: Double? = nil, shotEnd: Double? = nil) -> MomentAddress? {
        let target = fileURL.standardizedFileURL.path
        for root in roots {
            guard let resolved = Bookmarks.resolve(root.bookmark) else { continue }
            let base = resolved.url.standardizedFileURL.path
            let prefix = base.hasSuffix("/") ? base : base + "/"
            guard target.hasPrefix(prefix) else { continue }
            return MomentAddress(
                rootLabel: root.label,
                relativePath: String(target.dropFirst(prefix.count)),
                shotStart: shotStart,
                shotEnd: shotEnd,
                contentKey: AssetIdentity.key(for: fileURL)
            )
        }
        return nil
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Root].self, from: data) else { return }
        roots = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(roots) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
