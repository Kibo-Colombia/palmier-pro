import AVFoundation
import Foundation

extension ToolExecutor {
    private static let listPresetsAllowedKeys: Set<String> = ["category"]
    private static let applyPresetAllowedKeys: Set<String> = ["clipIds", "preset"]
    private static let previewPresetsAllowedKeys: Set<String> = ["clipId", "presets"]
    private static let previewPresetsMaxCandidates = 6
    private static let previewPresetsMaxDimension: CGFloat = 512
    private static let previewPresetsJPEGQuality: CGFloat = 0.7

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

    /// The disambiguation core (milestone D): render each candidate preset on the user's OWN clip,
    /// non-destructively, so they can pick the closest. One still per candidate (rendered at the frame
    /// that best shows the effect). The live timeline is never touched — each candidate renders on a
    /// value-copy of the timeline.
    func previewPresets(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.previewPresetsAllowedKeys, path: "preview_presets")
        let clipId = try args.requireString("clipId")
        guard let presetNames = args["presets"] as? [String], !presetNames.isEmpty else {
            throw ToolError("Missing or empty 'presets' array (the candidate ids to compare)")
        }
        guard presetNames.count <= Self.previewPresetsMaxCandidates else {
            throw ToolError("Too many candidates (\(presetNames.count)); max \(Self.previewPresetsMaxCandidates).")
        }
        guard let loc = editor.findClip(id: clipId) else { throw ToolError("Clip not found: \(clipId)") }
        let baseClip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]

        var kinds: [PresetKind] = []
        for name in presetNames {
            guard let kind = PresetKind.parse(name) else {
                throw ToolError("Unknown preset '\(name)'. Call list_presets for the catalog.")
            }
            let info = PresetLibrary.info(kind)
            switch info.target {
            case .text where baseClip.mediaType != .text:
                throw ToolError("Candidate '\(kind.rawValue)' is a caption animation but \(clipId) is \(baseClip.mediaType.rawValue).")
            case .visual where baseClip.mediaType == .audio || baseClip.mediaType == .text:
                throw ToolError("Candidate '\(kind.rawValue)' is for visual clips but \(clipId) is \(baseClip.mediaType.rawValue).")
            default:
                break
            }
            kinds.append(kind)
        }

        let timeline = editor.timeline
        let fps = timeline.fps
        let canvas = CGSize(width: timeline.width, height: timeline.height)
        let renderSize = Self.fitSize(canvas, longestEdge: Self.previewPresetsMaxDimension)
        let resolver = editor.mediaResolver

        var imageBlocks: [ToolResult.Block] = []
        var rendered: [[String: Any]] = []
        for kind in kinds {
            var probe = timeline
            PresetLibrary.apply(kind, to: &probe.tracks[loc.trackIndex].clips[loc.clipIndex], fps: fps)
            let absFrame = min(
                baseClip.endFrame - 1,
                baseClip.startFrame + PresetLibrary.previewOffset(kind, fps: fps)
            )
            guard let jpeg = try? await Self.renderProbeFrame(
                timeline: probe, frame: max(0, absFrame), canvas: canvas, renderSize: renderSize, resolver: resolver
            ) else { continue }
            imageBlocks.append(.image(base64: jpeg.base64EncodedString(), mediaType: "image/jpeg"))
            let info = PresetLibrary.info(kind)
            rendered.append(["preset": kind.rawValue, "name": info.name, "category": info.category.rawValue])
        }
        guard !imageBlocks.isEmpty else { throw ToolError("Failed to render any candidate previews.") }

        let meta: [String: Any] = [
            "clipId": clipId,
            "candidates": rendered,
            "note": "One still per candidate, in order, rendered on the user's own clip. Ask the user which is closest, then apply it with apply_preset and refine with set_grade.",
        ]
        guard let json = Self.jsonString(meta) else { throw ToolError("Failed to encode candidate metadata") }
        return ToolResult(content: imageBlocks + [.text(json)], isError: false)
    }

    /// Renders a single composited frame (video + text overlays) from a probe timeline. Mirrors the
    /// inspect_timeline path but on a caller-supplied timeline value, so nothing is committed.
    private static func renderProbeFrame(
        timeline: Timeline, frame: Int, canvas: CGSize, renderSize: CGSize, resolver: MediaResolver
    ) async throws -> Data? {
        let composition = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { resolver.resolveURL(for: $0) },
            renderSize: canvas
        )
        let generator = AVAssetImageGenerator(asset: composition.composition)
        generator.videoComposition = composition.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = renderSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(timeline.fps))
        guard let videoCG = try? await generator.image(at: time).image else { return nil }
        let frameCanvas = CGSize(width: videoCG.width, height: videoCG.height)
        let textRoot = TextLayerController.buildSnapshot(timeline: timeline, canvasSize: frameCanvas, atFrame: frame)
        guard let composited = EditorViewModel.compositeCapture(video: videoCG, textRoot: textRoot, canvas: frameCanvas) else {
            return nil
        }
        return ImageEncoder.encodeJPEG(composited, quality: previewPresetsJPEGQuality)
    }

    /// Aspect-preserving size whose longest edge is at most `longestEdge`.
    private static func fitSize(_ size: CGSize, longestEdge: CGFloat) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > longestEdge else { return size }
        let scale = longestEdge / longest
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}
