import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import PalmierPro

@Suite("AlphaVideoNormalizer")
struct AlphaVideoNormalizerTests {
    @Test func straightAlphaComesBackPremultiplied() async throws {
        let source = try await Self.writeStraightAlphaClip()
        defer { try? FileManager.default.removeItem(at: source) }

        let output = try #require(try await AlphaVideoNormalizer.premultipliedVideo(
            for: source, mediaRef: "alpha-ok-\(UUID().uuidString)"
        ))
        defer { try? FileManager.default.removeItem(at: output) }

        let (red, alpha) = try await Self.firstPixel(of: output)
        #expect(abs(Int(alpha) - 128) <= 4)
        #expect(abs(Int(red) - 100) <= 8)
    }

    /// Every timeline rebuild used to retry an unreadable clip, each retry leaving a spinning writer behind.
    @Test(.timeLimit(.minutes(1)))
    func unreadableFramesFailWithoutSpinning() async throws {
        let source = try await Self.writeStraightAlphaClip()
        defer { try? FileManager.default.removeItem(at: source) }
        try Self.zeroSecondHalf(of: source)
        let mediaRef = "alpha-bad-\(UUID().uuidString)"

        let first = try await AlphaVideoNormalizer.premultipliedVideo(for: source, mediaRef: mediaRef)
        if let first { try? FileManager.default.removeItem(at: first) }

        let started = Date()
        let second = try await AlphaVideoNormalizer.premultipliedVideo(for: source, mediaRef: mediaRef)
        if let second { try? FileManager.default.removeItem(at: second) }
        #expect(second == nil)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    private static let size = 64
    private static let frameCount = 60

    /// Every pixel is red 200 at alpha 128, stored straight (not premultiplied).
    private static func writeStraightAlphaClip() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("alpha-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = true
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
            AVVideoWidthKey: size,
            AVVideoHeightKey: size,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size,
            kCVPixelBufferHeightKey as String: size,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            let buffer = try straightAlphaBuffer()
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    private static func straightAlphaBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<size {
            for x in 0..<size {
                let p = base + y * rowBytes + x * 4
                p[0] = 0; p[1] = 0; p[2] = 200; p[3] = 128
            }
        }
        return pixelBuffer
    }

    /// Keeps the header (written first) and destroys the later frames' data.
    private static func zeroSecondHalf(of url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        try handle.seek(toOffset: length / 2)
        handle.write(Data(count: Int(length - length / 2)))
    }

    private static func firstPixel(of url: URL) async throws -> (red: UInt8, alpha: UInt8) {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        #expect(reader.startReading())
        let sample = try #require(output.copyNextSampleBuffer())
        let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        return (base[2], base[3])
    }
}
