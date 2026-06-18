import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Per-shot key-frame thumbnails for the hover-scrub library card (M1, "The Organizer").
///
/// One thumbnail per detected shot-start (from the visual index, via `EmbeddingStore.shots`).
/// No new analysis — it reads timestamps the indexer already found and renders one frame each.
/// Cached in memory for the session and on disk as a JPEG sprite sheet + JSON sidecar across
/// sessions (mirroring `MediaVisualCache`), keyed by the same `EmbeddingStore` file identity so
/// a source edit invalidates the entry alongside the embeddings.
@MainActor
final class KeyframeThumbnailCache {
    static let shared = KeyframeThumbnailCache()

    struct Keyframe: Sendable {
        let shotStart: Double
        let image: CGImage
    }

    private var memory: [String: [Keyframe]] = [:]
    private var inFlight: Set<String> = []

    /// Cap concurrent frame extractions so a grid of hovers doesn't starve playback.
    private nonisolated static let gate = AsyncSemaphore(value: 3)
    private nonisolated static let diskCache = DiskCache(named: "KeyframeThumbnails")
    /// Long clips can have hundreds of shots; a card is only ~170pt wide, so sample down.
    private nonisolated static let maxShots = 48
    /// Retina-crisp on a hover card (vs `MediaVisualCache`'s 120px timeline tiles).
    private nonisolated static let tileMaxDim: CGFloat = 320

    /// Synchronous peek for the session cache — safe inside a SwiftUI `body`.
    func cached(key: String) -> [Keyframe]? { memory[key] }

    /// Loads the per-shot keyframes (memory → disk sprite → generate). Returns nil when the
    /// file has no current index or only a single shot, so the caller falls back to the poster.
    func keyframes(forURL url: URL, key: String) async -> [Keyframe]? {
        if let cached = memory[key] { return cached }
        guard !inFlight.contains(key) else { return nil }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        // Fast cross-session path: decode the cached sprite off-main.
        if let disk = await Task.detached(priority: .utility, operation: { Self.loadSprite(key: key) }).value {
            memory[key] = disk
            return disk
        }

        // Need the shot list from the visual index (file read, off-main).
        guard let shots = await Task.detached(priority: .utility, operation: { EmbeddingStore.shots(key: key) }).value,
              shots.count > 1 else { return nil }

        let sampled = Self.sample(shots, max: Self.maxShots)
        let frames = await Self.generate(url: url, shots: sampled)
        guard !frames.isEmpty else { return nil }
        await Task.detached(priority: .utility, operation: { Self.saveSprite(frames, key: key) }).value
        memory[key] = frames
        return frames
    }

    // MARK: - Sampling

    /// Evenly downsample to at most `max` shots, always keeping the first and last.
    private static func sample(_ shots: [EmbeddingStore.Shot], max: Int) -> [EmbeddingStore.Shot] {
        guard shots.count > max, max > 1 else { return shots }
        let step = Double(shots.count - 1) / Double(max - 1)
        return (0..<max).map { shots[Int((Double($0) * step).rounded())] }
    }

    // MARK: - Generation

    private nonisolated static func generate(url: URL, shots: [EmbeddingStore.Shot]) async -> [Keyframe] {
        await gate.wait()
        defer { Task { await gate.signal() } }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: tileMaxDim, height: tileMaxDim)
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let times = shots.map { CMTime(seconds: $0.repTime, preferredTimescale: 600) }
        var shotStartByTimeValue: [Int64: Double] = [:]
        for (i, t) in times.enumerated() { shotStartByTimeValue[t.value] = shots[i].shotStart }

        var collected: [(shotStart: Double, image: CGImage)] = []
        for await result in generator.images(for: times) {
            if case .success(requestedTime: let requested, image: let image, actualTime: _) = result,
               let shotStart = shotStartByTimeValue[requested.value] {
                collected.append((shotStart, image))
            }
        }
        collected.sort { $0.shotStart < $1.shotStart }
        return collected.map { Keyframe(shotStart: $0.shotStart, image: $0.image) }
    }

    // MARK: - Disk sprite cache (one JPEG grid + JSON sidecar; sidecar written last)

    private struct SpriteMeta: Codable {
        let tileWidth: Int
        let tileHeight: Int
        let columns: Int
        let shotStarts: [Double]
    }

    private nonisolated static func loadSprite(key: String) -> [Keyframe]? {
        let metaURL = diskCache.directory.appendingPathComponent(key + ".keyframes.json")
        let imageURL = diskCache.directory.appendingPathComponent(key + ".keyframes.jpg")
        guard let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(SpriteMeta.self, from: metaData),
              meta.tileWidth > 0, meta.tileHeight > 0, meta.columns > 0, !meta.shotStarts.isEmpty,
              let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let sprite = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        let rows = (meta.shotStarts.count + meta.columns - 1) / meta.columns
        guard sprite.width >= meta.tileWidth * min(meta.columns, meta.shotStarts.count),
              sprite.height >= meta.tileHeight * rows else { return nil }
        var out: [Keyframe] = []
        out.reserveCapacity(meta.shotStarts.count)
        for (i, shotStart) in meta.shotStarts.enumerated() {
            let col = i % meta.columns
            let row = i / meta.columns
            let rect = CGRect(x: col * meta.tileWidth, y: row * meta.tileHeight,
                              width: meta.tileWidth, height: meta.tileHeight)
            guard let tile = sprite.cropping(to: rect) else { return nil }
            out.append(Keyframe(shotStart: shotStart, image: tile))
        }
        return out
    }

    private nonisolated static func saveSprite(_ frames: [Keyframe], key: String) {
        guard let first = frames.first?.image, first.width > 0, first.height > 0 else { return }
        let tileW = first.width
        let tileH = first.height
        let columns = min(50, frames.count)
        let rows = (frames.count + columns - 1) / columns
        guard let ctx = CGContext(data: nil, width: tileW * columns, height: tileH * rows,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return }
        for (i, frame) in frames.enumerated() {
            let col = i % columns
            let row = i / columns
            // CGContext origin is bottom-left; row 0 sits at the top to match the crop space.
            let y = (rows - 1 - row) * tileH
            ctx.draw(frame.image, in: CGRect(x: col * tileW, y: y, width: tileW, height: tileH))
        }
        guard let sprite = ctx.makeImage() else { return }

        let imageURL = diskCache.directory.appendingPathComponent(key + ".keyframes.jpg")
        let metaURL = diskCache.directory.appendingPathComponent(key + ".keyframes.json")
        guard let dest = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, sprite, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }

        let meta = SpriteMeta(tileWidth: tileW, tileHeight: tileH, columns: columns, shotStarts: frames.map(\.shotStart))
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metaURL)
        }
    }
}
