import AVFoundation
import CoreImage
import Vision

/// On-device CV/DSP analysis of a reference video → the frame-accurate half of an `EditRecipe`.
///
/// All native, no Python (the research pass found Apple frameworks cover everything except beat
/// detection, which `BeatDetector` handles): shot cuts via `VNGenerateImageFeaturePrintRequest`
/// frame-distance, format from `AVAsset`, color via Core Image area-average, captions via
/// `VNRecognizeTextRequest`. It produces the deterministic recipe fields plus a storyboard (one frame
/// per shot) that the agent looks at to fill the fuzzy `vibe` half.
enum ReferenceAnalyzer {
    struct StoryboardFrame: Sendable {
        let timeSeconds: Double
        let jpeg: Data
    }

    struct Analysis: Sendable {
        var format: FormatRecipe
        var pacing: PacingRecipe
        var beat: BeatRecipe
        var captions: CaptionRecipe
        var color: ColorMoodRecipe
        var storyboard: [StoryboardFrame]
    }

    // Cut detection: feature-print distance above this (and ≥ minGap apart) marks a shot boundary.
    private static let cutThreshold: Float = 0.32
    private static let minShotGap: Double = 0.25
    private static let analysisEdge: CGFloat = 256
    private static let storyboardEdge: CGFloat = 512
    private static let storyboardJPEGQuality: CGFloat = 0.7
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func analyze(url: URL, maxStoryboard: Int) async throws -> Analysis {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ReferenceError.noVideo
        }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        guard duration > 0 else { throw ReferenceError.zeroDuration }

        let natural = (try? await videoTrack.load(.naturalSize)) ?? .zero
        let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
        let oriented = natural.applying(transform)
        let w = Int(abs(oriented.width)), h = Int(abs(oriented.height))
        let fps = Double((try? await videoTrack.load(.nominalFrameRate)) ?? 30)

        // Sample frames at a steady cadence, capped so long inputs stay bounded.
        let cadence = max(0.3, duration / 120)
        var times: [Double] = []
        var t = cadence / 2
        while t < duration { times.append(t); t += cadence }
        if times.isEmpty { times = [duration / 2] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: analysisEdge, height: analysisEdge)

        // One pass: per-frame feature print, color stats, caption presence/position.
        var prints: [(time: Double, print: VNFeaturePrintObservation?)] = []
        var rgbSamples: [(r: Double, g: Double, b: Double)] = []
        var textFrames = 0
        var textCenterYs: [Double] = []
        var lastTextHash = -1
        var textChanges = 0
        var ocrFrames = 0

        for (i, time) in times.enumerated() {
            let cm = CMTime(seconds: time, preferredTimescale: 600)
            guard let cg = try? await generator.image(at: cm).image else {
                prints.append((time, nil)); continue
            }
            prints.append((time, featurePrint(cg)))
            if let rgb = averageRGB(cg) { rgbSamples.append(rgb) }

            // OCR every other frame to keep it cheap.
            if i % 2 == 0 {
                ocrFrames += 1
                let (hasText, centerY, hash) = recognizeText(cg)
                if hasText {
                    textFrames += 1
                    if let centerY { textCenterYs.append(centerY) }
                    if hash != lastTextHash { textChanges += 1; lastTextHash = hash }
                }
            }
        }

        let pacing = detectPacing(prints, duration: duration)
        let color = aggregateColor(rgbSamples)
        let captions = summarizeCaptions(
            textFrames: textFrames, ocrFrames: ocrFrames, centerYs: textCenterYs,
            changes: textChanges, duration: duration
        )
        let beatResult = await BeatDetector.detect(url: url)
        let beat = BeatRecipe(
            bpm: beatResult.bpm, beatTimesSeconds: beatResult.beats,
            confidence: beatResult.confidence, note: beatResult.note
        )

        let format = FormatRecipe(
            width: w, height: h, aspectRatio: Self.aspectRatio(w, h),
            durationSeconds: (duration * 100).rounded() / 100, fps: (fps * 100).rounded() / 100,
            confidence: 1.0
        )

        // Storyboard: one frame at each shot midpoint, capped.
        let storyboard = try await storyboardFrames(
            asset: asset, boundaries: pacing.shotBoundariesSeconds,
            duration: duration, maxFrames: maxStoryboard
        )

