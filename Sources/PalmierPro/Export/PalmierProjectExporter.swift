import Foundation

/// Writes a self-contained `.palmier` package: every resolvable media reference is copied
/// into the new bundle's `media/` directory and rewritten to a project-relative source
enum PalmierProjectExporter {

    struct Report: Codable, Equatable, Sendable {
        /// Entry ids that were `.external` and are now bundled.
        var collected: [String] = []
        /// Already-internal media files copied across.
        var copiedInternal: Int = 0
        /// Entries whose source file couldn't be found, so they couldn't be included.
        var missing: [Missing] = []
        /// Total bytes copied into the new bundle.
        var totalBytes: Int64 = 0

        struct Missing: Codable, Equatable, Sendable { var id: String; var name: String }
    }

    @discardableResult
    static func export(
        timeline: Timeline,
        manifest: MediaManifest,
        generationLog: GenerationLog,
        sourceProjectURL: URL?,
        to destURL: URL,
        overwrite: Bool = true,
        strictMissingMedia: Bool = false,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> Report {
        let fm = FileManager.default
        if !overwrite && fm.fileExists(atPath: destURL.path) {
            throw ToolError("Destination already exists: \(destURL.path). Set overwrite=true to replace it.")
        }
        let missing = missingMedia(in: manifest, projectURL: sourceProjectURL)
        if strictMissingMedia && !missing.isEmpty {
            throw ToolError("Missing media: \(missing.map(\.id).joined(separator: ", ")). Package was not written.")
        }
        try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destURL.deletingLastPathComponent()
            .appendingPathComponent(".palmier-export-\(UUID().uuidString)", isDirectory: true)
        let mediaDir = staging.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var report = Report()
        var newEntries: [MediaManifestEntry] = []
        var relativePathBySource: [String: String] = [:]   // dedup: absolute source path -> media/<file>
        let total = max(1, manifest.entries.count)

        for (index, entry) in manifest.entries.enumerated() {
            defer { progress?(Double(index + 1) / Double(total)) }

            guard let srcURL = sourceURL(for: entry.source, projectURL: sourceProjectURL),
                  fm.fileExists(atPath: srcURL.path) else {
                report.missing.append(.init(id: entry.id, name: entry.name))
                newEntries.append(entry)                    // keep the (dangling) reference as-is
                continue
            }

            let key = srcURL.standardizedFileURL.path
            let relativePath: String
            if let existing = relativePathBySource[key] {
                relativePath = existing
            } else {
                let dest = uniqueURL(in: mediaDir, preferredName: filename(for: entry, sourceURL: srcURL), fm: fm)
                try fm.copyItem(at: srcURL, to: dest)
                relativePath = "\(Project.mediaDirectoryName)/\(dest.lastPathComponent)"
                relativePathBySource[key] = relativePath
                report.totalBytes += fileSize(dest, fm: fm)
                if case .project = entry.source { report.copiedInternal += 1 }
            }

            if case .external = entry.source { report.collected.append(entry.id) }
            var rewritten = entry
            rewritten.source = .project(relativePath: relativePath)
            newEntries.append(rewritten)
        }

        var newManifest = manifest
        newManifest.entries = newEntries
        if strictMissingMedia && !report.missing.isEmpty {
            throw ToolError("Media disappeared during packaging: \(report.missing.map(\.id).joined(separator: ", ")).")
        }

        let encoder = JSONEncoder()
        try encoder.encode(timeline).write(to: staging.appendingPathComponent(Project.timelineFilename))
        try encoder.encode(newManifest).write(to: staging.appendingPathComponent(Project.manifestFilename))
        try encoder.encode(generationLog).write(to: staging.appendingPathComponent(Project.generationLogFilename))

        // Carry across non-media bundle contents (thumbnail, chat history) when present.
        if let sourceProjectURL {
            copyIfPresent(Project.thumbnailFilename, from: sourceProjectURL, to: staging, fm: fm)
            copyIfPresent(ChatSessionStore.dirName, from: sourceProjectURL, to: staging, fm: fm)
        }

        try ProjectAutomationFiles.commit(staging: staging, to: destURL, overwrite: overwrite)
        return report
    }

    // MARK: - Helpers

    static func missingMedia(in manifest: MediaManifest, projectURL: URL?) -> [Report.Missing] {
        manifest.entries.compactMap { entry in
            guard let url = sourceURL(for: entry.source, projectURL: projectURL),
                  FileManager.default.fileExists(atPath: url.path) else {
                return Report.Missing(id: entry.id, name: entry.name)
            }
            return nil
        }
    }

    private static func sourceURL(for source: MediaSource, projectURL: URL?) -> URL? {
        switch source {
        case .external(let path): return URL(fileURLWithPath: path)
        case .project(let rel):
            guard let projectURL, !rel.hasPrefix("/") else { return nil }
            let base = projectURL.standardizedFileURL.resolvingSymlinksInPath()
            let url = base.appendingPathComponent(rel).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(base.path + "/") else { return nil }
            return url
        }
    }

    private static func filename(for entry: MediaManifestEntry, sourceURL: URL) -> String {
        switch entry.source {
        case .project:
            return sourceURL.lastPathComponent                 // preserve existing internal name
        case .external:
            let ext = sourceURL.pathExtension
            let base = "import-\(entry.id.prefix(8))"
            return ext.isEmpty ? base : "\(base).\(ext)"
        }
    }

    /// Appends `-1`, `-2`, … to avoid clobbering an already-written file of the same name.
    private static func uniqueURL(in dir: URL, preferredName: String, fm: FileManager) -> URL {
        let candidate = dir.appendingPathComponent(preferredName)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ns = preferredName as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var n = 1
        while true {
            let name = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            let url = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    private static func copyIfPresent(_ name: String, from source: URL, to staging: URL, fm: FileManager) {
        let src = source.appendingPathComponent(name)
        guard fm.fileExists(atPath: src.path) else { return }
        try? fm.copyItem(at: src, to: staging.appendingPathComponent(name))
    }

    private static func fileSize(_ url: URL, fm: FileManager) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
