import AVFoundation
import Accelerate

/// On-device tempo + beat-grid estimation for a reference video's audio.
///
/// The research pass flagged this as the one piece with no native Apple API (MusicKit's BPM is a
/// metadata tag, not a detector). So this is a from-scratch energy-novelty + autocorrelation tracker
/// built on Accelerate/vDSP — no Python, no FFT setup, no model. It is intentionally modest: good
/// enough to lock a cut-to-beat grid for strong-beat short-form music, with an honest confidence so
/// the apply step can downgrade to plain pacing when the track has no clear pulse.
///
/// Pipeline: decode mono PCM → per-hop energy novelty (log-compressed, half-wave-rectified first
/// difference) → autocorrelation peak in the 60–180 BPM band → phase-align a beat grid.
enum BeatDetector {
    static let sampleRate: Double = 22050
    static let hop = 512
    static let win = 1024

    struct Result: Sendable {
        let bpm: Double?
        let beats: [Double]
        let confidence: Double
        let note: String?
    }

    static func detect(url: URL) async -> Result {
        guard let samples = try? await readMonoSamples(url: url), samples.count > win else {
            return Result(bpm: nil, beats: [], confidence: 0, note: "no decodable audio")
        }
        let env = onsetEnvelope(samples)
        let envRate = sampleRate / Double(hop)
        guard env.count > 8 else {
            return Result(bpm: nil, beats: [], confidence: 0, note: "audio too short for tempo")
        }
        let (bpm, conf) = estimateTempo(env, envRate: envRate)
        guard let bpm, conf > 0.15 else {
            return Result(bpm: nil, beats: [], confidence: conf, note: "no confident tempo — use plain pacing")
        }
        let duration = Double(samples.count) / sampleRate
        let beats = beatGrid(env, envRate: envRate, bpm: bpm, duration: duration)
        return Result(bpm: (bpm * 10).rounded() / 10, beats: beats, confidence: conf, note: nil)
    }

    // MARK: - Decode

    private static func readMonoSamples(url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        var samples: [Float] = []
        while let buf = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buf) else { continue }
            let len = CMBlockBufferGetDataLength(block)
            guard len > 0 else { continue }
            var chunk = [Float](repeating: 0, count: len / MemoryLayout<Float>.size)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: &chunk)
            samples.append(contentsOf: chunk)
            CMSampleBufferInvalidate(buf)
        }
        return samples
    }

    // MARK: - Onset novelty

    private static func onsetEnvelope(_ x: [Float]) -> [Float] {
        let n = x.count
        let frames = max(0, (n - win) / hop + 1)
        guard frames > 1 else { return [] }
        var logE = [Float](repeating: 0, count: frames)
        x.withUnsafeBufferPointer { p in
            for i in 0..<frames {
                var ms: Float = 0
                vDSP_measqv(p.baseAddress! + i * hop, 1, &ms, vDSP_Length(win))  // mean of squares
                logE[i] = logf(1 + 1000 * ms)
            }
        }
        var env = [Float](repeating: 0, count: frames)
        for i in 1..<frames {
            let d = logE[i] - logE[i - 1]
            env[i] = d > 0 ? d : 0
        }
        return env
    }

    // MARK: - Tempo via autocorrelation

    private static func estimateTempo(_ env: [Float], envRate: Double) -> (Double?, Double) {
        let n = env.count
        var mean: Float = 0
        vDSP_meanv(env, 1, &mean, vDSP_Length(n))
        let centered = env.map { $0 - mean }

        let minBPM = 60.0, maxBPM = 180.0
        let minLag = max(1, Int((60.0 / maxBPM) * envRate))
        let maxLag = Int((60.0 / minBPM) * envRate)
        guard maxLag < n, minLag < maxLag else { return (nil, 0) }

        var zero: Float = 0
        vDSP_dotpr(centered, 1, centered, 1, &zero, vDSP_Length(n))
        guard zero > 0 else { return (nil, 0) }

        var bestLag = 0
        var bestVal: Float = 0
        centered.withUnsafeBufferPointer { p in
            for lag in minLag...maxLag {
                var acc: Float = 0
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &acc, vDSP_Length(n - lag))
                let norm = acc / zero
                if norm > bestVal { bestVal = norm; bestLag = lag }
            }
        }
        guard bestLag > 0 else { return (nil, 0) }
        let bpm = 60.0 * envRate / Double(bestLag)
        return (bpm, Double(max(0, min(1, bestVal))))
    }

    // MARK: - Beat grid (phase alignment)

    private static func beatGrid(_ env: [Float], envRate: Double, bpm: Double, duration: Double) -> [Double] {
        let period = 60.0 / bpm
        let periodFrames = period * envRate
        guard periodFrames >= 1 else { return [] }

        var bestPhase = 0.0
        var bestScore: Float = -1
        let phaseSteps = 16
        for s in 0..<phaseSteps {
            let phase = Double(s) / Double(phaseSteps) * periodFrames
            var score: Float = 0
            var f = phase
            while Int(f) < env.count {
                score += env[Int(f)]
                f += periodFrames
            }
            if score > bestScore { bestScore = score; bestPhase = phase }
        }

        var beats: [Double] = []
        var t = bestPhase / envRate
        while t < duration {
            beats.append((t * 1000).rounded() / 1000)
            t += period
        }
        return beats
    }
}
