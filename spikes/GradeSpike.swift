// GradeSpike.swift — THROWAWAY de-risk spike for Koma in-app color grading.
//
// Purpose: settle the one architecture fork before we write any real grading code.
// To grade real pixels we must install a custom compositor. Two candidate paths:
//
//   A) customVideoCompositorClass (custom AVVideoCompositing)
//      - keeps AVVideoCompositionCoreAnimationTool (Koma bakes text on export with it)
//      - BUT replaces the built-in compositor: hands us RAW per-track frames, so we'd
//        have to re-implement transform/crop/opacity/layering ourselves. Big scope.
//
//   B) AVVideoComposition(applyingCIFiltersWithHandler:)
//      - hands us the ALREADY-composited frame as one CIImage (geometry free). Far less code.
//      - BUT is reputed to be incompatible with CoreAnimationTool (text bake).
//
// This spike empirically answers, across the FOUR consumers Koma really uses
// (AVAssetExportSession w/ named presets, AVAssetImageGenerator = inspect_timeline,
//  and by extension the live player + range-render which share the composition):
//   1. Is a custom compositor honored by AVAssetExportSession with 1080 / HEVC / ProRes?
//   2. Is it honored by AVAssetImageGenerator (the agent's verify loop)?
//   3. Does the custom compositor COEXIST with the CoreAnimationTool text bake?
//   4. Does the cheap handler API grade correctly in export + image generator?
//   5. Does the handler API coexist with CoreAnimationTool? (the deciding test for path B)
//   6. Identity (no-op) grade => no color shift? (trust test)
//   7. Per-frame CI render cost at 1080p (live-scrub viability)
//
// Run:   swift spikes/GradeSpike.swift            (uses a synthetic gray source)
//        swift spikes/GradeSpike.swift /path/clip.mov   (also perf-tests real footage)
//
// Reads a strong tint: +0.35 R, -0.35 B. So a graded mid-gray (0.5,0.5,0.5) reads as
// roughly (0.85, 0.5, 0.15): RED clearly > BLUE. Ungraded gray reads R ~= B.

import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import QuartzCore
import CoreGraphics

// MARK: - Shared render state (single-threaded orchestration; safe for a spike)

nonisolated(unsafe) let ciContext = CIContext(options: [.cacheIntermediates: false])
nonisolated(unsafe) var gApplyTint = true   // false => identity passthrough

enum SpikeError: Error { case noFrame, noDestBuffer, exportNil(String), imageGenFailed }

func tinted(_ image: CIImage) -> CIImage {
    guard gApplyTint else { return image }
    let f = CIFilter.colorMatrix()
    f.inputImage = image
    f.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
    f.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
    f.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
    f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
    f.biasVector = CIVector(x: 0.35, y: 0, z: -0.35, w: 0)
    return f.outputImage ?? image
}

// MARK: - Custom compositor (Path A). Minimal: grade only the first source track.

final class SpikeCompositor: NSObject, AVVideoCompositing {
    var sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let tid = request.sourceTrackIDs.first?.int32Value,
                  let src = request.sourceFrame(byTrackID: tid) else {
                request.finish(with: SpikeError.noFrame); return
            }
            guard let dest = request.renderContext.newPixelBuffer() else {
                request.finish(with: SpikeError.noDestBuffer); return
            }
            let out = tinted(CIImage(cvPixelBuffer: src))
            ciContext.render(out, to: dest)
            request.finish(withComposedVideoFrame: dest)
        }
    }
}

// MARK: - Pixel helpers

struct RGB { let r: Double; let g: Double; let b: Double // 0..255
    var redOverBlue: String { String(format: "R=%.0f G=%.0f B=%.0f", r, g, b) }
    var looksTinted: Bool { r - b > 40 }      // +0.35R -0.35B over 255 ≈ +90/-90
    func close(to o: RGB, tol: Double) -> Bool { abs(r-o.r) <= tol && abs(g-o.g) <= tol && abs(b-o.b) <= tol }
}

func samplePixel(_ cg: CGImage, fx: Double, fy: Double) -> RGB {
    let x = max(0, min(cg.width - 1, Int(Double(cg.width) * fx)))
    let y = max(0, min(cg.height - 1, Int(Double(cg.height) * fy)))
    var px: [UInt8] = [0, 0, 0, 0]
    let cs = CGColorSpaceCreateDeviceRGB()
    let bm = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8,
                              bytesPerRow: 4, space: cs, bitmapInfo: bm) else { return RGB(r: -1, g: -1, b: -1) }
    ctx.draw(cg, in: CGRect(x: -CGFloat(x), y: -CGFloat(cg.height - 1 - y),
                            width: CGFloat(cg.width), height: CGFloat(cg.height)))
    return RGB(r: Double(px[0]), g: Double(px[1]), b: Double(px[2]))
}

