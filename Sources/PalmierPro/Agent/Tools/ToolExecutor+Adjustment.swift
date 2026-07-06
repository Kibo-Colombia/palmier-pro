import Foundation

// MARK: add_adjustment_layer — a media-less clip that grades everything below it

extension ToolExecutor {
    func addAdjustmentLayer(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["startFrame", "durationFrames", "trackIndex"],
                                path: "add_adjustment_layer")
        let startFrame = try args.requireInt("startFrame")
        let durationFrames = try args.requireInt("durationFrames")
        guard startFrame >= 0 else { throw ToolError("startFrame must be ≥ 0") }
        guard durationFrames > 0 else { throw ToolError("durationFrames must be > 0") }
        let trackIndex = args.int("trackIndex")
        if let trackIndex {
            guard editor.timeline.tracks.indices.contains(trackIndex) else {
                throw ToolError("trackIndex \(trackIndex) out of range (0..\(max(0, editor.timeline.tracks.count - 1)))")
            }
            guard editor.timeline.tracks[trackIndex].type != .audio else {
                throw ToolError("trackIndex \(trackIndex) is an audio track — adjustment layers need a video track")
            }
        }

        let id = editor.addAdjustmentLayer(
            startFrame: startFrame,
            durationFrames: durationFrames,
            trackIndex: trackIndex
        )
        let placement = trackIndex.map { "track \($0)" } ?? "a new top track"
        return .ok("Added adjustment layer \(id) on \(placement), frames \(startFrame)..\(startFrame + durationFrames). Give it a grade with set_grade (and optionally set_mask / set_keyframes) — it applies to every track below across that range.")
    }
}
