import Foundation

/// Materializes a Space onto disk on demand (M3 Step 4, "The Organizer"). `pointer` is the default
/// and needs nothing — the registry JSON *is* the materialization. These are the explicit
/// escalations the user asks for:
/// - `symlink`: deduped whole-file shortcuts into a chosen folder (Finder-visible; the moment
///   range stays in-app metadata, since a symlink can't represent a frame range).
/// - `copy`: deduped whole-file copies (isolation). A re-encoded sub-clip per range is a future
///   refinement — for now copy duplicates the whole source file.
///
/// Re-materializing replaces the Space's output folder wholesale (it's a disposable mirror of the
/// Space, fully reproducible), so the result is idempotent.
@MainActor
enum SpaceMaterializer {
    enum Mode: Sendable { case symlink, copy }
    struct Result: Sendable { let directory: URL; let written: Int; let skipped: Int }

    static func materialize(_ space: Space, mode: Mode, into destination: URL) async throws -> Result {
        let files = uniqueFiles(in: space)
        let dirName = folderName(space)
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let dir = destination.appendingPathComponent(dirName, isDirectory: true)
            if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var written = 0, skipped = 0
            for file in files {
                let dest = uniqueDestination(for: file, in: dir, fm: fm)
                do {
                    switch mode {
                    case .symlink: try fm.createSymbolicLink(at: dest, withDestinationURL: file)
                    case .copy:    try fm.copyItem(at: file, to: dest)
                    }
                    written += 1
                } catch {
                    skipped += 1
                }
            }
            return Result(directory: dir, written: written, skipped: skipped)
        }.value
    }

    /// Distinct source files referenced by the Space, in first-seen order — a symlink/copy is
    /// whole-file, so several moments from one clip dedup to a single output.
    private static func uniqueFiles(in space: Space) -> [URL] {
        let fm = FileManager.default
        var seen = Set<String>()
        var files: [URL] = []
        for address in space.items {
            guard let url = RootsRegistry.shared.fileURL(for: address),
                  fm.fileExists(atPath: url.path),
                  seen.insert(url.standardizedFileURL.path).inserted else { continue }
            files.append(url)
        }
        return files
    }

    private static func folderName(_ space: Space) -> String {
        let trimmed = space.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = trimmed.isEmpty ? "Space" : trimmed
        return safe.replacingOccurrences(of: "/", with: "-")
    }

    /// Avoid collisions when two distinct sources share a filename within one output folder.
    private nonisolated static func uniqueDestination(for file: URL, in dir: URL, fm: FileManager) -> URL {
        var candidate = dir.appendingPathComponent(file.lastPathComponent)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        var n = 2
        repeat {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = dir.appendingPathComponent(name)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}
