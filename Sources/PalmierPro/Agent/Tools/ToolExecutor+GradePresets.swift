import Foundation

// MARK: save_grade_preset / list_grade_presets / apply_grade_preset — user-saved grades

extension ToolExecutor {
    func saveGradePreset(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["name", "clipId"], path: "save_grade_preset")
        let name = try args.requireString("name")
        let clipId = try args.requireString("clipId")
        guard let clip = editor.clipFor(id: clipId) else { throw ToolError("Clip not found: \(clipId)") }
        guard clip.mediaType != .audio else { throw ToolError("Audio clips carry no grade: \(clipId)") }
        guard !clip.grade.isIdentity else {
            throw ToolError("Clip \(clipId) has a neutral grade — nothing to save. Grade it first with set_grade/apply_look.")
        }
        let preset: GradePresetStore.GradePreset
        do {
            preset = try GradePresetStore.shared.save(name: name, grade: clip.grade)
        } catch GradePresetStore.PresetError.emptyName {
            throw ToolError("Preset name must not be empty")
        }
        return .ok("Saved grade preset '\(preset.name)' (id \(preset.id)) from clip \(clipId). Note: presets capture the STATIC grade only — keyframes and masks are not included.")
    }

    func listGradePresets() -> ToolResult {
        let presets = GradePresetStore.shared.all()
        guard !presets.isEmpty else {
            return .ok("No saved grade presets yet. Save one with save_grade_preset.")
        }
        let rows: [[String: Any]] = presets.map { p in
            var row: [String: Any] = ["id": p.id, "name": p.name]
            var traits: [String] = []
            if let lut = p.grade.lut { traits.append("look:\(lut)") }
            if p.grade.exposure != 0 { traits.append("exposure") }
            if p.grade.contrast != 1 { traits.append("contrast") }
            if p.grade.saturation != 1 { traits.append("saturation") }
            if p.grade.temperature != 0 || p.grade.tint != 0 { traits.append("white-balance") }
            if p.grade.highlights != 0 || p.grade.shadows != 0 || p.grade.fade != 0 { traits.append("tonal") }
            if !p.grade.hsl.isIdentity { traits.append("hsl") }
            if !p.grade.curves.isIdentity { traits.append("curves") }
            if !p.grade.wheels.isIdentity { traits.append("wheels") }
            if p.grade.vignette != 0 { traits.append("vignette") }
            row["adjusts"] = traits
            return row
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["presets": rows])) ?? Data()
        return .ok(String(data: data, encoding: .utf8) ?? "{}")
    }

    func applyGradePreset(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["presetId", "clipIds", "intensity"], path: "apply_grade_preset")
        let presetId = try args.requireString("presetId")
        guard let clipIds = args["clipIds"] as? [String], !clipIds.isEmpty else {
            throw ToolError("Missing or empty 'clipIds' array")
        }
        guard let preset = GradePresetStore.shared.preset(id: presetId) else {
            throw ToolError("Unknown preset id '\(presetId)'. Call list_grade_presets for the catalog.")
        }
        for id in clipIds {
            guard let clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            if clip.mediaType == .audio { throw ToolError("Cannot grade an audio clip: \(id)") }
        }
        var grade = preset.grade
        if let intensity = args.double("intensity") {
            grade.intensity = min(1, max(0, intensity))
        }

        let actionName = "Apply Grade Preset (Agent)"
        _ = withUndoGroup(editor, actionName: actionName) {
            for id in clipIds {
                editor.commitClipProperty(clipId: id) { $0.grade = grade }
            }
            return ()
        }
        let n = clipIds.count
        return .ok("Applied preset '\(preset.name)' to \(n) clip\(n == 1 ? "" : "s") (replaces each clip's grade; masks/keyframes untouched).")
    }
}
