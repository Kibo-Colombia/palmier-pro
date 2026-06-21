import Foundation

// MARK: set_grade — per-clip primary color correction (grade by conversation)

fileprivate struct SetGradeInput: DecodableToolArgs {
    let clipIds: [String]
    let exposure: Double?
    let brightness: Double?
    let contrast: Double?
    let saturation: Double?
    let temperature: Double?
    let tint: Double?
    let intensity: Double?
    let reset: Bool?

    static let allowedKeys: Set<String> = [
        "clipIds", "exposure", "brightness", "contrast", "saturation",
        "temperature", "tint", "intensity", "reset",
    ]

    var hasAnyField: Bool {
        exposure != nil || brightness != nil || contrast != nil || saturation != nil
            || temperature != nil || tint != nil || intensity != nil || reset == true
    }
}

extension ToolExecutor {
    /// Channel clamp domains (mirrors the CIFilter-sane ranges in GradeCompositor).
    private static func clampGrade(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    func setGrade(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: SetGradeInput = try decodeToolArgs(args, path: "set_grade")
        guard !input.clipIds.isEmpty else { throw ToolError("Missing or empty 'clipIds' array") }
        guard input.hasAnyField else {
            throw ToolError("set_grade needs at least one channel (exposure/brightness/contrast/saturation/temperature/tint/intensity) or reset:true")
        }

        // Resolve every clip up front; grade is a visual property — reject audio clips.
        for id in input.clipIds {
            guard let loc = editor.findClip(id: id) else { throw ToolError("Clip not found: \(id)") }
            let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            if clip.mediaType == .audio {
                throw ToolError("Cannot grade an audio clip: \(id)")
            }
        }

        let actionName = input.clipIds.count == 1 ? "Color Grade (Agent)" : "Color Grade \(input.clipIds.count) Clips (Agent)"
        let summaries: [String] = withUndoGroup(editor, actionName: actionName) {
            var out: [String] = []
            for id in input.clipIds {
                var changed: [String] = []
                editor.commitClipProperty(clipId: id) { clip in
                    var g = clip.grade
                    if input.reset == true { g = ColorGrade() }
                    if let v = input.exposure    { g.exposure    = Self.clampGrade(v, -4...4);   changed.append("exposure \(fmt(g.exposure))") }
                    if let v = input.brightness  { g.brightness  = Self.clampGrade(v, -1...1);   changed.append("brightness \(fmt(g.brightness))") }
                    if let v = input.contrast    { g.contrast    = Self.clampGrade(v, 0...4);    changed.append("contrast \(fmt(g.contrast))") }
                    if let v = input.saturation  { g.saturation  = Self.clampGrade(v, 0...4);    changed.append("saturation \(fmt(g.saturation))") }
                    if let v = input.temperature { g.temperature = Self.clampGrade(v, -100...100); changed.append("temperature \(fmt(g.temperature))") }
                    if let v = input.tint        { g.tint        = Self.clampGrade(v, -100...100); changed.append("tint \(fmt(g.tint))") }
                    if let v = input.intensity   { g.intensity   = Self.clampGrade(v, 0...1);    changed.append("intensity \(fmt(g.intensity))") }
                    clip.grade = g
                }
                if input.reset == true && changed.isEmpty {
                    out.append("\(id): reset to neutral")
                } else {
                    out.append("\(id): \(changed.joined(separator: ", "))")
                }
            }
            return out
        }

        let n = input.clipIds.count
        return .ok("Graded \(n) clip\(n == 1 ? "" : "s"): \(summaries.joined(separator: "; "))")
    }
}

/// Compact number formatting for the per-clip echo (drops trailing zeros).
private func fmt(_ v: Double) -> String {
    if v == v.rounded() { return String(Int(v)) }
    return String(format: "%.2f", v)
}
