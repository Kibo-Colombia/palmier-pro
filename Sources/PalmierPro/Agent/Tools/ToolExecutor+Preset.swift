import Foundation

extension ToolExecutor {
    private static let listPresetsAllowedKeys: Set<String> = ["category"]
    private static let applyPresetAllowedKeys: Set<String> = ["clipIds", "preset"]

    /// Enumerate the curated preset library — the catalog the recipe snaps to and the user browses.
    func listPresets(_ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.listPresetsAllowedKeys, path: "list_presets")
        var items = PresetLibrary.catalog
        if let cat = args.string("category") {
            guard let category = PresetCategory(rawValue: cat) else {
                throw ToolError("Unknown category '\(cat)'. Valid: transition, caption-animation, effect.")
            }
            items = items.filter { $0.category == category }
        }
        let arr: [[String: Any]] = items.map {
            [
                "preset": $0.kind.rawValue,
                "category": $0.category.rawValue,
                "name": $0.name,
                "summary": $0.summary,
                "appliesTo": $0.target.rawValue,
                "keywords": $0.keywords,
            ]
        }
        guard let json = Self.jsonString(["presets": arr]) else {
            throw ToolError("Failed to encode presets")
        }
        return .ok(json)
    }

    /// Apply a named preset to clips, expanding it into the existing keyframe/grade primitives.
    func applyPreset(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.applyPresetAllowedKeys, path: "apply_preset")
        let presetName = try args.requireString("preset")
        guard let kind = PresetKind.parse(presetName) else {
            let valid = PresetKind.allCases.map(\.rawValue).joined(separator: ", ")
            throw ToolError("Unknown preset '\(presetName)'. Valid: \(valid). Call list_presets for the catalog.")
        }
        guard let clipIds = args["clipIds"] as? [String], !clipIds.isEmpty else {
            throw ToolError("Missing or empty 'clipIds' array")
        }
        let info = PresetLibrary.info(kind)

        // Validate every clip up front against the preset's target.
        for id in clipIds {
            guard let loc = editor.findClip(id: id) else { throw ToolError("Clip not found: \(id)") }
            let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            switch info.target {
            case .text where clip.mediaType != .text:
                throw ToolError("Preset '\(kind.rawValue)' is a caption animation — clip \(id) is \(clip.mediaType.rawValue), not text.")
            case .visual where clip.mediaType == .audio || clip.mediaType == .text:
                throw ToolError("Preset '\(kind.rawValue)' applies to visual clips — clip \(id) is \(clip.mediaType.rawValue).")
            default:
                break
            }
        }

        let fps = editor.timeline.fps
        let actionName = clipIds.count == 1 ? "Apply \(info.name) (Agent)" : "Apply \(info.name) ×\(clipIds.count) (Agent)"
        withUndoGroup(editor, actionName: actionName) {
            for id in clipIds {
                editor.commitClipProperty(clipId: id) { clip in
                    PresetLibrary.apply(kind, to: &clip, fps: fps)
                }
            }
        }
        let n = clipIds.count
        return .ok("Applied '\(info.name)' (\(info.category.rawValue)) to \(n) clip\(n == 1 ? "" : "s"). Verify with inspect_timeline.")
    }
}
