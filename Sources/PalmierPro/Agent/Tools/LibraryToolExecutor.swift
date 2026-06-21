import Foundation

/// The home screen's tool host. Reads the cross-project Library (`RootsRegistry`, on-disk label
/// sidecars) and mutates `SpaceRegistry`. No `EditorViewModel` — there's no open project here.
/// Footage is never moved, copied, or deleted; only Spaces (groupings) and their membership change.
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
            case .listSpaces:     return listSpaces()
            case .createSpace:    return try createSpace(args)
            case .addToSpace:     return try addToSpace(args)
            case .removeFromSpace: return try removeFromSpace(args)
            case .renameSpace:    return try renameSpace(args)
            case .removeSpace:    return try removeSpace(args)
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
        var seenCount = 0, labeledCount = 0, speechCount = 0, silentCount = 0, pendingSaidCount = 0
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
            matches.append(dict)
            if matches.count >= limit { break }
        }
        return jsonResult(["matchCount": matches.count, "matches": matches])
    }

    /// The "said" understanding state from the on-disk transcript: no transcript yet → pending,
    /// empty transcript (no audio / no speech) → silent, otherwise → speech.
    private func saidStatus(_ transcript: TranscriptionResult?) -> String {
        guard let transcript else { return "pending" }
        return transcript.text.isEmpty ? "silent" : "speech"
    }

    /// Top label tokens for a file, read passively from the on-disk sidecar (no model inference —
    /// mirrors how `SummaryService` reads labels on the home screen). Empty until the file indexes.
    private func labels(for url: URL) -> [String] {
        guard let key = EmbeddingStore.key(for: url),
              let file = LabelStore.load(key: key)?.file else { return [] }
        return file
            .sorted { ($0.coverage * Double($0.peak)) > ($1.coverage * Double($1.peak)) }
            .prefix(6)
            .map(\.token)
    }

    // MARK: - Spaces

    private func listSpaces() -> ToolResult {
        let spaces = SpaceRegistry.shared.spaces.map { space -> [String: Any] in
            ["id": space.id.uuidString, "name": space.name, "itemCount": space.items.count]
        }
        return jsonResult(["spaces": spaces])
    }

    private func createSpace(_ args: [String: Any]) throws -> ToolResult {
        let name = try args.requireString("name")
        let space = SpaceRegistry.shared.create(name: name)
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

    // MARK: - Helpers

    private func resolveSpace(_ args: [String: Any]) throws -> Space {
        let raw = try args.requireString("spaceId")
        guard let id = UUID(uuidString: raw), let space = SpaceRegistry.shared.space(id) else {
            throw ToolError("spaceId not found: \(raw). Call list_spaces for valid ids, or create_space first.")
        }
        return space
    }

    private func requirePaths(_ args: [String: Any]) throws -> [String] {
        let paths = args.stringArray("filePaths")
        guard !paths.isEmpty else { throw ToolError("filePaths is required and must be a non-empty array.") }
        return paths
    }

    private func jsonResult(_ obj: Any) -> ToolResult {
        guard let s = ToolExecutor.jsonString(obj) else { return .error("Failed to serialize result.") }
        return .ok(s)
    }
}
