import Foundation

enum MarkerToolDefinitions {
    private static var revision: [String: Any] { [
        "type": "string", "description": "Optional. Exact revision from get_timeline; rejects intervening edits."
    ] }
    private static var color: [String: Any] { [
        "type": "string", "enum": MarkerColor.allCases.map(\.rawValue), "description": "Resolve's marker colors. Default blue."
    ] }
    private static var markerQuery: [String: Any] { [
        "type": "string",
        "description": "Marker id, or its name: exact (case-insensitive), or a unique prefix ending at a word boundary ('HOOK 2' finds 'HOOK 2 · The tiny clock')."
    ] }
    private static var frame: [String: Any] { ["type": "integer", "minimum": 0] }

    private static var markerSpec: [String: Any] {
        schema([
            "id": ["type": "string", "description": "Optional stable id (e.g. 'hook-2'); must be unique. Generated when omitted."],
            "name": ["type": "string", "description": "Shown on the ruler, e.g. 'HOOK 1 · Three pulls'."],
            "color": color,
            "startFrame": frame,
            "durationFrames": ["type": "integer", "minimum": 0, "description": "0 (default) is a point marker; longer is a range."],
            "endFrame": ["type": "integer", "minimum": 1, "description": "Exclusive range end; alternative to durationFrames."],
            "note": ["type": "string"],
        ], required: ["name", "startFrame"])
    }

    static let all: [AgentTool] = [
        tool(.addMarkers, "Add named timeline markers, like DaVinci Resolve's: a point, or a range when durationFrames/endFrame is set. They draw as colored named blocks on the ruler, persist in the project, and people click them to jump there. Use one range per section (each hook, chapter or beat) so it reads at a glance. One undo for the batch. Returns the created markers with frames and seconds.", [
            "markers": ["type": "array", "minItems": 1, "items": markerSpec],
            "expectedRevision": revision,
        ], required: ["markers"]),
        tool(.listMarkers, "List the timeline's markers in start order, with frames and seconds. get_timeline includes the same list."),
        tool(.updateMarker, "Rename, recolor, move or resize one marker. Send only the fields to change; note '' clears the note.", [
            "marker": markerQuery,
            "name": ["type": "string"], "color": color, "startFrame": frame,
            "durationFrames": ["type": "integer", "minimum": 0],
            "endFrame": ["type": "integer", "minimum": 1, "description": "Exclusive range end; alternative to durationFrames."],
            "note": ["type": "string"],
            "expectedRevision": revision,
        ], required: ["marker"]),
        tool(.removeMarkers, "Remove markers by id or name, or all of them with all=true. One undo.", [
            "markers": ["type": "array", "items": markerQuery],
            "all": ["type": "boolean"],
            "expectedRevision": revision,
        ]),
        tool(.playRange, "Open a project (or reuse its window) and play exactly a range in the preview, stopping at end. Pass marker, or start with an optional end. A range marker plays its range; a point marker plays until the next marker. Mirrors the koma://play URL. Works without an open project when project is set.", [
            "project": ["type": "string", "description": "Absolute .palmier path. Omit to use the active project."],
            "start": ["type": "number", "minimum": 0, "description": "Seconds."],
            "end": ["type": "number", "minimum": 0, "description": "Seconds, exclusive. Omit to play to the end."],
            "marker": markerQuery,
        ]),
    ]

    private static func tool(_ name: ToolName, _ description: String, _ properties: [String: [String: Any]] = [:], required: [String] = []) -> AgentTool {
        AgentTool(name: name, description: description, inputSchema: schema(properties, required: required))
    }

    private static func schema(_ properties: [String: [String: Any]], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
}
