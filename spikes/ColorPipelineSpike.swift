// ColorPipelineSpike.swift — forensic harness for Koma's LUT color pipeline.
//
// Question: Koma renders footage+LUT flatter/grayer than DaVinci Resolve rendering the
// IDENTICAL footage with the IDENTICAL baked .cube. Where does the pipeline diverge?
//
// Resolve's model (ground truth): decoded file code values → 3D LUT lookup → output code
// values, written to a file tagged bt709. No linearization anywhere: a .cube baked from a
// node chain is a pure code-value → code-value map.
//
// Koma's model: AVFoundation decodes to BGRA8 (tagged 709) → CIImage linearizes (709
// inverse-OETF) → CIColorCubeWithColorSpace re-encodes to `inputColorSpace` to index the
// cube → cube output decoded back from `inputColorSpace` to linear → CIContext.render
// encodes to the destination buffer. Every place where the encode isn't the exact inverse
// of the decode bends the tones.
//
// This spike measures each variant of (cube inputColorSpace × render output colorspace)
// against Resolve's actual render of the same frame, plus:
//   • NULL      — no LUT at all, compared against the raw source frame (round-trip fidelity)
//   • DIRECT    — CPU trilinear cube lookup on raw code values (the achievable floor:
//                 LUT-bake interpolation error + ground-truth H.264 compression only)
//
// Run:
//   swift spikes/ColorPipelineSpike.swift <source.mp4> <lut.cube> <groundtruth.mov> <frame> [<frame>…]
//
// Ground-truth material (2026-07): DJI Osmo Pocket 3 D-Log M clip, Resolve-baked 65pt cube,
// walk_in_the_park.mov (frame N of the mov == frame N of the source clip, verified via EDL
// + embedded timecode 21:00:52:02).

import AVFoundation
import CoreImage
import CoreVideo
import Foundation

// MARK: - .cube parser (mirror of Sources/PalmierPro/Preview/CubeLUTParser.swift)

struct Cube {
    let dimension: Int
    let data: Data          // dimension³ RGBA float32, red fastest
    let floats: [Float]
}

func parseCube(url: URL) -> Cube? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    var dimension = 0
    var values: [Float] = []
    for rawLine in text.split(whereSeparator: \.isNewline) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        let upper = line.uppercased()
        if upper.hasPrefix("TITLE") || upper.hasPrefix("DOMAIN_MIN") || upper.hasPrefix("DOMAIN_MAX") { continue }
        if upper.hasPrefix("LUT_3D_SIZE") { dimension = Int(line.split(separator: " ").last ?? "") ?? 0; continue }
        if upper.hasPrefix("LUT_1D_SIZE") { return nil }
        let parts = line.split(separator: " ").compactMap { Float($0) }
        guard parts.count == 3 else { continue }
        values.append(contentsOf: [parts[0], parts[1], parts[2], 1])
    }
    guard dimension > 1, values.count == dimension * dimension * dimension * 4 else { return nil }
    return Cube(dimension: dimension, data: values.withUnsafeBytes { Data($0) }, floats: values)
}

// MARK: - Harness compositor: the exact color-relevant slice of GradeCompositor

enum HarnessConfig {
    nonisolated(unsafe) static var cubeColorSpace: CGColorSpace?   // nil → skip LUT
    nonisolated(unsafe) static var renderColorSpace: CGColorSpace? // nil → plain render(to:)
    nonisolated(unsafe) static var useSourceSpaceForCube = false   // override: cube CS = buffer's own CS
    nonisolated(unsafe) static var useSourceSpaceForOut = false    // override: render CS = buffer's own CS
    nonisolated(unsafe) static var cube: Cube?
    nonisolated(unsafe) static var lastSourceDescription = ""
    nonisolated(unsafe) static var sourceSpace: CGColorSpace?
}

nonisolated(unsafe) let ciContext = CIContext(options: [.cacheIntermediates: false])

