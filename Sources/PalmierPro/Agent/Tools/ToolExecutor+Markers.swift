import Foundation

extension ToolExecutor {
    private static let addMarkersAllowedKeys: Set<String> = ["markers", "expectedRevision"]
    private static let markerSpecAllowedKeys: Set<String> = ["id", "name", "color", "startFrame", "durationFrames", "endFrame", "note"]
    private static let updateMarkerAllowedKeys: Set<String> = ["marker", "name", "color", "startFrame", "durationFrames", "endFrame", "note", "expectedRevision"]
    private static let removeMarkersAllowedKeys: Set<String> = ["markers", "all", "expectedRevision"]
    private static let playRangeAllowedKeys: Set<String> = ["project", "start", "end", "marker"]
    private static let markerNameMaxLength = 200

    func addMarkers(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.addMarkersAllowedKeys, path: "add_markers")
        try checkProjectRevision(editor, expected: args.string("expectedRevision"))
        guard let specs = args["markers"] as? [[String: Any]], !specs.isEmpty else {
            throw ToolError("add_markers: markers must be a non-empty array of objects")
        }
        var markers = editor.timeline.markers
        var ids = Set(markers.map(\.id))
        var added: [TimelineMarker] = []
        for (i, spec) in specs.enumerated() {
            let path = "markers[\(i)]"
            try validateUnknownKeys(spec, allowed: Self.markerSpecAllowedKeys, path: path)
            guard let start = spec.int("startFrame"), start >= 0 else {
                throw ToolError("\(path): startFrame must be an integer >= 0")
            }
            var marker = TimelineMarker(
                name: try Self.markerName(spec["name"], path: path),
                color: try Self.markerColor(spec["color"], path: path) ?? .blue,
                startFrame: start,
                durationFrames: try Self.markerDuration(spec, start: start, path: path) ?? 0,
                note: spec.string("note")
            )
            if let raw = spec["id"] {
                guard let id = raw as? String, !id.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw ToolError("\(path): id must be a non-empty string")
                }
                marker.id = id
            }
            guard ids.insert(marker.id).inserted else {
                throw ToolError("\(path): a marker with id '\(marker.id)' already exists")
            }
            added.append(marker)
        }
        markers.append(contentsOf: added)
        editor.replaceMarkers(Self.sortedMarkers(markers), actionName: added.count == 1 ? "Add Marker" : "Add Markers")
        let fps = editor.timeline.fps
        return try Self.markerReceipt(["ok": true, "added": added.map { Self.markerObject($0, fps: fps) }, "revision": editor.editRevision])
    }

    func listMarkers(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: [], path: "list_markers")
        let fps = editor.timeline.fps
        return try Self.markerReceipt([
            "fps": fps, "count": editor.timeline.markers.count,
            "markers": editor.timeline.markers.map { Self.markerObject($0, fps: fps) },
        ])
    }

    func updateMarker(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.updateMarkerAllowedKeys, path: "update_marker")
        try checkProjectRevision(editor, expected: args.string("expectedRevision"))
        guard let query = args["marker"] as? String else { throw ToolError("update_marker: marker is required") }
        var marker = try editor.timeline.markers.resolve(query)
        let id = marker.id
        if args["name"] != nil { marker.name = try Self.markerName(args["name"], path: "update_marker") }
        if let color = try Self.markerColor(args["color"], path: "update_marker") { marker.color = color }
        if args["startFrame"] != nil {
            guard let start = args.int("startFrame"), start >= 0 else {
                throw ToolError("update_marker: startFrame must be an integer >= 0")
            }
            marker.startFrame = start
        }
        if let duration = try Self.markerDuration(args, start: marker.startFrame, path: "update_marker") {
            marker.durationFrames = duration
        }
        if args["note"] != nil {
            guard let note = args["note"] as? String else { throw ToolError("update_marker: note must be a string") }
            marker.note = note.isEmpty ? nil : note
        }
        let markers = editor.timeline.markers.map { $0.id == id ? marker : $0 }
        editor.replaceMarkers(Self.sortedMarkers(markers), actionName: "Edit Marker")
        return try Self.markerReceipt(["ok": true, "marker": Self.markerObject(marker, fps: editor.timeline.fps), "revision": editor.editRevision])
    }

    func removeMarkers(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.removeMarkersAllowedKeys, path: "remove_markers")
        try checkProjectRevision(editor, expected: args.string("expectedRevision"))
        let all = args.bool("all") ?? false
        let queries = args.stringArray("markers")
        guard all != !queries.isEmpty else {
            throw ToolError("remove_markers: pass markers (ids or names) or all=true")
        }
        let removed = all ? editor.timeline.markers : try queries.map { try editor.timeline.markers.resolve($0) }
        let removedIds = Set(removed.map(\.id))
        let remaining = editor.timeline.markers.filter { !removedIds.contains($0.id) }
        editor.replaceMarkers(remaining, actionName: removedIds.count == 1 ? "Remove Marker" : "Remove Markers")
        return try Self.markerReceipt([
            "ok": true, "removed": removed.map { ["id": $0.id, "name": $0.name] },
            "remaining": remaining.count, "revision": editor.editRevision,
        ])
    }

    func playRange(_ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.playRangeAllowedKeys, path: "play_range")
        for key in ["start", "end"] where args[key] != nil && args.double(key) == nil {
            throw ToolError("play_range: \(key) must be a number of seconds")
        }
        if args["project"] != nil, args.string("project") == nil {
            throw ToolError("play_range: project must be an absolute .palmier path")
        }
        let request = RangePlayback.Request(
            project: args.string("project"),
            start: args.double("start"),
            end: args.double("end"),
            marker: args.string("marker")
        )
        return try Self.markerReceipt(try await RangePlayback.perform(request))
    }

    nonisolated static func markerObject(_ marker: TimelineMarker, fps: Int) -> [String: Any] {
        var object: [String: Any] = [
            "id": marker.id, "name": marker.name, "color": marker.color.rawValue,
            "startFrame": marker.startFrame, "durationFrames": marker.durationFrames, "endFrame": marker.endFrame,
            "startSeconds": frameToSeconds(frame: marker.startFrame, fps: fps).rounded(toPlaces: 3),
            "endSeconds": frameToSeconds(frame: marker.endFrame, fps: fps).rounded(toPlaces: 3),
        ]
        if let note = marker.note { object["note"] = note }
        return object
    }

    private static func sortedMarkers(_ markers: [TimelineMarker]) -> [TimelineMarker] {
        markers.enumerated().sorted {
            $0.element.startFrame != $1.element.startFrame ? $0.element.startFrame < $1.element.startFrame : $0.offset < $1.offset
        }.map(\.element)
    }

    private static func markerName(_ raw: Any?, path: String) throws -> String {
        guard let name = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw ToolError("\(path): name must be a non-empty string")
        }
        guard name.count <= markerNameMaxLength else {
            throw ToolError("\(path): name must be at most \(markerNameMaxLength) characters")
        }
        return name
    }

    private static func markerColor(_ raw: Any?, path: String) throws -> MarkerColor? {
        guard let raw else { return nil }
        guard let string = raw as? String, let color = MarkerColor(rawValue: string.lowercased()) else {
            throw ToolError("\(path): color must be one of \(MarkerColor.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return color
    }

    /// nil when neither durationFrames nor endFrame is given.
    private static func markerDuration(_ args: [String: Any], start: Int, path: String) throws -> Int? {
        switch (args["durationFrames"], args["endFrame"]) {
        case (nil, nil):
            return nil
        case (.some, .some):
            throw ToolError("\(path): pass durationFrames or endFrame, not both")
        case (.some, nil):
            guard let duration = args.int("durationFrames"), duration >= 0 else {
                throw ToolError("\(path): durationFrames must be an integer >= 0")
            }
            return duration
        case (nil, .some):
            guard let end = args.int("endFrame"), end > start else {
                throw ToolError("\(path): endFrame must be an integer after startFrame")
            }
            return end - start
        }
    }

    private static func markerReceipt(_ object: [String: Any]) throws -> ToolResult {
        guard let json = jsonString(object) else { throw ToolError("Failed to encode markers") }
        return .ok(json)
    }
}
