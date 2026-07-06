import Foundation

// MARK: set_mask — limit where a clip's color grade applies

/// A fully validated partial mask — parse once, merge over any base mask.
/// Shared by set_mask and set_keyframes' mask rows.
struct MaskChannels {
    static let allowedKeys: Set<String> = [
        "shape", "centerX", "centerY", "width", "height", "rotation", "feather", "invert", "reset",
    ]

    private struct Input: Decodable {
        let shape: String?
        let centerX: Double?
        let centerY: Double?
        let width: Double?
        let height: Double?
        let rotation: Double?
        let feather: Double?
        let invert: Bool?
        let reset: Bool?

        var hasAnyField: Bool {
            shape != nil || centerX != nil || centerY != nil || width != nil || height != nil
                || rotation != nil || feather != nil || invert != nil || reset == true
        }
    }

    private let input: Input
    private let parsedShape: MaskShape?

    var hasAnyField: Bool { input.hasAnyField }

    static func parse(_ raw: [String: Any], path: String) throws -> MaskChannels {
        try validateUnknownKeys(raw, allowed: allowedKeys, path: path)
        let data: Data
        do { data = try JSONSerialization.data(withJSONObject: raw) }
        catch { throw ToolError("\(path): could not re-serialize args (\(error.localizedDescription))") }
        let input: Input
        do { input = try JSONDecoder().decode(Input.self, from: data) }
        catch { throw ToolError("\(path): \(error.localizedDescription)") }

        var shape: MaskShape? = nil
        if let s = input.shape {
            guard let parsed = MaskShape(rawValue: s) else {
                throw ToolError("\(path).shape: unknown shape '\(s)'. Expected one of: \(MaskShape.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            shape = parsed
        }
        return MaskChannels(input: input, parsedShape: shape)
    }

    private static func clamp(_ v: Double, _ range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, v))
    }

    func merged(over base: AdjustMask) -> (mask: AdjustMask, changed: [String]) {
        var m = base
        var changed: [String] = []
        if input.reset == true { m = AdjustMask(); changed.append("reset") }
        if let s = parsedShape { m.shape = s; changed.append("shape \(s.rawValue)") }
        // Centers may go off-frame (−1…2) so masks can sweep in/out via keyframes.
        if let v = input.centerX  { m.centerX  = Self.clamp(v, -1...2); changed.append("centerX \(v)") }
        if let v = input.centerY  { m.centerY  = Self.clamp(v, -1...2); changed.append("centerY \(v)") }
        if let v = input.width    { m.width    = Self.clamp(v, 0.01...4); changed.append("width \(v)") }
        if let v = input.height   { m.height   = Self.clamp(v, 0.01...4); changed.append("height \(v)") }
        if let v = input.rotation { m.rotation = Self.clamp(v, -360...360); changed.append("rotation \(v)") }
        if let v = input.feather  { m.feather  = Self.clamp(v, 0...1); changed.append("feather \(v)") }
        if let v = input.invert   { m.invert   = v; changed.append("invert \(v)") }
        return (m, changed)
    }
}

extension ToolExecutor {
    func setMask(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        guard let clipIds = args["clipIds"] as? [String], !clipIds.isEmpty else {
            throw ToolError("Missing or empty 'clipIds' array")
        }
        var channelArgs = args
        channelArgs.removeValue(forKey: "clipIds")
        let channels = try MaskChannels.parse(channelArgs, path: "set_mask")
        guard channels.hasAnyField else {
            throw ToolError("set_mask needs at least one field (shape/centerX/centerY/width/height/rotation/feather/invert) or reset:true")
        }

        for id in clipIds {
            guard let loc = editor.findClip(id: id) else { throw ToolError("Clip not found: \(id)") }
            let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            if clip.mediaType == .audio {
                throw ToolError("Cannot mask an audio clip: \(id)")
            }
        }

        let summaries: [String] = withUndoGroup(editor, actionName: "Adjust Mask (Agent)") {
            var out: [String] = []
            for id in clipIds {
                var summary = ""
                editor.commitClipProperty(clipId: id) { clip in
                    let (mask, changed) = channels.merged(over: clip.mask)
                    clip.mask = mask
                    summary = changed.joined(separator: ", ")
                }
                out.append("\(id): \(summary.isEmpty ? "no change" : summary)")
            }
            return out
        }

        let n = clipIds.count
        return .ok("Masked \(n) clip\(n == 1 ? "" : "s"): \(summaries.joined(separator: "; "))")
    }
}