final class HarnessCompositor: NSObject, AVVideoCompositing {
    let sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let tid = request.sourceTrackIDs.first?.int32Value,
                  let src = request.sourceFrame(byTrackID: tid),
                  let dest = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "harness", code: 1)); return
            }
            // Diagnostic: what does AVFoundation attach to the decoded buffer?
            if HarnessConfig.lastSourceDescription.isEmpty {
                let atts = CVBufferCopyAttachments(src, .shouldPropagate) as? [String: Any] ?? [:]
                let keys = ["ColorPrimaries", "TransferFunction", "YCbCrMatrix"]
                    .map { "\($0)=\(atts["CV\($0)" as String] ?? atts[$0] ?? "?")" }
                let img = CIImage(cvPixelBuffer: src)
                HarnessConfig.lastSourceDescription =
                    "src attachments: \(keys.joined(separator: " ")) | CIImage colorSpace: \(img.colorSpace.map(String.init(describing:)) ?? "nil")"
            }
            var img = CIImage(cvPixelBuffer: src)
            let srcCS = img.colorSpace
            HarnessConfig.sourceSpace = srcCS
            let cubeCS = HarnessConfig.useSourceSpaceForCube ? srcCS : HarnessConfig.cubeColorSpace
            if let cube = HarnessConfig.cube, let cs = cubeCS {
                img = img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                    "inputCubeDimension": cube.dimension,
                    "inputCubeData": cube.data,
                    "inputColorSpace": cs,
                ]).cropped(to: img.extent)
            }
            let outCS = HarnessConfig.useSourceSpaceForOut ? srcCS : HarnessConfig.renderColorSpace
            if let out = outCS {
                ciContext.render(img, to: dest, bounds: img.extent, colorSpace: out)
            } else {
                ciContext.render(img, to: dest)   // exactly what GradeCompositor does today
            }
            request.finish(withComposedVideoFrame: dest)
        }
    }
}

// MARK: - Offline single-frame render through the real AVFoundation compositor machinery

func renderFrame(sourceURL: URL, frame: Int) throws -> [UInt8] {
    let asset = AVURLAsset(url: sourceURL)
    let comp = AVMutableComposition()
    let sem = DispatchSemaphore(value: 0)
    var loadError: Error?
    var natSize = CGSize.zero
    var nominal = CMTime(value: 1001, timescale: 24000)
    Task {
        do {
            guard let srcTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw NSError(domain: "harness", code: 2)
            }
            let (size, range, minDur) = try await srcTrack.load(.naturalSize, .timeRange, .minFrameDuration)
            natSize = size
            nominal = minDur
            let dst = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try dst.insertTimeRange(range, of: srcTrack, at: .zero)
        } catch { loadError = error }
        sem.signal()
    }
    sem.wait()
    if let loadError { throw loadError }

    var vc = AVVideoComposition.Configuration()
    vc.renderSize = natSize
    vc.frameDuration = nominal
    vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
    vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
    vc.customVideoCompositorClass = HarnessCompositor.self
    var instr = AVVideoCompositionInstruction.Configuration()
    instr.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
    var li = AVVideoCompositionLayerInstruction.Configuration(trackID: comp.tracks(withMediaType: .video)[0].trackID)
    li.setOpacity(1, at: .zero)
    instr.layerInstructions = [AVVideoCompositionLayerInstruction(configuration: li)]
    vc.instructions = [AVVideoCompositionInstruction(configuration: instr)]
    let videoComposition = AVVideoComposition(configuration: vc)

    let reader = try AVAssetReader(asset: comp)
    let output = AVAssetReaderVideoCompositionOutput(
        videoTracks: comp.tracks(withMediaType: .video),
        videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    output.videoComposition = videoComposition
    output.alwaysCopiesSampleData = false
    reader.add(output)
    let fps = Double(nominal.timescale) / Double(nominal.value)
    let start = CMTime(seconds: (Double(frame) + 0.25) / fps, preferredTimescale: 24000)
    reader.timeRange = CMTimeRange(start: start, duration: CMTime(seconds: 2.0 / fps, preferredTimescale: 24000))
    guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
          let buf = CMSampleBufferGetImageBuffer(sample) else {
        throw NSError(domain: "harness", code: 3, userInfo: [NSLocalizedDescriptionKey: "no composed frame (reader status \(reader.status.rawValue) \(String(describing: reader.error)))"])
    }
    defer { reader.cancelReading() }
    return bgraToRGB(buf)
}

