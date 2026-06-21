import Testing
import AVFoundation
import CoreImage
import CoreVideo
import CoreGraphics
@testable import PalmierPro

/// Integration tests for the real GradeCompositor / GradeRenderModel / GradeInstruction:
/// render a synthetic source through the actual package compositor and sample pixels.
/// Validates (a) a grade visibly lands, (b) an identity grade does not shift color, and
/// (c) geometry (transform) is reproduced to match AVFoundation's built-in compositor —
/// the flip-sandwich regression guard.
@Suite("GradeCompositor")
struct GradeCompositorTests {

    // MARK: helpers

    /// Writes a short video whose pixels are produced by `color(row, height) -> (b,g,r)`.
    private func makeSource(_ url: URL, w: Int, h: Int, color: @escaping (Int, Int) -> (UInt8, UInt8, UInt8)) async throws {
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
                    let (b, g, r) = color(row, h)
                    for col in 0..<w { let o = row*bpr + col*4; p[o] = b; p[o+1] = g; p[o+2] = r; p[o+3] = 255 }
                }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished(); await writer.finishWriting()
    }

    private func composition(from url: URL) async throws -> (AVMutableComposition, CMPersistentTrackID, CGSize) {
        let asset = AVURLAsset(url: url)
        let c = AVMutableComposition()
        let dur = try await asset.load(.duration)
        let v = try await asset.loadTracks(withMediaType: .video).first!
        let natSize = try await v.load(.naturalSize)
        let ct = c.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try ct.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: v, at: .zero)
        return (c, ct.trackID, natSize)
    }

    /// A videoComposition that drives the REAL GradeCompositor with the given model.
    private func gradeVC(_ comp: AVMutableComposition, model: GradeRenderModel) -> AVVideoComposition {
        var vc = AVVideoComposition.Configuration()
        vc.renderSize = model.renderSize
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(model.fps))
        vc.customVideoCompositorClass = GradeCompositor.self
        vc.instructions = [GradeInstruction(timeRange: CMTimeRange(start: .zero, duration: comp.duration), model: model)]
        return AVVideoComposition(configuration: vc)
    }

    /// Reference videoComposition using AVFoundation's built-in compositor with an optional transform.
    private func builtinVC(_ comp: AVMutableComposition, trackID: CMPersistentTrackID, transform: CGAffineTransform?, renderSize: CGSize) -> AVVideoComposition {
        var li = AVVideoCompositionLayerInstruction.Configuration(trackID: trackID)
        li.setOpacity(1, at: .zero)
        if let transform { li.setTransform(transform, at: .zero) }
        var instr = AVVideoCompositionInstruction.Configuration()
        instr.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
        instr.layerInstructions = [AVVideoCompositionLayerInstruction(configuration: li)]
        var vc = AVVideoComposition.Configuration()
        vc.renderSize = renderSize
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        vc.instructions = [AVVideoCompositionInstruction(configuration: instr)]
        return AVVideoComposition(configuration: vc)
    }

    private func render(_ comp: AVMutableComposition, _ vc: AVVideoComposition) async throws -> CGImage {
        let gen = AVAssetImageGenerator(asset: comp)
        gen.videoComposition = vc
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let (cg, _) = try await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
        return cg
    }

    private func sample(_ cg: CGImage, _ fx: Double, _ fy: Double) -> (Double, Double, Double) {
        let x = max(0, min(cg.width-1, Int(Double(cg.width)*fx)))
        let y = max(0, min(cg.height-1, Int(Double(cg.height)*fy)))
        var px: [UInt8] = [0,0,0,0]
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -CGFloat(x), y: -CGFloat(cg.height-1-y), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return (Double(px[0]), Double(px[1]), Double(px[2]))
    }

    private func gray(_ row: Int, _ h: Int) -> (UInt8, UInt8, UInt8) { (128, 128, 128) }
    private func redTopBlueBottom(_ row: Int, _ h: Int) -> (UInt8, UInt8, UInt8) { row < h/2 ? (0, 0, 255) : (255, 0, 0) }

    private func model(_ trackID: CMPersistentTrackID, natSize: CGSize, renderSize: CGSize, clip: Clip) -> GradeRenderModel {
        GradeRenderModel(fps: 30, renderSize: renderSize, tracks: [
            GradeTrackRender(trackID: trackID, hidden: false,
                             clips: [GradeClipRender(clip: clip, natSize: natSize, preferredTransform: .identity)])
        ])
    }

    // MARK: tests

    @Test func gradeVisiblyLands() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grade-grade.mov")
        try await makeSource(url, w: 640, h: 360, color: gray)
        let (comp, trackID, natSize) = try await composition(from: url)
        let renderSize = CGSize(width: 1280, height: 720)
        // Identity Transform fills the canvas — give the built-in baseline the SAME affine so the
        // only difference vs the graded render is the grade itself, not geometry.
        let tIdentity = CompositionBuilder.affineTransform(for: Transform(), natSize: natSize, renderSize: renderSize)

        let baseline = sample(try await render(comp, builtinVC(comp, trackID: trackID, transform: tIdentity, renderSize: renderSize)), 0.5, 0.5)

        var clip = Fixtures.clip(start: 0, duration: 30)
        clip.grade = ColorGrade(brightness: 0.35)   // additive lift on mid-gray → clearly brighter
        let graded = sample(try await render(comp, gradeVC(comp, model: model(trackID, natSize: natSize, renderSize: renderSize, clip: clip))), 0.5, 0.5)

        #expect(graded.0 > baseline.0 + 25)   // brightness raised the gray noticeably
        #expect(graded.1 > baseline.1 + 25)
        #expect(graded.2 > baseline.2 + 25)
    }

    @Test func identityGradeDoesNotShiftColor() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grade-identity.mov")
        try await makeSource(url, w: 640, h: 360, color: gray)
        let (comp, trackID, natSize) = try await composition(from: url)
        let renderSize = CGSize(width: 1280, height: 720)
        let tIdentity = CompositionBuilder.affineTransform(for: Transform(), natSize: natSize, renderSize: renderSize)

        // Both fill the canvas with the same geometry; only difference is our compositor vs built-in.
        let baseline = sample(try await render(comp, builtinVC(comp, trackID: trackID, transform: tIdentity, renderSize: renderSize)), 0.5, 0.5)

        let clip = Fixtures.clip(start: 0, duration: 30)  // default ColorGrade() == identity
        #expect(clip.grade.isIdentity)
        let through = sample(try await render(comp, gradeVC(comp, model: model(trackID, natSize: natSize, renderSize: renderSize, clip: clip))), 0.5, 0.5)

        // The compositor reproduces the built-in result within codec/render tolerance — no color shift.
        #expect(abs(through.0 - baseline.0) < 8)
        #expect(abs(through.1 - baseline.1) < 8)
        #expect(abs(through.2 - baseline.2) < 8)
    }

    @Test func geometryMatchesBuiltInCompositor() async throws {
        // The flip-sandwich regression guard: a scaled+offset clip through the REAL GradeCompositor
        // (identity grade) must match AVFoundation's built-in setTransform render.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grade-geo.mov")
        try await makeSource(url, w: 960, h: 540, color: redTopBlueBottom)
        let (comp, trackID, natSize) = try await composition(from: url)
        let renderSize = CGSize(width: 1280, height: 720)

        let t = Transform(centerX: 0.3, centerY: 0.25, width: 0.5, height: 0.5)
        let tAV = CompositionBuilder.affineTransform(for: t, natSize: natSize, renderSize: renderSize)
        let reference = try await render(comp, builtinVC(comp, trackID: trackID, transform: tAV, renderSize: renderSize))

        var clip = Fixtures.clip(start: 0, duration: 30)
        clip.transform = t                       // same transform, identity grade
        clip.grade = ColorGrade(brightness: 0.0001) // force non-identity so the compositor engages
        let test = try await render(comp, gradeVC(comp, model: model(trackID, natSize: natSize, renderSize: renderSize, clip: clip)))

        // Compare a grid; placement must match (color is essentially unchanged by 0.0001 brightness).
        var maxDiff = 0.0
        for gy in 1...6 { for gx in 1...6 {
            let r = sample(reference, Double(gx)/7, Double(gy)/7)
            let s = sample(test, Double(gx)/7, Double(gy)/7)
            maxDiff = max(maxDiff, abs(r.0-s.0) + abs(r.1-s.1) + abs(r.2-s.2))
        }}
        #expect(maxDiff < 30)   // geometry placement matches the built-in compositor
    }
}
