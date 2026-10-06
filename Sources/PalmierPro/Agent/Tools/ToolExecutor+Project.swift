import AppKit
import Foundation

extension ToolExecutor {
    func createProject(_ args: [String: Any]) async throws -> ToolResult {
        let input: CreateProjectArgs = try decodeToolArgs(args, path: "create_project")
        let url = try ProjectAutomationFiles.outputURL(input.path, extension: Project.fileExtension)
        try rejectOpenDestination(url)
        var timeline = Timeline()
        timeline.width = input.width ?? 1920
        timeline.height = input.height ?? 1080
        timeline.fps = input.fps ?? 30
        guard (16...8192).contains(timeline.width), (16...8192).contains(timeline.height),
              (1...240).contains(timeline.fps) else {
            throw ToolError("width and height must be 16...8192; fps must be 1...240")
        }
        timeline.settingsConfigured = true
        try PalmierProjectExporter.export(timeline: timeline, manifest: MediaManifest(),
                                          generationLog: GenerationLog(), sourceProjectURL: nil,
                                          to: url, overwrite: input.overwrite ?? false,
                                          strictMissingMedia: true)
        let document = try AppState.shared.openProjectForAutomation(at: url)
        return projectReceipt(document)
    }

    func openProject(_ args: [String: Any]) async throws -> ToolResult {
        let input: OpenProjectArgs = try decodeToolArgs(args, path: "open_project")
        let url = try ProjectAutomationFiles.outputURL(input.path, extension: Project.fileExtension)
        let document = try AppState.shared.openProjectForAutomation(at: url)
        return projectReceipt(document)
    }

    func saveProject(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: SaveProjectArgs = try decodeToolArgs(args, path: "save_project")
        let document = try activeDocument(editor, projectId: input.projectId)
        try checkProjectRevision(editor, expected: input.expectedRevision)
        let requestedRevision = editor.editRevision
        try await AppState.shared.saveProjectForAutomation(document)
        guard let url = document.fileURL else { throw ToolError("Saved project has no file path") }
        let savedTimeline = try JSONDecoder().decode(Timeline.self,
            from: Data(contentsOf: url.appendingPathComponent(Project.timelineFilename)))
        let savedManifest = try JSONDecoder().decode(MediaManifest.self,
            from: Data(contentsOf: url.appendingPathComponent(Project.manifestFilename)))
        let savedRevision = try TimelineEditPlanner.revision(timeline: savedTimeline, manifest: savedManifest)
        var receipt = projectReceiptObject(document)
        receipt["savedRevision"] = savedRevision
        receipt["requestedRevision"] = requestedRevision
        receipt["currentRevision"] = editor.editRevision
        return .ok(Self.jsonString(receipt)!)
    }

    func exportProjectPackage(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: PackageProjectArgs = try decodeToolArgs(args, path: "export_project_package")
        _ = try activeDocument(editor, projectId: input.projectId)
        try checkProjectRevision(editor, expected: input.expectedRevision)
        let destination = try ProjectAutomationFiles.outputURL(input.path, extension: Project.fileExtension)
        try rejectOpenDestination(destination)
        let timeline = editor.timeline
        let manifest = editor.mediaManifest
        let log = editor.generationLog
        let sourceURL = editor.projectURL
        let sourceRevision = editor.editRevision
        let overwrite = input.overwrite ?? false
        let strict = input.strictMissingMedia ?? true
        let report = try await Task.detached(priority: .userInitiated) {
            try PalmierProjectExporter.export(timeline: timeline, manifest: manifest,
                                              generationLog: log, sourceProjectURL: sourceURL,
                                              to: destination, overwrite: overwrite,
                                              strictMissingMedia: strict)
        }.value
        let object: [String: Any] = [
            "ok": true, "path": destination.path, "sourceRevision": sourceRevision,
            "collected": report.collected, "copiedInternal": report.copiedInternal,
            "totalBytes": report.totalBytes,
            "missingMedia": report.missing.map { ["id": $0.id, "name": $0.name] },
        ]
        return .ok(Self.jsonString(object)!)
    }

    func checkProjectRevision(_ editor: EditorViewModel, expected: String?) throws {
        if let expected, expected != editor.editRevision {
            throw ToolError("Revision conflict. Read the current project before saving or exporting.")
        }
    }

    private func activeDocument(_ editor: EditorViewModel, projectId: String?) throws -> VideoProject {
        guard let document = AppState.shared.activeProject, document.editorViewModel === editor else {
            throw ToolError("The editor is not the active saved project")
        }
        if let projectId, projectId != automationProjectId(document) {
            throw ToolError("Project conflict. The active project has changed.")
        }
        return document
    }

    private func rejectOpenDestination(_ url: URL) throws {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        if NSDocumentController.shared.documents.compactMap({ $0 as? VideoProject })
            .contains(where: { $0.fileURL?.standardizedFileURL.resolvingSymlinksInPath() == resolved }) {
            throw ToolError("Destination is an open project. Save it or choose another path.")
        }
    }

    private func automationProjectId(_ document: VideoProject) -> String {
        document.editorViewModel.projectId ?? document.fileURL.flatMap { url in
            ProjectRegistry.shared.entries.first { $0.url.standardizedFileURL == url.standardizedFileURL }?.id.uuidString
        } ?? document.fileURL?.standardizedFileURL.path ?? document.displayName
    }

    private func projectReceiptObject(_ document: VideoProject) -> [String: Any] {
        let editor = document.editorViewModel
        let missing = PalmierProjectExporter.missingMedia(in: editor.mediaManifest, projectURL: editor.projectURL)
        return [
            "ok": true, "ready": missing.isEmpty, "documentReady": true, "mediaReady": missing.isEmpty,
            "projectId": automationProjectId(document),
            "name": document.displayName ?? Project.defaultProjectName,
            "path": document.fileURL?.path ?? "", "revision": editor.editRevision,
            "width": editor.timeline.width, "height": editor.timeline.height, "fps": editor.timeline.fps,
            "totalFrames": editor.timeline.totalFrames, "tracks": editor.timeline.tracks.count,
            "clips": editor.timeline.tracks.reduce(0) { $0 + $1.clips.count },
            "media": editor.mediaManifest.entries.count, "isDocumentEdited": document.isDocumentEdited,
            "missingMedia": missing.map { ["id": $0.id, "name": $0.name] },
        ]
    }

    private func projectReceipt(_ document: VideoProject) -> ToolResult {
        .ok(Self.jsonString(projectReceiptObject(document))!)
    }
}

private struct CreateProjectArgs: DecodableToolArgs {
    static let allowedKeys: Set<String> = ["path", "width", "height", "fps", "overwrite"]
    let path: String
    let width: Int?
    let height: Int?
    let fps: Int?
    let overwrite: Bool?
}

private struct OpenProjectArgs: DecodableToolArgs {
    static let allowedKeys: Set<String> = ["path"]
    let path: String
}

private struct SaveProjectArgs: DecodableToolArgs {
    static let allowedKeys: Set<String> = ["projectId", "expectedRevision"]
    let projectId: String?
    let expectedRevision: String?
}

private struct PackageProjectArgs: DecodableToolArgs {
    static let allowedKeys: Set<String> = ["path", "projectId", "expectedRevision", "overwrite", "strictMissingMedia"]
    let path: String
    let projectId: String?
    let expectedRevision: String?
    let overwrite: Bool?
    let strictMissingMedia: Bool?
}