func centerAndCorner(_ cg: CGImage) -> (center: RGB, corner: RGB) {
    (samplePixel(cg, fx: 0.5, fy: 0.5), samplePixel(cg, fx: 0.2, fy: 0.2))
}

// MARK: - Synthetic source (deterministic mid-gray, 1280x720, ~1.5s @30)

func makeSyntheticSource(to url: URL, w: Int = 1280, h: Int = 720, seconds: Double = 1.5, fps: Int32 = 30) async throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: w, AVVideoHeightKey: h
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let frames = Int(seconds * Double(fps))
    var pool: CVPixelBufferPool? = adaptor.pixelBufferPool
    for i in 0..<frames {
        while !input.isReadyForMoreMediaData { usleep(2000) }
        var pb: CVPixelBuffer?
        if let p = pool { CVPixelBufferPoolCreatePixelBuffer(nil, p, &pb) }
        if pb == nil {
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
        }
        guard let buf = pb else { continue }
        CVPixelBufferLockBaseAddress(buf, [])
        if let base = CVPixelBufferGetBaseAddress(buf) {
            memset(base, 0x80, CVPixelBufferGetBytesPerRow(buf) * h) // BGRA all 0x80 => mid gray
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        let t = CMTime(value: CMTimeValue(i), timescale: fps)
        adaptor.append(buf, withPresentationTime: t)
        _ = pool // keep
    }
    input.markAsFinished()
    await writer.finishWriting()
    if writer.status != .completed { throw SpikeError.exportNil("synth source: \(writer.error?.localizedDescription ?? "unknown")") }
}

// MARK: - Composition + video-composition builders

func makeComposition(from assetURL: URL) async throws -> AVMutableComposition {
    let asset = AVURLAsset(url: assetURL)
    let comp = AVMutableComposition()
    let dur = try await asset.load(.duration)
    let vtracks = try await asset.loadTracks(withMediaType: .video)
    guard let v = vtracks.first else { throw SpikeError.exportNil("no video track in source") }
    let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    try ct.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: v, at: .zero)
    return comp
}

func customCompositorVC(for asset: AVAsset) async throws -> AVMutableVideoComposition {
    let vc = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
    vc.customVideoCompositorClass = SpikeCompositor.self
    return vc
}

func handlerVC(for asset: AVAsset) async throws -> AVVideoComposition {
    return try await AVVideoComposition.videoComposition(with: asset) { request in
        request.finish(with: tinted(request.sourceImage), context: nil)
    }
}

// A center white overlay layer stands in for Koma's baked text (same CoreAnimationTool path).
func animationTool(w: CGFloat, h: CGFloat) -> AVVideoCompositionCoreAnimationTool {
    let parent = CALayer(); parent.frame = CGRect(x: 0, y: 0, width: w, height: h)
    let video = CALayer(); video.frame = parent.frame
    let overlay = CALayer()
    overlay.frame = CGRect(x: w*0.35, y: h*0.35, width: w*0.30, height: h*0.30)
    overlay.backgroundColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    parent.addSublayer(video)
    parent.addSublayer(overlay)
    return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
}

// MARK: - Export + read-back

func presetFileType(_ preset: String) -> AVFileType {
    preset.contains("ProRes") ? .mov : .mp4
}

func export(_ comp: AVComposition, vc: AVVideoComposition?, preset: String) async throws -> URL {
    guard let session = AVAssetExportSession(asset: comp, presetName: preset) else {
        throw SpikeError.exportNil("AVAssetExportSession nil for preset \(preset)")
    }
    session.videoComposition = vc
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradespike-\(abs(preset.hashValue))-\(Int.random(in: 0...99999))")
        .appendingPathExtension(presetFileType(preset) == .mov ? "mov" : "mp4")
    try? FileManager.default.removeItem(at: out)
    try await session.export(to: out, as: presetFileType(preset))
    return out
}

func frame(of url: URL, at seconds: Double = 0.5) async throws -> CGImage {
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    let (cg, _) = try await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
    return cg
}

func frameViaCompositor(comp: AVComposition, vc: AVVideoComposition, at seconds: Double = 0.5) async throws -> CGImage {
    let gen = AVAssetImageGenerator(asset: comp)
    gen.videoComposition = vc            // inspect_timeline sets this; honors customVideoCompositorClass
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    let (cg, _) = try await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
    return cg
}

