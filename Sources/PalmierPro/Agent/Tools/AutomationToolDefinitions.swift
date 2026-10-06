import Foundation

enum AutomationToolDefinitions {
    private static var revision: [String: Any] { [
        "type": "string", "description": "Exact revision from get_timeline; rejects intervening human or agent edits."
    ] }
    private static var path: [String: Any] { ["type": "string", "description": "Absolute destination path."] }
    private static var identifier: [String: Any] { ["type": "string"] }
    private static var flag: [String: Any] { ["type": "boolean"] }
    private static var frame: [String: Any] { ["type": "integer", "minimum": 0] }
    private static var duration: [String: Any] { ["type": "integer", "minimum": 1] }

    static let all: [AgentTool] = [
        tool(.getCapabilities, "Discover the running build, API version, schema fingerprint, supported tools and explicit audio units. Works without an open project."),
        tool(.createProject, "Create, save and open an empty .palmier project without a dialog. Existing paths are rejected unless overwrite is explicit.", [
            "path": path, "width": ["type": "integer", "minimum": 16, "maximum": 8192],
            "height": ["type": "integer", "minimum": 16, "maximum": 8192],
            "fps": ["type": "integer", "minimum": 1, "maximum": 240], "overwrite": flag
        ], required: ["path"]),
        tool(.openProject, "Open a .palmier project without a dialog. Returns its identity, loaded media readiness and revision.", ["path": path], required: ["path"]),
        tool(.saveProject, "Save the current native project without a dialog. Use projectId and expectedRevision to guard the target. Returns a confirmed on-disk receipt.", [
            "projectId": identifier, "expectedRevision": revision
        ]),
        tool(.exportProjectPackage, "Write a portable .palmier copy with bundled media. Strict missing-media validation is enabled by default; original project remains open.", [
            "path": path, "projectId": identifier, "expectedRevision": revision,
            "overwrite": flag, "strictMissingMedia": flag
        ], required: ["path"]),
        tool(.startExport, "Start an asynchronous native video export of a frozen project revision. Returns a jobId immediately. Reuse idempotencyKey only with the identical request; poll get_export_job for progress and a verified completion receipt.", [
            "path": path, "format": ["type": "string", "enum": ["h264", "h265", "prores"]],
            "resolution": ["type": "string", "enum": ["720p", "1080p", "4K"]],
            "overwrite": flag, "expectedRevision": revision, "idempotencyKey": identifier
        ], required: ["path"]),
        tool(.getExportJob, "Read export progress or its completion/failure receipt. Saved jobs interrupted by an app restart are reported explicitly.", ["jobId": identifier], required: ["jobId"]),
        tool(.cancelExport, "Cancel an export job and report its resulting state.", ["jobId": identifier], required: ["jobId"]),
        tool(.applyEdit, "Validate an entire edit before committing it once: one undo, one composition rebuild, no partial changes. Stable UUIDs identify clips/tracks. expectedRevision protects human edits; operationId makes an identical retry safe. dryRun returns the planned diff without changing the project. Collisions reject by default; overwrite is explicit. resize_beat stretches picture/text holds, preserves short sound lengths and ripples only the declared tracks.", [
            "expectedRevision": revision, "projectId": identifier, "operationId": identifier, "dryRun": flag,
            "collisionPolicy": ["type": "string", "enum": ["reject", "overwrite"]],
            "operations": ["type": "array", "minItems": 1, "items": ["oneOf": operationSchemas]]
        ], required: ["expectedRevision", "operationId", "operations"]),
        tool(.setTrackProperties, "Set a track's mute, visibility or sync lock using its stable UUID, without changing clip gain or volume automation. Uses the same revision and retry guards as apply_edit.", [
            "trackId": identifier, "muted": flag, "hidden": flag, "syncLocked": flag,
            "expectedRevision": revision, "projectId": identifier, "operationId": identifier, "dryRun": flag
        ], required: ["trackId", "expectedRevision", "operationId"])
    ]

    private static var operationSchemas: [[String: Any]] {
        [
            operation("move_clip", ["clipId": identifier, "trackId": identifier, "startFrame": frame], required: ["clipId"]),
            operation("resize_clip", ["clipId": identifier, "durationFrames": duration], required: ["clipId", "durationFrames"]),
            operation("set_clip", [
                "clipId": identifier, "volume": ["type": "number", "minimum": 0, "maximum": 1],
                "opacity": ["type": "number", "minimum": 0, "maximum": 1],
                "fadeInFrames": frame, "fadeOutFrames": frame, "clearVolumeAutomation": flag,
                "transform": schema([
                    "centerX": ["type": "number"], "centerY": ["type": "number"],
                    "width": ["type": "number", "exclusiveMinimum": 0], "height": ["type": "number", "exclusiveMinimum": 0],
                    "flipHorizontal": flag, "flipVertical": flag
                ], required: [])
            ], required: ["clipId"]),
            operation("set_track", ["trackId": identifier, "muted": flag, "hidden": flag, "syncLocked": flag], required: ["trackId"]),
            operation("remove_clip", ["clipId": identifier], required: ["clipId"]),
            operation("resize_beat", [
                "startFrame": frame, "endFrame": frame, "durationFrames": duration,
                "clips": ["type": "array", "items": schema([
                    "clipId": identifier, "role": ["type": "string", "enum": ["hold", "sound_start", "sound_end", "span"]]
                ], required: ["clipId", "role"])],
                "rippleTrackIds": ["type": "array", "items": identifier]
            ], required: ["startFrame", "endFrame", "durationFrames", "clips", "rippleTrackIds"])
        ]
    }

    private static func operation(_ name: String, _ properties: [String: [String: Any]], required: [String]) -> [String: Any] {
        var properties = properties
        properties["type"] = ["type": "string", "enum": [name]]
        return schema(properties, required: ["type"] + required)
    }

    private static func tool(_ name: ToolName, _ description: String, _ properties: [String: [String: Any]] = [:], required: [String] = []) -> AgentTool {
        AgentTool(name: name, description: description, inputSchema: schema(properties, required: required))
    }

    private static func schema(_ properties: [String: [String: Any]], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
}
