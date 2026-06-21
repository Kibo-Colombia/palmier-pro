import AVFoundation
import CoreImage
import Foundation

/// Shared on-device auto-color analysis (no AI): render a clip's representative frame, then derive
/// a gentle exposure lift + a gray-world white-balance nudge. Used by the auto_color MCP tool and
/// the inspector's Auto button so both produce the same correction.
enum AutoColorAnalysis {
    struct Result: Sendable { let exposure: Double; let temperature: Double; let tint: Double }

    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func analyze(url: URL, clip: Clip, fps: Int) async -> Result? {
        guard let rgb = try? await averageRGB(url: url, clip: clip, fps: fps) else { return nil }
        let (r, g, b) = rgb
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let ev = luma > 0.02 ? max(-1.5, min(1.5, log2(0.46 / luma))) : 1.5
        let temp = max(-60, min(60, (b - r) * 220))            // cool frame (b>r) → warm it (+)
        let tint = max(-60, min(60, (g - (r + b) / 2) * 220))  // green cast (g high) → +magenta
        return Result(exposure: round2(ev), temperature: round2(temp), tint: round2(tint))
    }

    /// Average sRGB of a representative frame — a still loads directly; a video renders its midpoint.
    private static func averageRGB(url: URL, clip: Clip, fps: Int) async throws -> (Double, Double, Double) {
        let ci: CIImage
        if clip.mediaType == .image, let img = CIImage(contentsOf: url) {
            ci = img
        } else {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            gen.maximumSize = CGSize(width: 320, height: 320)
            let midSource = Double(clip.trimStartFrame) + Double(clip.durationFrames) * clip.speed / 2
            let t = CMTime(seconds: max(0, midSource / Double(max(1, fps))), preferredTimescale: 600)
            ci = CIImage(cgImage: try await gen.image(at: t).image)
        }
        let avg = ci.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: ci.extent)])
        var px = [UInt8](repeating: 0, count: 4)
        context.render(avg, toBitmap: &px, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: colorSpace)
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }

    private static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}

// MARK: auto_color — instant, on-device exposure + white-balance correction (no AI)

fileprivate struct AutoColorInput: DecodableToolArgs {
    let clipIds: [String]
    let intensity: Double?
    static let allowedKeys: Set<String> = ["clipIds", "intensity"]
}

extension ToolExecutor {
    func autoColor(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: AutoColorInput = try decodeToolArgs(args, path: "auto_color")
        guard !input.clipIds.isEmpty else { throw ToolError("Missing or empty 'clipIds' array") }

        // Render + analyze each clip's representative frame up front (async), before the undo group.
        var derived: [(id: String, result: AutoColorAnalysis.Result)] = []
        var skipped: [String] = []
        for id in input.clipIds {
            guard let loc = editor.findClip(id: id) else { throw ToolError("Clip not found: \(id)") }
            let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            if clip.mediaType == .audio { throw ToolError("Cannot color an audio clip: \(id)") }
            guard let url = editor.mediaResolver.resolveURL(for: clip.mediaRef),
                  let r = await AutoColorAnalysis.analyze(url: url, clip: clip, fps: editor.timeline.fps) else {
                skipped.append(id); continue
            }
            derived.append((id, r))
        }
        guard !derived.isEmpty else { throw ToolError("Could not render a frame for any clip to analyze.") }

        let intensity = input.intensity.map { min(1, max(0, $0)) }
        let actionName = derived.count == 1 ? "Auto Color (Agent)" : "Auto Color \(derived.count) Clips (Agent)"
        let summaries: [String] = withUndoGroup(editor, actionName: actionName) {
            derived.map { d in
                editor.commitClipProperty(clipId: d.id) { clip in
                    clip.grade.exposure = d.result.exposure
                    clip.grade.temperature = d.result.temperature
                    clip.grade.tint = d.result.tint
                    if let intensity { clip.grade.intensity = intensity }
                }
                return "\(d.id): exposure \(fmt(d.result.exposure)), temp \(fmt(d.result.temperature)), tint \(fmt(d.result.tint))"
            }
        }
        var msg = "Auto-colored \(derived.count) clip\(derived.count == 1 ? "" : "s"): \(summaries.joined(separator: "; "))"
        if !skipped.isEmpty { msg += ". Skipped (no frame): \(skipped.joined(separator: ", "))" }
        return .ok(msg)
    }
}

private func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v) }
