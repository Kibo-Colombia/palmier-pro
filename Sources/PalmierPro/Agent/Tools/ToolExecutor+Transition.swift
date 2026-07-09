import Foundation

// apply_transition — the house mode-switch gesture, stamped in one call.
//
// The MiraiKibo flagship system (brain/03_studio/VIDEO_MANUAL.md) fixes ONE
// transition per format for every full-frame handoff between talking-head
// footage and a website slide: "el pase de papel" (long-form, subtle) and
// "el golpe" (short-form, aggressive). A signature SFX pins to the exposure
// kiss at the clip edges, so the numbers must never drift per edit — that is
// why this is a tool and not a recipe agents rebuild with set_keyframes.

fileprivate struct ApplyTransitionInput: DecodableToolArgs {
    let clipId: String
    let style: String
    let edges: String?
    static let allowedKeys: Set<String> = ["clipId", "style", "edges"]
}

fileprivate enum TransitionEdges: String {
    case both, `in`, out

    var hasIn: Bool { self != .out }
    var hasOut: Bool { self != .`in` }
}

/// The two canon styles. All frame counts are for 60 fps and auto-shrink on
/// short clips (each edge is capped at a third of the clip).
fileprivate struct TransitionSpec {
    let inFrames: Int      // full settle of the entrance gesture
    let outFrames: Int     // length of the exit gesture
    let fadeInFrames: Int
    let fadeOutFrames: Int
    let kissIn: Double     // exposure kiss at frame 0, decays over kissInFrames
    let kissInFrames: Int
    let kissOut: Double    // closing kiss, rises into the cut
    let kissOutFrames: Int
    let riseIn: Double     // paper: normalized y offset the slide rises from
    let riseOut: Double    // paper: y offset it exits toward (negative = up)
    let scaleIn: Double    // punch: entrance scale factor (1 = none)
    let scaleOut: Double   // punch: exit scale factor
    let rotationIn: Double // punch: entrance rotation settle, degrees

    static let paper = TransitionSpec(
        inFrames: 14, outFrames: 13, fadeInFrames: 10, fadeOutFrames: 10,
        kissIn: 0.45, kissInFrames: 8, kissOut: 0.5, kissOutFrames: 8,
        riseIn: 0.07, riseOut: -0.05, scaleIn: 1, scaleOut: 1, rotationIn: 0
    )

    static let punch = TransitionSpec(
        inFrames: 7, outFrames: 7, fadeInFrames: 4, fadeOutFrames: 4,
        kissIn: 1.2, kissInFrames: 6, kissOut: 1.0, kissOutFrames: 6,
        riseIn: 0, riseOut: 0, scaleIn: 1.16, scaleOut: 1.12, rotationIn: -2
    )

    static func named(_ name: String) -> TransitionSpec? {
        switch name {
        case "paper": return .paper
        case "punch": return .punch
        default: return nil
        }
    }
}

extension ToolExecutor {