// MARK: - Reporting

nonisolated(unsafe) var passCount = 0, failCount = 0, warnCount = 0
func report(_ name: String, _ pass: Bool?, _ detail: String) {
    let tag: String
    switch pass {
    case .some(true): tag = "✅ PASS"; passCount += 1
    case .some(false): tag = "❌ FAIL"; failCount += 1
    case .none: tag = "⚠️  INFO"; warnCount += 1
    }
    print("  \(tag)  \(name)\n          \(detail)")
}

// MARK: - Tests

func run(sourceURL: URL, realFootage: URL?) async {
    print("\n══════════════════════════════════════════════════════════════")
    print(" KOMA COLOR-GRADING DE-RISK SPIKE")
    print(" macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("══════════════════════════════════════════════════════════════")

    // Baseline: ungraded gray from a plain export (no compositor)
    do {
        let comp = try await makeComposition(from: sourceURL)
        let url = try await export(comp, vc: nil, preset: AVAssetExportPreset1280x720)
        let base = samplePixel(try await frame(of: url), fx: 0.5, fy: 0.5)
        report("Baseline ungraded source", base.looksTinted ? false : true,
               "center \(base.redOverBlue)  (expect R≈B, NOT tinted)")
    } catch { report("Baseline ungraded source", false, "error: \(error)") }

    let presets = [
        AVAssetExportPreset1920x1080,
        AVAssetExportPresetHEVC1920x1080,
        AVAssetExportPresetAppleProRes422LPCM
    ]

    print("\n── PATH A: custom AVVideoCompositing (customVideoCompositorClass) ──")
    gApplyTint = true
    for preset in presets {
        do {
            let comp = try await makeComposition(from: sourceURL)
            let vc = try await customCompositorVC(for: comp)
            let url = try await export(comp, vc: vc, preset: preset)
            let c = samplePixel(try await frame(of: url), fx: 0.5, fy: 0.5)
            report("Export honors custom compositor — \(preset)", c.looksTinted,
                   "center \(c.redOverBlue)  (expect RED≫BLUE if grade landed)")
        } catch { report("Export honors custom compositor — \(preset)", false, "error: \(error)") }
    }

    // A + AVAssetImageGenerator (inspect_timeline)
    do {
        let comp = try await makeComposition(from: sourceURL)
        let vc = try await customCompositorVC(for: comp)
        let c = samplePixel(try await frameViaCompositor(comp: comp, vc: vc), fx: 0.5, fy: 0.5)
        report("inspect_timeline (AVAssetImageGenerator) honors custom compositor", c.looksTinted,
               "center \(c.redOverBlue)  (agent's verify loop)")
    } catch { report("inspect_timeline honors custom compositor", false, "error: \(error)") }

    // A + CoreAnimationTool (text bake coexistence) — THE key test for path A
    do {
        let comp = try await makeComposition(from: sourceURL)
        let vc = try await customCompositorVC(for: comp)
        vc.animationTool = animationTool(w: vc.renderSize.width, h: vc.renderSize.height)
        let url = try await export(comp, vc: vc, preset: AVAssetExportPreset1920x1080)
        let (center, corner) = centerAndCorner(try await frame(of: url))
        let textOK = center.r > 200 && center.g > 200 && center.b > 200  // white overlay
        let gradeOK = corner.looksTinted
        report("Custom compositor + CoreAnimationTool COEXIST (text+grade)",
               textOK && gradeOK,
               "center \(center.redOverBlue) [expect WHITE overlay], corner \(corner.redOverBlue) [expect tinted]")
    } catch { report("Custom compositor + CoreAnimationTool coexist", false, "error: \(error)") }

    print("\n── PATH B: AVVideoComposition(applyingCIFiltersWithHandler:) ──")
    for preset in presets {
        do {
            let comp = try await makeComposition(from: sourceURL)
            let vc = try await handlerVC(for: comp)
            let url = try await export(comp, vc: vc, preset: preset)
            let c = samplePixel(try await frame(of: url), fx: 0.5, fy: 0.5)
            report("Export honors CIFilters handler — \(preset)", c.looksTinted,
                   "center \(c.redOverBlue)")
        } catch { report("Export honors CIFilters handler — \(preset)", false, "error: \(error)") }
    }

    // B + AVAssetImageGenerator
    do {
        let comp = try await makeComposition(from: sourceURL)
        let vc = try await handlerVC(for: comp)
        let gen = AVAssetImageGenerator(asset: comp); gen.videoComposition = vc
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let (cg, _) = try await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
        let c = samplePixel(cg, fx: 0.5, fy: 0.5)
        report("inspect_timeline honors CIFilters handler", c.looksTinted, "center \(c.redOverBlue)")
    } catch { report("inspect_timeline honors CIFilters handler", false, "error: \(error)") }

    // B + CoreAnimationTool — THE deciding test for path B
    do {
        let comp = try await makeComposition(from: sourceURL)
        let vcImmutable = try await handlerVC(for: comp)
        guard let vc = vcImmutable.mutableCopy() as? AVMutableVideoComposition else {
            throw SpikeError.exportNil("handler VC not mutable-copyable")
        }
        vc.animationTool = animationTool(w: vc.renderSize.width, h: vc.renderSize.height)
        let url = try await export(comp, vc: vc, preset: AVAssetExportPreset1920x1080)
        let (center, corner) = centerAndCorner(try await frame(of: url))
        let textOK = center.r > 200 && center.g > 200 && center.b > 200
        let gradeOK = corner.looksTinted
        let verdict: Bool? = (textOK && gradeOK) ? true : (gradeOK || textOK ? nil : false)
        report("CIFilters handler + CoreAnimationTool COEXIST (text+grade)", verdict,
               "center \(center.redOverBlue) [want WHITE], corner \(corner.redOverBlue) [want tinted]" +
               (verdict == nil ? "  → PARTIAL: handler API likely drops the animationTool (expected incompatibility)" : ""))
    } catch {
        report("CIFilters handler + CoreAnimationTool coexist", false,
               "error: \(error)  → confirms the known handler-API/text-bake incompatibility")
    }

    print("\n── TRUST: identity grade must not shift color ──")
    do {
        gApplyTint = false
        let comp = try await makeComposition(from: sourceURL)
        let vc = try await customCompositorVC(for: comp)
        let graded = samplePixel(try await frameViaCompositor(comp: comp, vc: vc), fx: 0.5, fy: 0.5)
        let plain  = samplePixel(try await frame(of: try await export(comp, vc: nil, preset: AVAssetExportPreset1280x720)), fx: 0.5, fy: 0.5)
        report("Identity custom compositor = no visible shift", graded.close(to: plain, tol: 6),
               "graded \(graded.redOverBlue) vs plain \(plain.redOverBlue) (tol ±6)")
        gApplyTint = true
    } catch { report("Identity custom compositor = no visible shift", false, "error: \(error)"); gApplyTint = true }

    print("\n── PERF: per-frame CI render cost (live-scrub viability) ──")
    for (label, url) in [("synthetic 1280×720", sourceURL)] + (realFootage.map { [("real footage", $0)] } ?? []) {
        do {
            let comp = try await makeComposition(from: url)
            let vc = try await customCompositorVC(for: comp)
            let gen = AVAssetImageGenerator(asset: comp); gen.videoComposition = vc
            gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
            let dur = try await comp.load(.duration).seconds
            let n = 30
            let start = Date()
            for i in 0..<n {
                let t = CMTime(seconds: min(dur - 0.05, Double(i) / Double(n) * dur), preferredTimescale: 600)
                _ = try await gen.image(at: t)
            }
            let ms = Date().timeIntervalSince(start) / Double(n) * 1000
            report("CI grade throughput — \(label)", nil,
                   String(format: "%.1f ms/frame  (~%.0f fps ceiling; live preview wants ≥24–30)", ms, 1000/ms))
        } catch { report("CI grade throughput — \(label)", false, "error: \(error)") }
    }

    print("\n══════════════════════════════════════════════════════════════")
    print(" SUMMARY: \(passCount) pass · \(failCount) fail · \(warnCount) info")
    print(" Decision rule:")
    print("   • If Path B (handler) export+imagegen PASS and B+text PASS → use handler API (cheap; geometry free).")
    print("   • If B+text FAILS but A export+imagegen+text PASS → use custom compositor (must re-impl geometry).")
    print("   • If a specific export PRESET fails for the chosen path → that path needs AVAssetReader/Writer for export.")
    print("══════════════════════════════════════════════════════════════\n")
}

// MARK: - Entry

let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gradespike-src.mov")
        try await makeSyntheticSource(to: tmp)
        let real = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : nil
        if let r = real, !FileManager.default.fileExists(atPath: r.path) {
            print("⚠️  arg path does not exist, skipping real-footage perf: \(r.path)")
        }
        await run(sourceURL: tmp, realFootage: (real.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }))
    } catch {
        print("FATAL: \(error)")
        failCount += 1
    }
    sem.signal()
}
sem.wait()
exit(failCount > 0 ? 1 : 0)
