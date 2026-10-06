import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

@Suite("Export jobs")
@MainActor
struct ExportJobTests {
    private let fm = FileManager.default

    private func fixture() async throws -> (root: URL, timeline: Timeline, manifest: MediaManifest) {
        let root = fm.temporaryDirectory.appendingPathComponent("export-jobs-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let video = try await ImageVideoGenerator.blackVideo(size: CGSize(width: 32, height: 48))
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(id: "art", name: "Black", type: .video,
            source: .external(absolutePath: video.path), duration: 5)]
        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(mediaRef: "art", mediaType: .video, start: 0, duration: 15),
        ])])
        timeline.width = 32
        timeline.height = 48
        return (root, timeline, manifest)
    }

    @Test func cancellationPreservesExistingOutputAndReceiptSurvivesRestart() async throws {
        let (root, timeline, manifest) = try await fixture()
        defer { try? fm.removeItem(at: root) }
        let output = root.appendingPathComponent("review.mp4")
        try Data("PREVIOUS EXPORT".utf8).write(to: output)
        let storage = root.appendingPathComponent("jobs")
        let service = ExportJobService(storageURL: storage)
        let job = try service.start(timeline: timeline, manifest: manifest, projectURL: nil,
            path: output.path, formatName: "h264", resolutionName: "720p", overwrite: true, idempotencyKey: "cancel-1")
        _ = try service.cancel(jobId: job.jobId)
        let receipt = try await service.wait(jobId: job.jobId)
        #expect(receipt.state == .cancelled)
        #expect(try String(contentsOf: output, encoding: .utf8) == "PREVIOUS EXPORT")
        let restored = ExportJobService(storageURL: storage)
        #expect(try restored.receipt(jobId: job.jobId).state == .cancelled)
    }

    @Test func retryReturnsSameJobAndRejectsChangedRequest() async throws {
        let (root, timeline, manifest) = try await fixture()
        defer { try? fm.removeItem(at: root) }
        let service = ExportJobService(storageURL: root.appendingPathComponent("jobs"))
        let path = root.appendingPathComponent("review.mp4").path
        let first = try service.start(timeline: timeline, manifest: manifest, projectURL: nil,
            path: path, formatName: "h264", resolutionName: "720p", overwrite: false, idempotencyKey: "same")
        let retry = try service.start(timeline: timeline, manifest: manifest, projectURL: nil,
            path: path, formatName: "h264", resolutionName: "720p", overwrite: false, idempotencyKey: "same")
        #expect(first.jobId == retry.jobId)
        #expect(throws: ToolError.self) {
            try service.start(timeline: timeline, manifest: manifest, projectURL: nil,
                path: path, formatName: "h265", resolutionName: "720p", overwrite: false, idempotencyKey: "same")
        }
        #expect(throws: ToolError.self) {
            try service.start(timeline: timeline, manifest: manifest, projectURL: nil,
                path: path, formatName: "h264", resolutionName: "720p", overwrite: false, idempotencyKey: "other")
        }
        _ = try service.cancel(jobId: first.jobId)
        _ = try await service.wait(jobId: first.jobId)
    }

    @Test func missingMediaRejectsBeforeCreatingJobOrOutput() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("export-missing-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let service = ExportJobService(storageURL: root.appendingPathComponent("jobs"))
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(mediaRef: "missing", mediaType: .image, start: 0, duration: 30),
        ])])
        let output = root.appendingPathComponent("review.mp4")
        #expect(throws: ToolError.self) {
            try service.start(timeline: timeline, manifest: MediaManifest(), projectURL: nil,
                path: output.path, formatName: "h264", resolutionName: "720p", overwrite: false, idempotencyKey: nil)
        }
        #expect(!fm.fileExists(atPath: output.path))
        #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("jobs").path).isEmpty)
    }

    @Test func realExportFreezesRevisionAndWritesPlayablePortrait() async throws {
        let (root, originalTimeline, manifest) = try await fixture()
        defer { try? fm.removeItem(at: root) }
        let service = ExportJobService(storageURL: root.appendingPathComponent("jobs"))
        var timeline = originalTimeline
        let output = root.appendingPathComponent("review.mp4")
        let revision = try TimelineEditPlanner.revision(timeline: timeline, manifest: manifest)
        let job = try service.start(timeline: timeline, manifest: manifest, projectURL: nil,
            path: output.path, formatName: "h264", resolutionName: "720p", overwrite: false, idempotencyKey: "complete-1")
        timeline.tracks[0].clips[0].durationFrames = 60
        let receipt = try await service.wait(jobId: job.jobId)
        #expect(receipt.state == .completed, "\(receipt.error ?? "")")
        #expect(receipt.sourceRevision == revision)
        #expect(receipt.totalFrames == 15)
        #expect((receipt.bytes ?? 0) > 0)
        #expect(receipt.progress == 1)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 0.5) < 0.1)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size.width == 720)
        #expect(size.height == 1080)
    }

    @Test func persistedRunningJobBecomesInterruptedAfterRestart() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("interrupted-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var receipt = ExportJobReceipt(jobId: UUID().uuidString, path: "/tmp/review.mp4", format: "h264",
            resolution: "720p", sourceRevision: "frozen", totalFrames: 30, fps: 30,
            createdAt: Date(), idempotencyKey: "interrupted-1", requestFingerprint: "request")
        receipt.state = .running
        try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent("\(receipt.jobId).json"))
        let service = ExportJobService(storageURL: root)
        let restored = try service.receipt(jobId: receipt.jobId)
        #expect(restored.state == .failed)
        #expect(restored.error?.contains("interrupted") == true)
        #expect(restored.finishedAt != nil)
    }

    @Test func corruptExistingImageFailsWithoutReplacingPreviousExport() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("corrupt-export-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let image = root.appendingPathComponent("broken.png")
        try Data("NOT AN IMAGE".utf8).write(to: image)
        let output = root.appendingPathComponent("review.mp4")
        try Data("PREVIOUS EXPORT".utf8).write(to: output)
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(id: "art", name: "Broken", type: .image,
            source: .external(absolutePath: image.path), duration: 0)]
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(mediaRef: "art", mediaType: .image, start: 0, duration: 30),
        ])])
        let service = ExportJobService(storageURL: root.appendingPathComponent("jobs"))
        let job = try service.start(timeline: timeline, manifest: manifest, projectURL: nil,
            path: output.path, formatName: "h264", resolutionName: "720p", overwrite: true, idempotencyKey: nil)
        let receipt = try await service.wait(jobId: job.jobId)
        #expect(receipt.state == .failed)
        #expect(receipt.error?.contains("Unreadable image") == true)
        #expect(try String(contentsOf: output, encoding: .utf8) == "PREVIOUS EXPORT")
    }
}
