import AppKit
import CoreGraphics
import Foundation

/// Bakes text clips into transparent still images before export.
///
/// The export composition runs GradeCompositor as a custom video compositor, and
/// AVFoundation ignores `animationTool` (the CoreAnimation text path) whenever a custom
/// compositor is set — so CATextLayer overlays silently vanish from exports. Rasterizing
/// each text clip to a canvas-sized PNG and swapping it for an image clip routes text
/// through the same still-image pipeline as any other picture layer, preserving timing,
/// opacity keyframes, and fades.
enum TextExportBaker {
    /// Oversample factor over canvas pixels so glyph edges stay crisp after encoding.
    private static let rasterScale: CGFloat = 2

    /// Returns a timeline copy with every text clip replaced by a baked image clip, plus
    /// a URL resolver for the baked assets (falls back to `resolveURL` for real media).
    @MainActor
    static func bake(
        timeline: Timeline,
        resolveURL: @escaping @Sendable (String) -> URL?
    ) throws -> (timeline: Timeline, resolveURL: @Sendable (String) -> URL?) {
        var baked = timeline
        var bakedURLs: [String: URL] = [:]
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("koma-text-bake-\(UUID().uuidString)", isDirectory: true)

        for ti in baked.tracks.indices where !baked.tracks[ti].hidden {
            for ci in baked.tracks[ti].clips.indices {
                var clip = baked.tracks[ti].clips[ci]
                guard clip.mediaType == .text, clip.endFrame > clip.startFrame else { continue }

                let image = try rasterize(clip: clip, timeline: timeline)
                if bakedURLs.isEmpty {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                }
                let ref = "text-bake-\(clip.id)"
                let url = dir.appendingPathComponent("\(ref).png")
                guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                    throw ExportError.invalidFormat
                }
                CGImageDestinationAddImage(dest, image, nil)
                guard CGImageDestinationFinalize(dest) else { throw ExportError.invalidFormat }
                bakedURLs[ref] = url

                clip.mediaRef = ref
                clip.mediaType = .image
                clip.sourceClipType = .image
                clip.transform = Transform()  // PNG is canvas-sized — fill as-is
                clip.textContent = nil
                clip.textStyle = nil
                baked.tracks[ti].clips[ci] = clip
            }
        }

        let urls = bakedURLs
        return (baked, { id in urls[id] ?? resolveURL(id) })
    }

    /// Renders one text clip (style, shadow, box) alone on a transparent canvas.
    @MainActor
    private static func rasterize(clip: Clip, timeline: Timeline) throws -> CGImage {
        let canvas = CGSize(width: timeline.width, height: timeline.height)
        var solo = timeline
        solo.tracks = [Track(type: .video, clips: [clip])]
        let host = TextLayerController.buildSnapshot(
            timeline: solo, canvasSize: canvas, atFrame: clip.startFrame)
        // buildSnapshot bakes the sampled opacity into the layer; force full — the
        // composition applies the clip's own opacity/keyframes to the image layer.
        host.sublayers?.forEach { $0.opacity = 1 }

        let pixelW = Int(canvas.width * rasterScale)
        let pixelH = Int(canvas.height * rasterScale)
        guard let ctx = CGContext(
            data: nil, width: pixelW, height: pixelH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ExportError.unsupportedPreset }

        ctx.scaleBy(x: rasterScale, y: rasterScale)
        // The snapshot host is geometry-flipped (UIKit-style y-down); CGContext is y-up.
        ctx.translateBy(x: 0, y: canvas.height)
        ctx.scaleBy(x: 1, y: -1)
        host.layoutIfNeeded()
        host.render(in: ctx)
        guard let image = ctx.makeImage() else { throw ExportError.unsupportedPreset }
        return image
    }
}
