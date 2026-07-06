import Testing
import AVFoundation
import CoreImage
import CoreGraphics
@testable import PalmierPro

/// Renders through the real GradeCompositor with adjustment layers in the model and probes
/// pixels: the layer's grade must hit the composited stack below it — only inside its
/// frame range, never when its track is hidden.
@Suite("AdjustmentLayers")
struct AdjustmentLayerTests {

    // MARK: compact render helpers (same approach as GradeCompositorTests)

    private func makeRedSource(_ url: URL, w: Int = 320, h: Int = 180) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for i in 0..<30 {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
            guard let buf = pb else { continue }
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) {
                let bpr = CVPixelBufferGetBytesPerRow(buf)
                let p = base.assumingMemoryBound(to: UInt8.self)
                for row in 0..<h {
                    for col in 0..<w { let o = row*bpr + col*4; p[o] = 0; p[o+1] = 0; p[o+2] = 220; p[o+3] = 255 }
                }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished(); await writer.finishWriting()
    }

    private func renderCenter(model: GradeRenderModel, comp: AVMutableComposition) async throws -> (Double, Double, Double) {
        var vc = AVVideoComposition.Configuration()
        vc.renderSize = model.renderSize
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        vc.customVideoCompositorClass = GradeCompositor.self
        vc.instructions = [GradeInstruction(timeRange: CMTimeRange(start: .zero, duration: comp.duration), model: model)]
        let gen = AVAssetImageGenerator(asset: comp)
        gen.videoComposition = AVVideoComposition(configuration: vc)
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let (cg, _) = try await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
        var px: [UInt8] = [0, 0, 0, 0]
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -CGFloat(cg.width/2), y: -CGFloat(cg.height/2 - 1), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return (Double(px[0]), Double(px[1]), Double(px[2]))
    }

    /// Media track (red source) + one adjustment layer above it.
    private func harness(adjustment: Clip, hidden: Bool = false) async throws -> (GradeRenderModel, AVMutableComposition) {
        // Unique per call: tests run in parallel and AVFoundation reads the file lazily at render.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("adj-layer-\(UUID().uuidString).mov")
        try await makeRedSource(url)
        let asset = AVURLAsset(url: url)
        let comp = AVMutableComposition()
        let v = try await asset.loadTracks(withMediaType: .video).first!
        let natSize = try await v.load(.naturalSize)
        let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try ct.insertTimeRange(CMTimeRange(start: .zero, duration: try await asset.load(.duration)), of: v, at: .zero)

        let mediaClip = Fixtures.clip(start: 0, duration: 30)
        let model = GradeRenderModel(
            fps: 30,
            renderSize: CGSize(width: 320, height: 180),
            tracks: [GradeTrackRender(trackID: ct.trackID, hidden: false,
                                      clips: [GradeClipRender(clip: mediaClip, natSize: natSize,
                                                              preferredTransform: .identity, cube: nil)],
                                      timelineTrackIndex: 1)],
            adjustments: [GradeAdjustmentRender(clip: adjustment, cube: nil,
                                                correctionCube: nil, timelineTrackIndex: 0, hidden: hidden)]
        )
        return (model, comp)
    }

    private func adjustmentClip(start: Int, duration: Int) -> Clip {
        var clip = Fixtures.clip(mediaRef: "", mediaType: .adjustment, start: start, duration: duration)
        clip.sourceClipType = .adjustment
        return clip
    }

    // MARK: tests

    @Test func adjustmentLayerGradesTheStackBelow() async throws {
        var adj = adjustmentClip(start: 0, duration: 30)
        adj.grade.saturation = 0   // B&W over a red source ⇒ gray output
        let (model, comp) = try await harness(adjustment: adj)
        let (r, g, b) = try await renderCenter(model: model, comp: comp)
        #expect(abs(r - g) < 18 && abs(g - b) < 18, "expected near-gray, got \(r),\(g),\(b)")
    }

    @Test func adjustmentLayerOnlyAppliesInsideItsRange() async throws {
        var adj = adjustmentClip(start: 0, duration: 5)   // ends before the probed frame 15
        adj.grade.saturation = 0
        let (model, comp) = try await harness(adjustment: adj)
        let (r, _, b) = try await renderCenter(model: model, comp: comp)
        #expect(r > 150 && b < 60, "red must survive outside the layer's range, got r=\(r) b=\(b)")
    }

    @Test func hiddenAdjustmentTrackIsIgnored() async throws {
        var adj = adjustmentClip(start: 0, duration: 30)
        adj.grade.saturation = 0
        let (model, comp) = try await harness(adjustment: adj, hidden: true)
        let (r, _, b) = try await renderCenter(model: model, comp: comp)
        #expect(r > 150 && b < 60)
    }

    @Test func adjustmentOpacityScalesTheEffect() async throws {
        var adj = adjustmentClip(start: 0, duration: 30)
        adj.grade.saturation = 0
        adj.opacity = 0.5          // half-strength B&W ⇒ still clearly reddish
        let (model, comp) = try await harness(adjustment: adj)
        let (r, g, _) = try await renderCenter(model: model, comp: comp)
        #expect(r - g > 30, "half-opacity layer must leave partial saturation, got r=\(r) g=\(g)")
    }

    @Test func adjustmentClipRoundTripsThroughProjectJSON() throws {
        var adj = adjustmentClip(start: 12, duration: 90)
        adj.grade.contrast = 1.4
        adj.mask = AdjustMask(shape: .radial, feather: 0.3)
        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [adj])])
        timeline.fps = 30
        let data = try JSONEncoder().encode(timeline)
        let back = try JSONDecoder().decode(Timeline.self, from: data)
        let clip = back.tracks[0].clips[0]
        #expect(clip.mediaType == .adjustment)
        #expect(clip.sourceClipType == .adjustment)
        #expect(clip.grade.contrast == 1.4)
        #expect(clip.mask.shape == .radial)
        #expect(!clip.mediaType.buildsCompositionTrack)
    }
}
