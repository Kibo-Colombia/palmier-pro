// GeometrySpike.swift — THROWAWAY. Proves the Core Image coordinate-conversion formula the
// GradeCompositor will use, by comparing against AVFoundation's built-in compositor (ground truth).
//
// A custom AVVideoCompositing receives RAW source frames and must reproduce the geometry the
// built-in compositor would apply from a setTransform layer instruction. The risk is the
// top-left(Y-down, AVFoundation) vs bottom-left(Y-up, Core Image) coordinate mismatch.
//
// This renders ONE source (red top half / blue bottom half — asymmetric in Y so a flip is
// obvious) through a non-trivial Transform (scaled + offset, asymmetric in X and Y) two ways:
//   REFERENCE: AVFoundation built-in compositor with setTransform(affineTransform(for:t))
//   TEST:      a custom compositor applying candidate flip-sandwich variants
// and reports which variant matches the reference. That winning formula goes into GradeCompositor.
//
// Run:  swift spikes/GeometrySpike.swift

import AVFoundation
import CoreImage
import CoreVideo
import CoreGraphics

// ---- The EXACT transform mapping Koma feeds AVFoundation (copied from CompositionBuilder.affineTransform) ----
struct T { var centerX = 0.5, centerY = 0.5, width = 1.0, height = 1.0, rotation = 0.0
    var flipH = false, flipV = false
    var topLeft: (x: Double, y: Double) { (centerX - width/2, centerY - height/2) }
}
func affineTransform(for t: T, natSize: CGSize, renderSize: CGSize) -> CGAffineTransform {
    let tl = t.topLeft
    let sx = (renderSize.width / natSize.width) * t.width * (t.flipH ? -1 : 1)
    let sy = (renderSize.height / natSize.height) * t.height * (t.flipV ? -1 : 1)
    let tx = (t.flipH ? tl.x + t.width : tl.x) * renderSize.width
    let ty = (t.flipV ? tl.y + t.height : tl.y) * renderSize.height
    let placed = CGAffineTransform(scaleX: sx, y: sy)
        .concatenating(CGAffineTransform(translationX: tx, y: ty))
    guard t.rotation != 0 else { return placed }
    let cx = t.centerX * renderSize.width
    let cy = t.centerY * renderSize.height
    return placed
        .concatenating(CGAffineTransform(translationX: -cx, y: -cy))
        .concatenating(CGAffineTransform(rotationAngle: t.rotation * .pi / 180))
        .concatenating(CGAffineTransform(translationX: cx, y: cy))
}

func flipY(_ h: CGFloat) -> CGAffineTransform { CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h) }

// Candidate CI-space conversions of an AVFoundation transform tAV.
enum Variant: String, CaseIterable {
    case none, both, srcOnly, renderOnly
    func ci(_ tAV: CGAffineTransform, sh: CGFloat, renderH: CGFloat) -> CGAffineTransform {
        switch self {
        case .none:       return tAV
        case .both:       return flipY(sh).concatenating(tAV).concatenating(flipY(renderH))
        case .srcOnly:    return flipY(sh).concatenating(tAV)
        case .renderOnly: return tAV.concatenating(flipY(renderH))
        }
    }
}

nonisolated(unsafe) let ciCtx = CIContext(options: [.cacheIntermediates: false])
nonisolated(unsafe) var gTAV = CGAffineTransform.identity
nonisolated(unsafe) var gVariant = Variant.both
nonisolated(unsafe) var gRenderSize = CGSize(width: 1280, height: 720)

final class GeoCompositor: NSObject, AVVideoCompositing {
    let sourcePixelBufferAttributes: [String: Any]? = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let requiredPixelBufferAttributesForRenderContext: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    func renderContextChanged(_ c: AVVideoCompositionRenderContext) {}
    func startRequest(_ req: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let tid = req.sourceTrackIDs.first?.int32Value,
                  let src = req.sourceFrame(byTrackID: tid),
                  let dest = req.renderContext.newPixelBuffer() else {
                req.finish(with: NSError(domain: "geo", code: 1)); return
            }
            let s = CIImage(cvPixelBuffer: src)
            let sh = s.extent.height
            let tCI = gVariant.ci(gTAV, sh: sh, renderH: gRenderSize.height)
            let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: gRenderSize))
            let placed = s.transformed(by: tCI).cropped(to: CGRect(origin: .zero, size: gRenderSize))
            ciCtx.render(placed.composited(over: black), to: dest)
            req.finish(withComposedVideoFrame: dest)
        }
    }
}

func twoColorSource(to url: URL, w: Int, h: Int, fps: Int32 = 30, seconds: Double = 1) async throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
    let frames = Int(seconds * Double(fps))
    for i in 0..<frames {
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
                // row 0 = TOP of image in buffer memory. Top half RED, bottom half BLUE. (BGRA)
                let topHalf = row < h/2
                let b: UInt8 = topHalf ? 0 : 255, r: UInt8 = topHalf ? 255 : 0
                for col in 0..<w { let o = row*bpr + col*4
                    p[o] = b; p[o+1] = 0; p[o+2] = r; p[o+3] = 255 }
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
    }
    input.markAsFinished(); await writer.finishWriting()
    if writer.status != .completed { throw NSError(domain: "geo", code: 2, userInfo: [NSLocalizedDescriptionKey: writer.error?.localizedDescription ?? "writer"]) }
}

