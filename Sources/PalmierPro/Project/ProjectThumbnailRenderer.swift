import AppKit
import AVFoundation
import ImageIO

enum ProjectThumbnailRenderer {
    static func render(url: URL, type: ClipType, frame: Int, fps: Int) async -> Data? {
        if type == .image {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 320,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary) else { return nil }
            return jpeg(image)
        }
        guard type == .video, fps > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.maximumSize = CGSize(width: 320, height: 180)
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
        return await withCheckedContinuation { continuation in
            let completion = ThumbnailCompletion(continuation)
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, _ in
                completion.finish(image.flatMap { jpeg($0) })
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                completion.finish(nil)
                generator.cancelAllCGImageGeneration()
            }
        }
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}

private final class ThumbnailCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?

    init(_ continuation: CheckedContinuation<Data?, Never>) { self.continuation = continuation }

    func finish(_ data: Data?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: data)
    }
}
