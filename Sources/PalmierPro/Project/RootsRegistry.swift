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

    private let fileURL = Project.storageDirectory.appendingPathComponent(Project.rootsRegistryFilename)

    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "mts", "m2ts", "webm"]

    private init() {
        load()
        Task { await rescan() }
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

    // MARK: - Scan

    /// Re-enumerate every root for video files. Off-main; publishes `files` on completion.
    func rescan() async {
        let roots = self.roots
        let exts = Self.videoExtensions
        let found: [URL] = await Task.detached(priority: .utility) {
            var out: [URL] = []
            for root in roots {
                guard let resolved = Bookmarks.resolve(root.bookmark) else { continue }
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
            return out.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }.value
        self.files = found
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