func comp(from url: URL) async throws -> (AVMutableComposition, CMPersistentTrackID, CGSize) {
    let asset = AVURLAsset(url: url)
    let c = AVMutableComposition()
    let dur = try await asset.load(.duration)
    let v = try await asset.loadTracks(withMediaType: .video).first!
    let natSize = try await v.load(.naturalSize)
    let ct = c.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    try ct.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: v, at: .zero)
    return (c, ct.trackID, natSize)
}

func renderFrame(_ asset: AVAsset, vc: AVVideoComposition) async throws -> CGImage {
    let gen = AVAssetImageGenerator(asset: asset)
    gen.videoComposition = vc
    gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
    let (cg, _) = try await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
    return cg
}

func sample(_ cg: CGImage, _ fx: Double, _ fy: Double) -> (Double, Double, Double) {
    let x = max(0, min(cg.width-1, Int(Double(cg.width)*fx)))
    let y = max(0, min(cg.height-1, Int(Double(cg.height)*fy)))
    var px: [UInt8] = [0,0,0,0]
    let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: -CGFloat(x), y: -CGFloat(cg.height-1-y), width: CGFloat(cg.width), height: CGFloat(cg.height)))
    return (Double(px[0]), Double(px[1]), Double(px[2]))
}

// Mean abs pixel diff across a grid — lower is closer to the reference.
func diff(_ a: CGImage, _ b: CGImage) -> Double {
    var total = 0.0, n = 0.0
    for gy in 1...8 { for gx in 1...8 {
        let fx = Double(gx)/9.0, fy = Double(gy)/9.0
        let pa = sample(a, fx, fy), pb = sample(b, fx, fy)
        total += abs(pa.0-pb.0) + abs(pa.1-pb.1) + abs(pa.2-pb.2); n += 3
    }}
    return total/n
}

func referenceVC(comp: AVMutableComposition, trackID: CMPersistentTrackID, tAV: CGAffineTransform, renderSize: CGSize, fps: Int32) -> AVVideoComposition {
    var li = AVVideoCompositionLayerInstruction.Configuration(trackID: trackID)
    li.setTransform(tAV, at: .zero)
    li.setOpacity(1, at: .zero)
    var instr = AVVideoCompositionInstruction.Configuration()
    instr.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
    instr.layerInstructions = [AVVideoCompositionLayerInstruction(configuration: li)]
    var vc = AVVideoComposition.Configuration()
    vc.renderSize = renderSize
    vc.frameDuration = CMTime(value: 1, timescale: fps)
    vc.instructions = [AVVideoCompositionInstruction(configuration: instr)]
    return AVVideoComposition(configuration: vc)
}

func testVC(comp: AVMutableComposition, trackID: CMPersistentTrackID, renderSize: CGSize, fps: Int32) -> AVVideoComposition {
    var li = AVVideoCompositionLayerInstruction.Configuration(trackID: trackID)
    li.setOpacity(1, at: .zero)            // declares the track as a required source for the request
    var instr = AVVideoCompositionInstruction.Configuration()
    instr.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
    instr.layerInstructions = [AVVideoCompositionLayerInstruction(configuration: li)]
    var vc = AVVideoComposition.Configuration()
    vc.renderSize = renderSize
    vc.frameDuration = CMTime(value: 1, timescale: fps)
    vc.customVideoCompositorClass = GeoCompositor.self
    vc.instructions = [AVVideoCompositionInstruction(configuration: instr)]
    return AVVideoComposition(configuration: vc)
}

let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let renderSize = CGSize(width: 1280, height: 720)
        gRenderSize = renderSize
        let srcURL = FileManager.default.temporaryDirectory.appendingPathComponent("geo-src.mov")
        try await twoColorSource(to: srcURL, w: 960, h: 540)   // source AR differs from render to exercise scale
        let (composition, trackID, natSize) = try await comp(from: srcURL)

        print("\n═══ GEOMETRY CONVERSION PROOF ═══  source \(Int(natSize.width))x\(Int(natSize.height)) → render 1280x720\n")

        let cases: [(String, T)] = [
            ("identity (full frame)", T()),
            ("scale .5 offset up-left", T(centerX: 0.3, centerY: 0.25, width: 0.5, height: 0.5)),
            ("flipV", T(width: 1, height: 1, rotation: 0, flipH: false, flipV: true)),
        ]

        for (name, t) in cases {
            let tAV = affineTransform(for: t, natSize: natSize, renderSize: renderSize)
            gTAV = tAV
            let ref = try await renderFrame(composition, vc: referenceVC(comp: composition, trackID: trackID, tAV: tAV, renderSize: renderSize, fps: 30))
            print("• \(name)")
            print("    reference top-center=\(ints(sample(ref,0.5,0.25))) bottom-center=\(ints(sample(ref,0.5,0.75)))")
            var best = ("", 1e9)
            for v in Variant.allCases {
                gVariant = v
                let test = try await renderFrame(composition, vc: testVC(comp: composition, trackID: trackID, renderSize: renderSize, fps: 30))
                let d = diff(ref, test)
                let mark = d < 12 ? "  ← MATCH" : ""
                print(String(format: "    %-11@  meanDiff=%6.1f%@", v.rawValue as NSString, d, mark))
                if d < best.1 { best = (v.rawValue, d) }
            }
            print("    → best: \(best.0) (\(String(format: "%.1f", best.1)))\n")
        }
        print("Use the variant that MATCHES across ALL cases in GradeCompositor.\n")
    } catch { print("FATAL: \(error)") }
    sem.signal()
}
func ints(_ p: (Double,Double,Double)) -> String { String(format: "R%.0f G%.0f B%.0f", p.0, p.1, p.2) }
sem.wait()
