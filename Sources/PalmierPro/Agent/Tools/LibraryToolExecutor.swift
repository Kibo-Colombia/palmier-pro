import Foundation

/// The home screen's tool host. Reads the cross-project Library (`RootsRegistry`, on-disk label
/// sidecars) and mutates `SpaceRegistry`. No `EditorViewModel` — there's no open project here.
/// Spaces never touch footage; the explicit organizer tools (`move_file`/`rename_file`) are the
/// one sanctioned way to physically reorganize, and they never overwrite or delete.
@MainActor
final class LibraryToolExecutor: AgentToolHost {
    var toolSchemas: [AnthropicToolSchema] { LibraryToolDefinitions.all }
    var systemInstructions: String { LibraryAgentInstructions.serverInstructions }

    func execute(name: String, args: [String: Any]) async -> ToolResult {
        guard let tool = LibraryToolName(rawValue: name) else {
            return .error("Unknown tool: \(name)")
        }
        do {
            switch tool {
            case .listLibrary:    return listLibrary()
            case .searchLibrary:  return searchLibrary(args)
            case .getTranscript:  return try getTranscript(args)
            case .setSummary:     return try setSummary(args)
            case .listSpaces:     return listSpaces()
            case .createSpace:    return try createSpace(args)
            case .addToSpace:     return try addToSpace(args)
            case .removeFromSpace: return try removeFromSpace(args)
            case .renameSpace:    return try renameSpace(args)
            case .removeSpace:    return try removeSpace(args)
            case .listFolder:     return try listFolder(args)
            case .createFolder:   return try createFolder(args)
            case .moveFile:       return try moveFile(args)
            case .renameFile:     return try renameFile(args)
            }
        } catch let err as ToolError {
            return .error(err.message)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Library reads

    private func listLibrary() -> ToolResult {
        let roots = RootsRegistry.shared
        let indexer = LibraryIndexer.shared
        var seenCount = 0, labeledCount = 0, speechCount = 0, silentCount = 0, pendingSaidCount = 0, faceCount = 0
        let files = roots.files.map { url -> [String: Any] in
            let fileLabels = labels(for: url)
            let seen = EmbeddingStore.hasIndex(for: url)
            let transcript = TranscriptCache.cachedOnDisk(for: url)
            let said = saidStatus(transcript)

            if seen { seenCount += 1 }
            if !fileLabels.isEmpty { labeledCount += 1 }
            switch said {
            case "speech": speechCount += 1
            case "silent": silentCount += 1
            default: pendingSaidCount += 1
            }

            var dict: [String: Any] = [
                "path": url.path,
                "name": url.deletingPathExtension().lastPathComponent,
                "labels": fileLabels,
                "seen": seen,
                "said": said,
            ]
            if let transcript, !transcript.text.isEmpty {
                dict["spoken"] = String(transcript.text.prefix(280))
                if let lang = transcript.language { dict["lang"] = lang }
            }
            if let s = storedSummary(for: url) {
                dict["summary"] = s.fileSummary
                dict["summaryTier"] = s.fileTier
            }
            if let faces = faceInfo(for: url) {
                dict["faces"] = faces
                faceCount += 1
            }
            if let addr = roots.address(for: url) { dict["dragId"] = addr.dragString }
            return dict
        }
        return jsonResult([
            "roots": roots.roots.map { ["label": $0.label] },
            "fileCount": files.count,
            "files": files,
            // Corpus-level "what was understood": seen = visually indexed, labeled = ≥1 label,
            // heardSpeech/silent/saidPending = the transcription (said) layer.
            "understanding": [
                "total": files.count,
                "seen": seenCount,
                "labeled": labeledCount,
                "heardSpeech": speechCount,
                "silent": silentCount,
                "saidPending": pendingSaidCount,
                "withFaces": faceCount,
            ],
            "indexing": [
                "phase": indexer.phase.rawValue,
                "isIndexing": indexer.isIndexing,
                "done": indexer.done,
                "total": indexer.total,
            ],
        ])
    }

    private func searchLibrary(_ args: [String: Any]) -> ToolResult {
        let query = args.string("query")?.lowercased()
        let wantLabels = args.stringArray("labels").map { $0.lowercased() }
        let saidFilter = args.string("said")?.lowercased()
        let limit = args.int("limit") ?? 50
        var matches: [[String: Any]] = []
        for url in RootsRegistry.shared.files {
            let fileLabels = labels(for: url)
            let transcript = TranscriptCache.cachedOnDisk(for: url)
            let spoken = transcript?.text ?? ""
            let said = saidStatus(transcript)

            // query matches the filename OR the spoken words.
            if let query, !query.isEmpty,
               !url.lastPathComponent.lowercased().contains(query),
               !spoken.lowercased().contains(query) { continue }
            if !wantLabels.isEmpty {
                let lower = fileLabels.map { $0.lowercased() }
                let hit = wantLabels.allSatisfy { want in lower.contains { $0.contains(want) } }
                if !hit { continue }
            }
            if let saidFilter, said != saidFilter { continue }

            var dict: [String: Any] = [
                "path": url.path,
                "name": url.deletingPathExtension().lastPathComponent,
                "labels": fileLabels,
                "said": said,
            ]
            if !spoken.isEmpty {
                dict["spoken"] = String(spoken.prefix(280))
                if let lang = transcript?.language { dict["lang"] = lang }
            }
            if let s = storedSummary(for: url) {
                dict["summary"] = s.fileSummary
                dict["summaryTier"] = s.fileTier
            }
            if let faces = faceInfo(for: url) { dict["faces"] = faces }
            matches.append(dict)
            if matches.count >= limit { break }
        }
        return jsonResult(["matchCount": matches.count, "matches": matches])
    }

    /// Full transcript text per file, read passively from the on-disk cache (never transcribes).
    private func getTranscript(_ args: [String: Any]) throws -> ToolResult {
        let paths = try requirePaths(args, key: "paths")
        let transcripts = paths.map { path -> [String: Any] in
            let url = URL(fileURLWithPath: path)
            let transcript = TranscriptCache.cachedOnDisk(for: url)
            var dict: [String: Any] = ["path": path, "said": saidStatus(transcript)]
            if let transcript, !transcript.text.isEmpty {
                dict["spoken"] = transcript.text
                if let lang = transcript.language { dict["lang"] = lang }
            }
            return dict
        }
        return jsonResult(["transcripts": transcripts])
    }

    /// Persists assistant-authored summaries into the same store the (i) popover reads, marked as
    /// AI (tier 1) — so the work happens on the user's own Claude plan over MCP, not the paid
    /// in-app model. Skips (and reports) entries whose file is missing or whose text is empty.
    private func setSummary(_ args: [String: Any]) throws -> ToolResult {
        guard let items = args["summaries"] as? [[String: Any]], !items.isEmpty else {
            throw ToolError("summaries is required and must be a non-empty array of {path, summary}.")
        }
        var saved = 0
        var skipped: [[String: Any]] = []
        for item in items {
            guard let path = item.string("path") else {
                skipped.append(["path": "", "reason": "missing path"]); continue
            }
            guard let text = item.string("summary") else {
                skipped.append(["path": path, "reason": "missing summary"]); continue
            }
            let url = URL(fileURLWithPath: path)
            guard let key = EmbeddingStore.key(for: url) else {
                skipped.append(["path": path, "reason": "file not found"]); continue
            }
            if SummaryService.shared.storeExternalSummary(text, forURL: url, key: key) {
                saved += 1
            } else {
                skipped.append(["path": path, "reason": "empty after cleanup"])
            }
        }
        return jsonResult(["saved": saved, "skipped": skipped])
    }

    /// The stored summary sidecar for a file, if any (passive read — does not validate the
    /// fingerprint; the popover does that on display).
    private func storedSummary(for url: URL) -> AssetSummary? {
        guard let key = EmbeddingStore.key(for: url) else { return nil }
        return SummaryStore.load(key: key)
    }

    /// Face presence for a file from the on-disk `FaceStore` (passive). `max` is the most faces seen
    /// in a single frame (≈ people on screen). Nil when the clip has no detected faces.
    private func faceInfo(for url: URL) -> [String: Any]? {
        guard let key = EmbeddingStore.key(for: url),
              let record = FaceStore.load(key: key), record.hasFace else { return nil }
        return ["present": true, "max": record.maxFaces]
    }

    /// The "said" understanding state from the on-disk transcript: no transcript yet → pending,
    /// empty transcript (no audio / no speech) → silent, otherwise → speech.
    private func saidStatus(_ transcript: TranscriptionResult?) -> String {
        guard let transcript else { return "pending" }
        return transcript.text.isEmpty ? "silent" : "speech"
    }

    /// Top label tokens for a file, read passively from the on-disk sidecar (no model inference —
    /// shared with the Space label-filter UI via `LabelReader`). Empty until the file indexes.
    private func labels(for url: URL) -> [String] {
        LabelReader.labels(for: url)
    }

    // MARK: - Spaces

    private func listSpaces() -> ToolResult {
        let spaces = SpaceRegistry.shared.spaces.map { space -> [String: Any] in
            var dict: [String: Any] = ["id": space.id.uuidString, "name": space.name, "itemCount": space.items.count]
            if let filter = space.labelFilter, !filter.isEmpty { dict["labelFilter"] = filter }
            if let project = SpaceRegistry.shared.linkedProjectURL(for: space.id) {
                dict["linkedProject"] = project.deletingPathExtension().lastPathComponent
            }
            return dict
        }
        return jsonResult(["spaces": spaces])
    }

    private func createSpace(_ args: [String: Any]) throws -> ToolResult {
        let name = try args.requireString("name")
        let space = SpaceRegistry.shared.create(name: name)
        let filter = args.stringArray("labelFilter")
        if !filter.isEmpty { SpaceRegistry.shared.setLabelFilter(filter, for: space.id) }
        return jsonResult(["id": space.id.uuidString, "name": space.name])
    }

    private func addToSpace(_ args: [String: Any]) throws -> ToolResult {
        let space = try resolveSpace(args)
        let paths = try requirePaths(args)
        let roots = RootsRegistry.shared
        var addresses: [MomentAddress] = []
        var skipped: [String] = []
        for path in paths {
            if let addr = roots.address(for: URL(fileURLWithPath: path)) { addresses.append(addr) }
            else { skipped.append(path) }
        }
        SpaceRegistry.shared.add(addresses, to: space.id)
        return jsonResult(["added": addresses.count, "skipped": skipped])
    }

    private func removeFromSpace(_ args: [String: Any]) throws -> ToolResult {
        let space = try resolveSpace(args)
        let paths = try requirePaths(args)
        let roots = RootsRegistry.shared
        var removed = 0
        for path in paths {
            guard let addr = roots.address(for: URL(fileURLWithPath: path)) else { continue }
            SpaceRegistry.shared.removeItem(addr, from: space.id)
            removed += 1
        }
        return jsonResult(["removed": removed])
    }

    private func renameSpace(_ args: [String: Any]) throws -> ToolResult {
        let space = try resolveSpace(args)
        let name = try args.requireString("name")
        SpaceRegistry.shared.rename(space.id, to: name)
        return jsonResult(["ok": true, "id": space.id.uuidString, "name": name])
    }

    private func removeSpace(_ args: [String: Any]) throws -> ToolResult {
        let space = try resolveSpace(args)
        SpaceRegistry.shared.remove(space.id)
        return jsonResult(["ok": true])
    }

    // MARK: - Organizer (physical files — the only tools that touch the disk)

    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "mts", "m2ts", "webm"]

    private func listFolder(_ args: [String: Any]) throws -> ToolResult {
        let url = URL(fileURLWithPath: try args.requireString("path"), isDirectory: true)
        let depth = max(1, args.int("depth") ?? 1)
        guard OrganizerMove.isInScope(url) else {
            throw ToolError("Path is outside the organizer's scope (library roots or ~/Movies).")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolError("Folder not found: \(url.path)")
        }
        return jsonResult(["path": url.path, "entries": folderEntries(at: url, depth: depth)])
    }

    private func folderEntries(at url: URL, depth: Int) -> [[String: Any]] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let formatter = ISO8601DateFormatter()
        return children.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { child in
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isFolder = values?.isDirectory ?? false
            var dict: [String: Any] = [
                "name": child.lastPathComponent,
                "path": child.path,
                "kind": isFolder ? "folder" : "file",
            ]
            if let modified = values?.contentModificationDate { dict["modified"] = formatter.string(from: modified) }
            if isFolder {
                if depth > 1 { dict["entries"] = folderEntries(at: child, depth: depth - 1) }
            } else {
                dict["sizeBytes"] = values?.fileSize ?? 0
                let isVideo = Self.videoExtensions.contains(child.pathExtension.lowercased())
                dict["isVideo"] = isVideo
                if isVideo { dict["indexed"] = EmbeddingStore.hasIndex(for: child) }
            }
            return dict
        }
    }

