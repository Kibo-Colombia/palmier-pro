import AVFoundation
import CoreGraphics
import Foundation

/// The "recognizing" pass (M5): detect faces across a clip's sampled frames and persist a
/// `FaceRecord` — presence + timing, plus a few representative feature prints for later identity
/// clustering. On-device (Vision), free, and idempotent per (file, detector, sampler) like the
/// visual/transcript passes. Reuses `FrameSampler`, so it sees the same shot-aware frames the
/// visual indexer does (decoded independently — faces don't need the SigLIP model).
enum FaceIndexer {
    /// Crops below this normalized size are too small for a reliable feature print — counted as a
    /// sighting but not used as an identity sample.
    private static let minPrintSize: CGFloat = 0.06
    /// Representative prints kept per clip (best capture quality wins).
    private static let maxPrints = 3

    static func fingerprint(url: URL) -> String {
        "v\(FaceDetector.version)|s\(FrameSampler.samplerVersion)"
    }

    static func needsIndex(url: URL) -> Bool {
        guard let key = EmbeddingStore.key(for: url) else { return false }
        guard let record = FaceStore.load(key: key) else { return true }
        return record.fingerprint != fingerprint(url: url)
    }

    /// Detect + persist faces for one clip. No-op if already current. Persists even a no-face clip
    /// (empty record) so the pass resumes cheaply and isn't reprocessed.
    static func index(url: URL) async {
        guard let key = EmbeddingStore.key(for: url), needsIndex(url: url) else { return }
        let fp = fingerprint(url: url)
        let record = await Task.detached(priority: .utility) {
            await build(url: url, fingerprint: fp)
        }.value
        FaceStore.save(record, key: key)
        Log.search.notice("faces \(key.prefix(8)) max=\(record.maxFaces) hits=\(record.hits.count) prints=\(record.prints.count)")
    }

    private static func build(url: URL, fingerprint fp: String) async -> FaceRecord {
        let duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        var hits: [FaceHit] = []
        var maxFaces = 0
        // Keep frame + box for the best-quality face crops; pruned to maxPrints at the end.
        var candidates: [(quality: Float, time: Double, box: CGRect, frame: CGImage)] = []

        do {
            for try await frame in FrameSampler.frames(url: url, duration: duration) {
                if Task.isCancelled { break }
                let faces = FaceDetector.detect(in: frame.image)
                guard !faces.isEmpty else { continue }
                maxFaces = max(maxFaces, faces.count)
                for face in faces {
                    hits.append(FaceHit(time: frame.time, box: topLeft(face.box), quality: face.quality))
                    if face.box.width >= minPrintSize, face.box.height >= minPrintSize {
                        candidates.append((face.quality, frame.time, face.box, frame.image))
                    }
                }
                // Bound transient memory: keep only the strongest crops in flight.
                if candidates.count > maxPrints * 4 {
                    candidates = Array(candidates.sorted { $0.quality > $1.quality }.prefix(maxPrints * 2))
                }
            }
        } catch {
            Log.search.warning("face sampling failed \(url.lastPathComponent): \(error.localizedDescription)")
        }

        var prints: [FacePrint] = []
        for cand in candidates.sorted(by: { $0.quality > $1.quality }).prefix(maxPrints) {
            if let vector = FaceDetector.featurePrint(of: cand.frame, normBox: cand.box) {
                prints.append(FacePrint(vector: vector, quality: cand.quality, time: cand.time, box: topLeft(cand.box)))
            }
        }
        return FaceRecord(fingerprint: fp, maxFaces: maxFaces, hits: hits, prints: prints)
    }

    /// Vision box (normalized, bottom-left origin) → normalized top-left `[x, y, w, h]` for storage.
    private static func topLeft(_ b: CGRect) -> [Double] {
        [Double(b.minX), Double(1 - b.minY - b.height), Double(b.width), Double(b.height)]
    }
}
