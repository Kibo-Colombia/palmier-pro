import Foundation

// MARK: apply_look / list_looks / import_look — one-tap color "looks" (LUTs)

fileprivate struct ApplyLookInput: DecodableToolArgs {
    let clipIds: [String]
    let look: String?
    let intensity: Double?
    let reset: Bool?
    static let allowedKeys: Set<String> = ["clipIds", "look", "intensity", "reset"]
}

fileprivate struct ImportLookInput: DecodableToolArgs {
    let path: String
    let name: String?
    static let allowedKeys: Set<String> = ["path", "name"]
}

extension ToolExecutor {
    func applyLook(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: ApplyLookInput = try decodeToolArgs(args, path: "apply_look")
        guard !input.clipIds.isEmpty else { throw ToolError("Missing or empty 'clipIds' array") }
        let resolve: (String) -> URL? = { editor.mediaResolver.resolveURL(for: $0) }

        if input.reset != true {
            guard let look = input.look, !look.isEmpty else {
                throw ToolError("apply_look needs a 'look' id (or reset:true). Call list_looks for options.")
            }
            guard LUTStore.shared.exists(look, resolveURL: resolve) else {
                throw ToolError("Unknown look '\(look)'. Call list_looks for available looks.")
            }
        }

        // A look is a visual property — resolve clips up front and reject audio.
        for id in input.clipIds {
            guard let loc = editor.findClip(id: id) else { throw ToolError("Clip not found: \(id)") }
            if editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].mediaType == .audio {
                throw ToolError("Cannot apply a look to an audio clip: \(id)")
            }
        }

        let n = input.clipIds.count
        let actionName = n == 1 ? "Apply Look (Agent)" : "Apply Look to \(n) Clips (Agent)"
        let summaries: [String] = withUndoGroup(editor, actionName: actionName) {
            input.clipIds.map { id in
                editor.commitClipProperty(clipId: id) { clip in
                    if input.reset == true {
                        clip.grade.lut = nil
                    } else {
                        clip.grade.lut = input.look
                        if let i = input.intensity { clip.grade.lookIntensity = min(1, max(0, i)) }
                    }
                }
                if input.reset == true { return "\(id): look cleared" }
                let pct = input.intensity.map { " @ \(Int(min(1, max(0, $0)) * 100))%" } ?? ""
                return "\(id): \(input.look ?? "")\(pct)"
            }
        }
        let verb = input.reset == true ? "Cleared look on" : "Applied look to"
        return .ok("\(verb) \(n) clip\(n == 1 ? "" : "s"): \(summaries.joined(separator: "; "))")
    }

    func listLooks(_ editor: EditorViewModel) -> ToolResult {
        let bundled = LUTStore.shared.bundledLooks.map { ["id": $0.id, "name": $0.name, "description": $0.detail] }
        let imported = LUTStore.shared.importedLooks.map { ["id": $0.id, "name": $0.name] }
        let json = ToolExecutor.jsonString(["bundled": bundled, "imported": imported])
        return .ok(json ?? #"{"bundled":[],"imported":[]}"#)
    }

    func importLook(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: ImportLookInput = try decodeToolArgs(args, path: "import_look")
        let url = URL(fileURLWithPath: input.path)
        guard url.pathExtension.lowercased() == "cube" else { throw ToolError("Not a .cube file: \(input.path)") }
        guard let data = try? Data(contentsOf: url) else { throw ToolError("Could not read file: \(input.path)") }
        let name = input.name ?? url.deletingPathExtension().lastPathComponent
        guard let look = try? LUTStore.shared.importLook(suggestedName: name, data: data) else {
            throw ToolError("Not a valid 3D .cube LUT: \(input.path)")
        }
        return .ok("Imported look '\(look.name)' (id: \(look.id)). Apply it with apply_look.")
    }
}