    func applyTransition(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: ApplyTransitionInput = try decodeToolArgs(args, path: "apply_transition")
        guard let spec = TransitionSpec.named(input.style) else {
            throw ToolError("Unknown style '\(input.style)'. Expected: paper | punch")
        }
        guard let edges = TransitionEdges(rawValue: input.edges ?? "both") else {
            throw ToolError("Unknown edges '\(input.edges ?? "")'. Expected: both | in | out")
        }
        guard let clip = editor.clipFor(id: input.clipId) else {
            throw ToolError("Clip not found: \(input.clipId)")
        }
        let last = clip.durationFrames - 1
        guard last >= 8 else {
            throw ToolError("Clip \(input.clipId) is too short (\(clip.durationFrames) frames) for a transition")
        }

        // Edges never overlap: each is capped at a third of the clip.
        let cap = max(2, last / 3)
        let inLen = min(spec.inFrames, cap)
        let outLen = min(spec.outFrames, cap)
        let fadeIn = min(spec.fadeInFrames, inLen)
        let fadeOut = min(spec.fadeOutFrames, outLen)
        let kissInLen = min(spec.kissInFrames, inLen)
        let kissOutLen = min(spec.kissOutFrames, outLen)

        let base = clip.transform
        let (tx, ty) = base.topLeft

        var position: [Keyframe<AnimPair>] = []
        var scale: [Keyframe<AnimPair>] = []
        var rotation: [Keyframe<Double>] = []
        var opacity: [Keyframe<Double>] = []
        var grade: [Keyframe<ColorGrade>] = []

        func kissed(_ amount: Double) -> ColorGrade {
            var g = clip.grade
            g.exposure += amount
            return g
        }

        if edges.hasIn {
            if spec.riseIn != 0 {
                position.append(Keyframe(frame: 0, value: AnimPair(a: tx, b: ty + spec.riseIn)))
                position.append(Keyframe(frame: inLen, value: AnimPair(a: tx, b: ty)))
            }
            if spec.scaleIn != 1 {
                // Punch in around the clip's center: pair the scale with a
                // top-left compensation so the center never drifts.
                let w = base.width * spec.scaleIn
                let h = base.height * spec.scaleIn
                scale.append(Keyframe(frame: 0, value: AnimPair(a: w, b: h)))
                scale.append(Keyframe(frame: inLen, value: AnimPair(a: base.width, b: base.height)))
                position.append(Keyframe(frame: 0, value: AnimPair(a: base.centerX - w / 2, b: base.centerY - h / 2)))
                position.append(Keyframe(frame: inLen, value: AnimPair(a: tx, b: ty)))
            }
            if spec.rotationIn != 0 {
                rotation.append(Keyframe(frame: 0, value: spec.rotationIn))
                rotation.append(Keyframe(frame: inLen, value: 0))
            }
            opacity.append(Keyframe(frame: 0, value: 0))
            opacity.append(Keyframe(frame: fadeIn, value: 1))
            grade.append(Keyframe(frame: 0, value: kissed(spec.kissIn)))
            grade.append(Keyframe(frame: kissInLen, value: clip.grade))
        }

        if edges.hasOut {
            if spec.riseOut != 0 {
                position.append(Keyframe(frame: last - outLen, value: AnimPair(a: tx, b: ty)))
                position.append(Keyframe(frame: last, value: AnimPair(a: tx, b: ty + spec.riseOut)))
            }
            if spec.scaleOut != 1 {
                let w = base.width * spec.scaleOut
                let h = base.height * spec.scaleOut
                scale.append(Keyframe(frame: last - outLen, value: AnimPair(a: base.width, b: base.height)))
                scale.append(Keyframe(frame: last, value: AnimPair(a: w, b: h)))
                position.append(Keyframe(frame: last - outLen, value: AnimPair(a: tx, b: ty)))
                position.append(Keyframe(frame: last, value: AnimPair(a: base.centerX - w / 2, b: base.centerY - h / 2)))
            }
            opacity.append(Keyframe(frame: last - fadeOut, value: 1))
            opacity.append(Keyframe(frame: last, value: 0))
            grade.append(Keyframe(frame: last - kissOutLen, value: clip.grade))
            grade.append(Keyframe(frame: last, value: kissed(spec.kissOut)))
        }

        try withUndoGroup(editor, actionName: "Apply Transition (Agent)") {
            editor.commitClipProperty(clipId: input.clipId) { c in
                if !position.isEmpty { c.positionTrack = KeyframeTrack(keyframes: position) }
                if !scale.isEmpty { c.scaleTrack = KeyframeTrack(keyframes: scale) }
                if !rotation.isEmpty { c.rotationTrack = KeyframeTrack(keyframes: rotation) }
                c.opacityTrack = KeyframeTrack(keyframes: opacity)
                c.gradeTrack = KeyframeTrack(keyframes: grade)
            }
        }

        var written = ["opacity", "grade"]
        if !position.isEmpty { written.insert("position", at: 0) }
        if !scale.isEmpty { written.append("scale") }
        if !rotation.isEmpty { written.append("rotation") }
        let edgeNote = [
            edges.hasIn ? "in \(inLen)f" : nil,
            edges.hasOut ? "out \(outLen)f" : nil,
        ].compactMap { $0 }.joined(separator: ", ")
        return .ok("Applied '\(input.style)' mode-switch transition to \(input.clipId) (\(edgeNote)) — replaced keyframe tracks: \(written.joined(separator: ", ")).")
    }
}