func bgraToRGB(_ buf: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(buf, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
    let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
    let stride = CVPixelBufferGetBytesPerRow(buf)
    let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
    var rgb = [UInt8](repeating: 0, count: w * h * 3)
    for y in 0..<h {
        let row = base + y * stride
        for x in 0..<w {
            let p = row + x * 4
            let o = (y * w + x) * 3
            rgb[o] = p[2]; rgb[o + 1] = p[1]; rgb[o + 2] = p[0]
        }
    }
    return rgb
}

// MARK: - ffmpeg frame extraction (raw rgb24, code values preserved)

func ffmpegFrame(url: URL, frame: Int, fps: Double) throws -> [UInt8] {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("cps-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: out) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    let ss = String(format: "%.6f", Double(frame) / fps)
    p.arguments = ["-c", "ffmpeg -v error -ss \(ss) -i '\(url.path)' -frames:v 1 -f rawvideo -pix_fmt rgb24 -y '\(out.path)'"]
    try p.run(); p.waitUntilExit()
    let data = try Data(contentsOf: out)
    return [UInt8](data)
}

// MARK: - CPU direct cube application (trilinear, on raw code values) = Resolve emulation

func applyCubeDirect(_ rgb: [UInt8], cube: Cube) -> [UInt8] {
    let n = cube.dimension
    let denom = Float(n - 1)
    let f = cube.floats
    var out = [UInt8](repeating: 0, count: rgb.count)
    let px = rgb.count / 3
    for i in 0..<px {
        let r = Float(rgb[i * 3]) / 255, g = Float(rgb[i * 3 + 1]) / 255, b = Float(rgb[i * 3 + 2]) / 255
        let rf = r * denom, gf = g * denom, bf = b * denom
        let r0 = min(n - 2, max(0, Int(rf))), g0 = min(n - 2, max(0, Int(gf))), b0 = min(n - 2, max(0, Int(bf)))
        let dr = rf - Float(r0), dg = gf - Float(g0), db = bf - Float(b0)
        func at(_ ri: Int, _ gi: Int, _ bi: Int) -> SIMD3<Float> {
            let o = ((bi * n + gi) * n + ri) * 4
            return SIMD3(f[o], f[o + 1], f[o + 2])
        }
        let c00 = at(r0, g0, b0) * (1 - dr) + at(r0 + 1, g0, b0) * dr
        let c10 = at(r0, g0 + 1, b0) * (1 - dr) + at(r0 + 1, g0 + 1, b0) * dr
        let c01 = at(r0, g0, b0 + 1) * (1 - dr) + at(r0 + 1, g0, b0 + 1) * dr
        let c11 = at(r0, g0 + 1, b0 + 1) * (1 - dr) + at(r0 + 1, g0 + 1, b0 + 1) * dr
        let c0 = c00 * (1 - dg) + c10 * dg
        let c1 = c01 * (1 - dg) + c11 * dg
        let c = c0 * (1 - db) + c1 * db
        out[i * 3] = UInt8(max(0, min(255, (c.x * 255).rounded())))
        out[i * 3 + 1] = UInt8(max(0, min(255, (c.y * 255).rounded())))
        out[i * 3 + 2] = UInt8(max(0, min(255, (c.z * 255).rounded())))
    }
    return out
}

// MARK: - Stats

func stats(_ a: [UInt8], _ b: [UInt8], label: String) {
    guard a.count == b.count, !a.isEmpty else {
        print("  \(label): SIZE MISMATCH \(a.count) vs \(b.count)"); return
    }
    var sumAbs = [Double](repeating: 0, count: 3)
    var sumSigned = [Double](repeating: 0, count: 3)
    var maxAbs = [Int](repeating: 0, count: 3)
    let px = a.count / 3
    for i in 0..<px {
        for c in 0..<3 {
            let d = Int(a[i * 3 + c]) - Int(b[i * 3 + c])
            sumAbs[c] += Double(abs(d)); sumSigned[c] += Double(d)
            if abs(d) > maxAbs[c] { maxAbs[c] = abs(d) }
        }
    }
    let n = Double(px)
    let mae = sumAbs.map { $0 / n }
    let bias = sumSigned.map { $0 / n }
    print(String(format: "  %-28s MAE  R %.3f  G %.3f  B %.3f   bias  R %+.3f  G %+.3f  B %+.3f   max  %d/%d/%d",
                 (label as NSString).utf8String!, mae[0], mae[1], mae[2], bias[0], bias[1], bias[2], maxAbs[0], maxAbs[1], maxAbs[2]))
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 5 else {
    print("usage: swift ColorPipelineSpike.swift <source> <lut.cube> <groundtruth> <frame> [<frame>…]")
    exit(1)
}
let sourceURL = URL(fileURLWithPath: args[1])
let cubeURL = URL(fileURLWithPath: args[2])
let truthURL = URL(fileURLWithPath: args[3])
let frames = args[4...].compactMap { Int($0) }
guard let cube = parseCube(url: cubeURL) else { print("bad cube"); exit(1) }
HarnessConfig.cube = cube
let fps = 24000.0 / 1001.0

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let bt709 = CGColorSpace(name: CGColorSpace.itur_709)!
let hdtv: CGColorSpace = {
    let atts: [CFString: Any] = [
        kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
        kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
    ]
    return CVImageBufferCreateColorSpaceFromAttachments(atts as CFDictionary)!.takeRetainedValue()
}()

for frame in frames {
    print("=== frame \(frame) ===")
    let truth = try ffmpegFrame(url: truthURL, frame: frame, fps: fps)
    let source = try ffmpegFrame(url: sourceURL, frame: frame, fps: fps)

    // Floor: what a perfect code-value pipeline achieves (LUT bake + h264 noise only).
    stats(applyCubeDirect(source, cube: cube), truth, label: "DIRECT cpu code-values")

    // Round-trip fidelity: no LUT — vs raw source values. Probes what render() encodes with.
    func setCfg(_ cubeCS: CGColorSpace?, _ outCS: CGColorSpace?, cubeSrc: Bool = false, outSrc: Bool = false) {
        HarnessConfig.cubeColorSpace = cubeCS
        HarnessConfig.renderColorSpace = outCS
        HarnessConfig.useSourceSpaceForCube = cubeSrc
        HarnessConfig.useSourceSpaceForOut = outSrc
    }
    let disableLUT = { HarnessConfig.cube = nil }
    let enableLUT = { HarnessConfig.cube = cube }

    disableLUT()
    setCfg(nil, nil)
    stats(try renderFrame(sourceURL: sourceURL, frame: frame), source, label: "NULL out=plain")
    print("  [\(HarnessConfig.lastSourceDescription)]")
    setCfg(nil, bt709); stats(try renderFrame(sourceURL: sourceURL, frame: frame), source, label: "NULL out=709")
    setCfg(nil, srgb); stats(try renderFrame(sourceURL: sourceURL, frame: frame), source, label: "NULL out=sRGB")
    setCfg(nil, nil, outSrc: true); stats(try renderFrame(sourceURL: sourceURL, frame: frame), source, label: "NULL out=srcCS")

    enableLUT()
    let variants: [(String, CGColorSpace?, CGColorSpace?, Bool, Bool)] = [
        ("CURRENT cube=sRGB out=plain", srgb, nil, false, false),
        ("cube=709   out=plain", bt709, nil, false, false),
        ("cube=srcCS out=plain", nil, nil, true, false),
        ("cube=srcCS out=srcCS", nil, nil, true, true),
        ("FIX cube=hdtv709 out=plain", hdtv, nil, false, false),
        ("cube=709   out=709", bt709, bt709, false, false),
        ("cube=sRGB  out=sRGB", srgb, srgb, false, false),
    ]
    for (label, cubeCS, outCS, cubeSrc, outSrc) in variants {
        setCfg(cubeCS, outCS, cubeSrc: cubeSrc, outSrc: outSrc)
        stats(try renderFrame(sourceURL: sourceURL, frame: frame), truth, label: label)
    }
}