    private func createFolder(_ args: [String: Any]) throws -> ToolResult {
        let url = URL(fileURLWithPath: try args.requireString("path"), isDirectory: true)
        guard OrganizerMove.isInScope(url) else {
            throw ToolError("Path is outside the organizer's scope (library roots or ~/Movies).")
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return jsonResult(["ok": true, "path": url.path])
    }

    private func moveFile(_ args: [String: Any]) throws -> ToolResult {
        guard let moves = args["moves"] as? [[String: Any]], !moves.isEmpty else {
            throw ToolError("moves is required and must be a non-empty array of {source, destination}.")
        }
        let dryRun = (args["dryRun"] as? Bool) ?? false
        var results: [[String: Any]] = []
        var moved = 0
        for entry in moves {
            guard let source = entry.string("source"), let destination = entry.string("destination") else {
                results.append(["ok": false, "reason": "entry needs both source and destination"])
                continue
            }
            let sourceURL = URL(fileURLWithPath: source)
            let destinationURL = URL(fileURLWithPath: destination)
            if let reason = OrganizerMove.validate(source: sourceURL, destination: destinationURL) {
                results.append(["source": source, "destination": destination, "ok": false, "reason": reason])
                continue
            }
            if dryRun {
                results.append(["source": source, "destination": destination, "ok": true, "dryRun": true])
                continue
            }
            do {
                try OrganizerMove.move(source: sourceURL, destination: destinationURL)
                moved += 1
                results.append(["source": source, "destination": destination, "ok": true])
            } catch let failure as OrganizerMove.Failure {
                results.append(["source": source, "destination": destination, "ok": false, "reason": failure.reason])
            } catch {
                results.append(["source": source, "destination": destination, "ok": false, "reason": error.localizedDescription])
            }
        }
        if moved > 0 { Task { await RootsRegistry.shared.rescan() } }
        return jsonResult(["dryRun": dryRun, "moved": moved, "results": results])
    }

    private func renameFile(_ args: [String: Any]) throws -> ToolResult {
        let path = try args.requireString("path")
        let newName = try args.requireString("newName")
        guard !newName.contains("/") else { throw ToolError("newName must be a filename, not a path.") }
        let source = URL(fileURLWithPath: path)
        let destination = source.deletingLastPathComponent().appendingPathComponent(newName)
        if let reason = OrganizerMove.validate(source: source, destination: destination) {
            throw ToolError(reason)
        }
        try OrganizerMove.move(source: source, destination: destination)
        Task { await RootsRegistry.shared.rescan() }
        return jsonResult(["ok": true, "path": destination.path])
    }

    // MARK: - Helpers

    private func resolveSpace(_ args: [String: Any]) throws -> Space {
        let raw = try args.requireString("spaceId")
        guard let id = UUID(uuidString: raw), let space = SpaceRegistry.shared.space(id) else {
            throw ToolError("spaceId not found: \(raw). Call list_spaces for valid ids, or create_space first.")
        }
        return space
    }

    private func requirePaths(_ args: [String: Any], key: String = "filePaths") throws -> [String] {
        let paths = args.stringArray(key)
        guard !paths.isEmpty else { throw ToolError("\(key) is required and must be a non-empty array.") }
        return paths
    }

    private func jsonResult(_ obj: Any) -> ToolResult {
        guard let s = ToolExecutor.jsonString(obj) else { return .error("Failed to serialize result.") }
        return .ok(s)
    }
}