        return Analysis(format: format, pacing: pacing, beat: beat, captions: captions, color: color, storyboard: storyboard)
    }

    // MARK: - Shots / pacing

    private static func featurePrint(_ cg: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([request])
        return request.results?.first as? VNFeaturePrintObservation
    }

    private static func detectPacing(_ prints: [(time: Double, print: VNFeaturePrintObservation?)], duration: Double) -> PacingRecipe {
        var boundaries: [Double] = []
        var lastCut = -minShotGap
        var measured = 0
        for i in 1..<max(prints.count, 1) {
            guard let a = prints[i - 1].print, let b = prints[i].print else { continue }
            measured += 1
            var dist: Float = 0
            do { try a.computeDistance(&dist, to: b) } catch { continue }
            let time = prints[i].time
            if dist > cutThreshold, time - lastCut >= minShotGap {
                boundaries.append((time * 1000).rounded() / 1000)
                lastCut = time
            }
        }
        let cutCount = boundaries.count
        let shots = cutCount + 1
        let cps = duration > 0 ? Double(cutCount) / duration : 0
        // Confidence scales with how many comparisons we actually had (sparse sampling = less sure).
        let conf = measured >= 10 ? 0.8 : (measured >= 4 ? 0.55 : 0.3)
        return PacingRecipe(
            cutCount: cutCount,
            cutsPerSecond: (cps * 1000).rounded() / 1000,
            averageShotSeconds: (duration / Double(shots) * 100).rounded() / 100,
            shotBoundariesSeconds: boundaries,
            confidence: conf
        )
    }

    // MARK: - Color

    private static func averageRGB(_ cg: CGImage) -> (r: Double, g: Double, b: Double)? {
        let ci = CIImage(cgImage: cg)
        let extent = ci.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let avg = ci.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)])
        var px = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }

    private static func aggregateColor(_ samples: [(r: Double, g: Double, b: Double)]) -> ColorMoodRecipe {
        guard !samples.isEmpty else {
            return ColorMoodRecipe(averageRGB: [0, 0, 0], brightness: 0, saturation: 0, warmth: 0, moodHint: "unknown", confidence: 0)
        }
        let n = Double(samples.count)
        let r = samples.reduce(0) { $0 + $1.r } / n
        let g = samples.reduce(0) { $0 + $1.g } / n
        let b = samples.reduce(0) { $0 + $1.b } / n
        let brightness = (r + g + b) / 3
        let maxC = max(r, g, b), minC = min(r, g, b)
        let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
        let warmth = max(-1, min(1, (r - b) * 2))

        var parts: [String] = []
        parts.append(warmth > 0.12 ? "warm" : (warmth < -0.12 ? "cool" : "neutral"))
        parts.append(brightness > 0.6 ? "bright" : (brightness < 0.32 ? "dark" : "mid"))
        parts.append(saturation > 0.45 ? "vivid" : (saturation < 0.18 ? "muted" : "natural"))

        func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
        return ColorMoodRecipe(
            averageRGB: [round3(r), round3(g), round3(b)],
            brightness: round3(brightness), saturation: round3(saturation), warmth: round3(warmth),
            moodHint: parts.joined(separator: ", "), confidence: 0.7
        )
    }

    // MARK: - Captions

    private static func recognizeText(_ cg: CGImage) -> (hasText: Bool, centerY: Double?, hash: Int) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([request])
        guard let results = request.results, !results.isEmpty else { return (false, nil, -1) }
        var ys: [Double] = []
        var text = ""
        for obs in results {
            ys.append(Double(obs.boundingBox.midY))
            if let top = obs.topCandidates(1).first { text += top.string }
        }
        guard !ys.isEmpty else { return (false, nil, -1) }
        return (true, ys.reduce(0, +) / Double(ys.count), text.hashValue)
    }

    private static func summarizeCaptions(textFrames: Int, ocrFrames: Int, centerYs: [Double], changes: Int, duration: Double) -> CaptionRecipe {
        guard ocrFrames > 0 else {
            return CaptionRecipe(present: false, coverage: 0, position: nil, changesPerSecond: nil, confidence: 0)
        }
        let coverage = Double(textFrames) / Double(ocrFrames)
        let present = coverage > 0.15
        var position: String?
        if !centerYs.isEmpty {
            let avgY = centerYs.reduce(0, +) / Double(centerYs.count)   // 0 bottom … 1 top (Vision coords)
            position = avgY > 0.66 ? "top" : (avgY < 0.34 ? "bottom" : "center")
        }
        let cps = duration > 0 && present ? Double(changes) / duration : nil
        return CaptionRecipe(
            present: present,
            coverage: (coverage * 1000).rounded() / 1000,
            position: present ? position : nil,
            changesPerSecond: cps.map { ($0 * 1000).rounded() / 1000 },
            confidence: 0.65
        )
    }

    // MARK: - Storyboard

    private static func storyboardFrames(asset: AVURLAsset, boundaries: [Double], duration: Double, maxFrames: Int) async throws -> [StoryboardFrame] {
        // Shot midpoints: [0, b0, b1, …, duration] → midpoint of each consecutive pair.
        var edges = [0.0] + boundaries + [duration]
        edges = Array(Set(edges)).sorted()
        var mids: [Double] = []
        for i in 1..<edges.count { mids.append((edges[i - 1] + edges[i]) / 2) }
        if mids.isEmpty { mids = [duration / 2] }
        // Cap, keeping an even spread.
        if mids.count > maxFrames {
            let step = Double(mids.count) / Double(maxFrames)
            mids = (0..<maxFrames).map { mids[min(mids.count - 1, Int(Double($0) * step))] }
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: storyboardEdge, height: storyboardEdge)

        var out: [StoryboardFrame] = []
        for time in mids {
            let cm = CMTime(seconds: time, preferredTimescale: 600)
            guard let cg = try? await generator.image(at: cm).image,
                  let jpeg = ImageEncoder.encodeJPEG(cg, quality: storyboardJPEGQuality) else { continue }
            out.append(StoryboardFrame(timeSeconds: (time * 100).rounded() / 100, jpeg: jpeg))
        }
        return out
    }

    // MARK: - Helpers

    private static func aspectRatio(_ w: Int, _ h: Int) -> String {
        guard w > 0, h > 0 else { return "?" }
        let g = gcd(w, h)
        return "\(w / g):\(h / g)"
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
}

enum ReferenceError: Error, CustomStringConvertible {
    case noVideo
    case zeroDuration
    var description: String {
        switch self {
        case .noVideo: "The reference has no video track."
        case .zeroDuration: "The reference has zero duration."
        }
    }
}
