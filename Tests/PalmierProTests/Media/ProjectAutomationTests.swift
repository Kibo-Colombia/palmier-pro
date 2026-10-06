import AppKit
import Foundation
import Testing
@testable import PalmierPro

@Suite("Project automation")
struct ProjectAutomationTests {
    private let fm = FileManager.default

    private func root() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("project-automation-\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func strictMissingMediaLeavesExistingDestinationUntouched() throws {
        let root = try root()
        defer { try? fm.removeItem(at: root) }
        let destination = root.appendingPathComponent("Existing.palmier")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("keep.txt")
        try Data("USER EDIT".utf8).write(to: marker)
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(id: "gone", name: "Missing drawing", type: .image,
            source: .external(absolutePath: root.appendingPathComponent("gone.png").path), duration: 0)]
        #expect(throws: ToolError.self) {
            try PalmierProjectExporter.export(timeline: Fixtures.timeline(), manifest: manifest,
                generationLog: GenerationLog(), sourceProjectURL: nil,
                to: destination, overwrite: true, strictMissingMedia: true)
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "USER EDIT")
        #expect(!fm.fileExists(atPath: destination.appendingPathComponent(Project.timelineFilename).path))
    }

    @Test func explicitOverwriteIsRequiredBeforePackaging() throws {
        let root = try root()
        defer { try? fm.removeItem(at: root) }
        let destination = root.appendingPathComponent("Existing.palmier")
        try Data("USER EDIT".utf8).write(to: destination)
        #expect(throws: ToolError.self) {
            try PalmierProjectExporter.export(timeline: Fixtures.timeline(), manifest: MediaManifest(),
                generationLog: GenerationLog(), sourceProjectURL: nil,
                to: destination, overwrite: false, strictMissingMedia: true)
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "USER EDIT")
    }

    @Test func failedPromotionRestoresDestination() throws {
        let root = try root()
        defer { try? fm.removeItem(at: root) }
        let destination = root.appendingPathComponent("keep.mp4")
        try Data("USER EDIT".utf8).write(to: destination)
        #expect(throws: (any Error).self) {
            try ProjectAutomationFiles.commit(staging: root.appendingPathComponent("missing.mp4"),
                                              to: destination, overwrite: true)
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "USER EDIT")
    }

    @Test func packageRelativeSourceCannotEscapeThroughParentOrSymlink() throws {
        let root = try root()
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("Source.palmier")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.png")
        try Data("PRIVATE".utf8).write(to: outside)
        try fm.createSymbolicLink(at: source.appendingPathComponent("escape.png"), withDestinationURL: outside)
        var manifest = MediaManifest()
        manifest.entries = ["../outside.png", "escape.png"].enumerated().map { index, path in
            MediaManifestEntry(id: "escape-\(index)", name: path, type: .image,
                               source: .project(relativePath: path), duration: 0)
        }
        #expect(PalmierProjectExporter.missingMedia(in: manifest, projectURL: source).count == 2)
        let destination = root.appendingPathComponent("Out.palmier")
        #expect(throws: ToolError.self) {
            try PalmierProjectExporter.export(timeline: Fixtures.timeline(), manifest: manifest,
                generationLog: GenerationLog(), sourceProjectURL: source,
                to: destination, overwrite: false, strictMissingMedia: true)
        }
        #expect(!fm.fileExists(atPath: destination.path))
    }

    @Test func strictPackageCollectsAllSourcesAndRoundTrips() throws {
        let root = try root()
        defer { try? fm.removeItem(at: root) }
        let image = root.appendingPathComponent("panel.png")
        try Data("PANEL".utf8).write(to: image)
        let destination = root.appendingPathComponent("Portable.palmier")
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(id: "art", name: "Panel", type: .image,
            source: .external(absolutePath: image.path), duration: 0)]
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(mediaRef: "art", mediaType: .image, start: 0, duration: 90),
        ])])
        let report = try PalmierProjectExporter.export(timeline: timeline, manifest: manifest,
            generationLog: GenerationLog(), sourceProjectURL: nil, to: destination,
            overwrite: false, strictMissingMedia: true)
        #expect(report.missing.isEmpty)
        let savedTimeline = try JSONDecoder().decode(Timeline.self,
            from: Data(contentsOf: destination.appendingPathComponent(Project.timelineFilename)))
        let savedManifest = try JSONDecoder().decode(MediaManifest.self,
            from: Data(contentsOf: destination.appendingPathComponent(Project.manifestFilename)))
        #expect(savedTimeline == timeline)
        #expect(PalmierProjectExporter.missingMedia(in: savedManifest, projectURL: destination).isEmpty)
        let resolver = MediaResolver(manifest: { savedManifest }, projectURL: { destination })
        #expect(try Data(contentsOf: #require(resolver.resolveURL(for: "art"))) == Data("PANEL".utf8))
    }

    @Test func outputPathMustBeAbsoluteAndMatchFormat() throws {
        #expect(throws: ToolError.self) { try ProjectAutomationFiles.outputURL("relative.palmier", extension: "palmier") }
        #expect(throws: ToolError.self) { try ProjectAutomationFiles.outputURL("/tmp/out.mp4", extension: "palmier") }
        #expect(try ProjectAutomationFiles.outputURL("/tmp/quotes \" and spaces.palmier", extension: "palmier").path
            == "/tmp/quotes \" and spaces.palmier")
    }
}

@Suite("Image project persistence")
@MainActor
struct ImageProjectPersistenceTests {
    @Test func imageOnlyNativeSaveCompletesAndPreservesTimeline() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("image-save-\(UUID().uuidString)")
        let package = root.appendingPathComponent("Drawings.palmier")
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let image = root.appendingPathComponent("panel.png")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 48,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: image)
        let document = VideoProject()
        document.fileURL = package
        document.fileType = VideoProject.typeIdentifier
        document.editorViewModel.projectURL = package
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(mediaRef: "art", mediaType: .image, start: 0, duration: 90),
        ])])
        document.editorViewModel.timeline = timeline
        document.editorViewModel.mediaManifest.entries = [MediaManifestEntry(id: "art", name: "Panel", type: .image,
            source: .external(absolutePath: image.path), duration: 0)]
        let clock = ContinuousClock()
        let start = clock.now
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.save(to: package, ofType: VideoProject.typeIdentifier, for: .saveOperation) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        #expect(clock.now - start < .seconds(3))
        let restored = try JSONDecoder().decode(Timeline.self,
            from: Data(contentsOf: package.appendingPathComponent(Project.timelineFilename)))
        #expect(restored == timeline)
        let thumb = await ProjectThumbnailRenderer.render(url: image, type: .image, frame: 0, fps: 30)
        #expect(thumb != nil)
    }
}
