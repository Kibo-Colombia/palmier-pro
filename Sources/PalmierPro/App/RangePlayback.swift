import AppKit

/// Opens a project (reusing its window) and plays a range; shared by `koma://play` and `play_range`.
@MainActor
enum RangePlayback {
    struct Request {
        var project: String?
        var start: Double?
        var end: Double?
        var marker: String?
    }

    private static let engineWait: Duration = .seconds(15)
    private static let pollInterval: Duration = .milliseconds(100)

    static func perform(_ request: Request) async throws -> [String: Any] {
        if request.marker != nil, request.start != nil || request.end != nil {
            throw ToolError("Pass marker, or start with an optional end, not both.")
        }
        guard request.marker != nil || request.start != nil else {
            throw ToolError("Pass marker, or start (seconds) with an optional end.")
        }
        for (key, value) in [("start", request.start), ("end", request.end)] {
            if let value, !value.isFinite || value < 0 {
                throw ToolError("\(key) must be a non-negative number of seconds")
            }
        }

        let document = try openDocument(request.project)
        let editor = document.editorViewModel
        let fps = editor.timeline.fps
        let startFrame: Int
        var endFrame: Int?
        var marker: TimelineMarker?
        if let query = request.marker {
            let found = try editor.timeline.markers.resolve(query)
            marker = found
            startFrame = found.startFrame
            endFrame = found.isRange
                ? found.endFrame
                : editor.timeline.markers.map(\.startFrame).filter { $0 > found.startFrame }.min()
        } else {
            startFrame = frame(request.start ?? 0, fps: fps)
            endFrame = request.end.map { frame($0, fps: fps) }
        }
        let total = editor.timeline.totalFrames
        guard startFrame < max(total, 1) else {
            throw ToolError("start is past the end of the timeline (\(seconds(total, fps: fps)) s)")
        }
        if let end = endFrame, end <= startFrame {
            throw ToolError("end must be after start")
        }

        NSApp.activate(ignoringOtherApps: true)
        document.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
        try await waitForPlayer(editor)
        editor.playRange(startFrame: startFrame, endFrame: endFrame)

        let stop = editor.playbackStopFrame
        var receipt: [String: Any] = [
            "ok": true, "playing": editor.isPlaying,
            "path": document.fileURL?.path ?? "", "fps": fps,
            "startFrame": startFrame, "startSeconds": seconds(startFrame, fps: fps),
        ]
        if let stop {
            receipt["endFrame"] = stop
            receipt["endSeconds"] = seconds(stop, fps: fps)
        }
        if let marker {
            receipt["marker"] = ["id": marker.id, "name": marker.name]
        }
        return receipt
    }

    private static func openDocument(_ path: String?) throws -> VideoProject {
        guard let path else {
            guard let active = AppState.shared.activeProject else {
                throw ToolError("No project is open. Pass project with the .palmier path.")
            }
            return active
        }
        let url = try ProjectAutomationFiles.outputURL(path, extension: Project.fileExtension)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError("Project not found: \(url.path)")
        }
        return try AppState.shared.openProjectForAutomation(at: url)
    }

    /// A freshly opened window builds its preview engine and composition asynchronously.
    private static func waitForPlayer(_ editor: EditorViewModel) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + engineWait
        while editor.videoEngine?.player.currentItem == nil {
            guard clock.now < deadline else {
                throw ToolError("The preview didn't become ready in time. Try again once the project has loaded.")
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    private static func frame(_ seconds: Double, fps: Int) -> Int {
        Int((seconds * Double(fps)).rounded())
    }

    private static func seconds(_ frame: Int, fps: Int) -> Double {
        frameToSeconds(frame: frame, fps: fps).rounded(toPlaces: 3)
    }
}
