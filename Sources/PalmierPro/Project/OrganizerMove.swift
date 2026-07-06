import Foundation

/// Physical file organization (M-E, "The Organizer"): the one code path that moves or
/// renames anything on disk. Content-based identity (`AssetIdentity`) makes a move free —
/// all sidecars key off the bytes — and Space addresses are repaired in the same breath,
/// so a move is never observable as loss. Guard rails over power: never overwrites, never
/// deletes, and only operates inside the organizer's scope (a registered root or
/// `~/Movies`).
@MainActor
enum OrganizerMove {
    struct Failure: Error { let reason: String }

    /// Scope rail: both ends of every move must live under a registered library root or
    /// the user's Movies folder. Everything else on disk is out of bounds by design.
    static func isInScope(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let movies = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies", isDirectory: true).standardizedFileURL.path
        if path == movies || path.hasPrefix(movies + "/") { return true }
        for root in RootsRegistry.shared.roots {
            guard let resolved = Bookmarks.resolve(root.bookmark) else { continue }
            let base = resolved.url.standardizedFileURL.path
            if path.hasPrefix(base + "/") || path == base { return true }
        }
        return false
    }

    /// Validate without touching the disk — the `dryRun` result.
    static func validate(source: URL, destination: URL) -> String? {
        let fm = FileManager.default
        guard isInScope(source) else { return "source is outside the organizer's scope (library roots or ~/Movies)" }
        guard isInScope(destination) else { return "destination is outside the organizer's scope (library roots or ~/Movies)" }
        guard fm.fileExists(atPath: source.path) else { return "source does not exist" }
        guard !fm.fileExists(atPath: destination.path) else { return "destination already exists — moves never overwrite" }
        return nil
    }

    /// Move `source` → `destination` (parent folders created as needed), then keep every
    /// layer consistent: the identity map learns the new location without re-reading the
    /// file, and any Space moment addressing the old path is rewritten in place.
    static func move(source: URL, destination: URL) throws {
        if let reason = validate(source: source, destination: destination) {
            throw Failure(reason: reason)
        }
        let roots = RootsRegistry.shared
        let oldAddress = roots.address(for: source)

        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: source, to: destination)

        AssetIdentity.shared.noteMoved(from: source, to: destination)
        if let oldAddress, let newAddress = roots.address(for: destination) {
            SpaceRegistry.shared.repairAddress(oldAddress, to: newAddress)
        }
    }
}
