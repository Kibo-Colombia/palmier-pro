import Foundation

/// Tool names for the home-screen agent. These operate on the cross-project Library (footage from
/// user-added roots, understood in place) and Spaces (saved, non-destructive groupings) — never on
/// a project timeline. Whole files for V1; a Space is the home analog of the editor's folders.
enum LibraryToolName: String, CaseIterable, Sendable {
    case listLibrary = "list_library"
    case searchLibrary = "search_library"
    case listSpaces = "list_spaces"
    case createSpace = "create_space"
    case addToSpace = "add_to_space"
    case removeFromSpace = "remove_from_space"
    case renameSpace = "rename_space"
    case removeSpace = "remove_space"
}

enum LibraryToolDefinitions {
    static let all: [AnthropicToolSchema] = [
        schema(
            .listLibrary,
            "Lists the Library: every root folder, every video file in it (with on-device label tokens like 'set:night'), and indexing progress. Call this first. If indexing.isIndexing is true, labels are still filling in.",
            obj()
        ),
        schema(
            .searchLibrary,
            "Finds Library files by filename substring and/or label tokens. Both filters are ANDed; omit one to ignore it. Use before listing everything when you know what you want.",
            obj(properties: [
                "query": ["type": "string", "description": "Case-insensitive filename substring."],
                "labels": ["type": "array", "items": ["type": "string"], "description": "Label tokens to require, e.g. ['night', 'set:beach']. A file matches a token if any of its labels contains it."],
                "limit": ["type": "integer", "description": "Max matches to return (default 50)."],
            ])
        ),
        schema(
            .listSpaces,
            "Lists existing Spaces as {id, name, itemCount}. Use the id with the other Space tools.",
            obj()
        ),
        schema(
            .createSpace,
            "Creates a new empty Space and returns its id. A Space is a named, non-destructive grouping — the home analog of a folder. Don't create many tiny Spaces; prefer a few meaningful ones.",
            obj(properties: [
                "name": ["type": "string", "description": "Space name."],
            ], required: ["name"])
        ),
        schema(
            .addToSpace,
            "Adds Library files to a Space by their file paths (from list_library/search_library). De-duplicates. Paths outside every root are skipped and reported. Never moves or copies the footage.",
            obj(properties: [
                "spaceId": ["type": "string", "description": "Target Space id from list_spaces or create_space."],
                "filePaths": ["type": "array", "items": ["type": "string"], "description": "Absolute file paths to add."],
            ], required: ["spaceId", "filePaths"])
        ),
        schema(
            .removeFromSpace,
            "Removes Library files from a Space by their file paths. Leaves the footage untouched.",
            obj(properties: [
                "spaceId": ["type": "string", "description": "Target Space id."],
                "filePaths": ["type": "array", "items": ["type": "string"], "description": "Absolute file paths to remove."],
            ], required: ["spaceId", "filePaths"])
        ),
        schema(
            .renameSpace,
            "Renames a Space.",
            obj(properties: [
                "spaceId": ["type": "string", "description": "Space id."],
                "name": ["type": "string", "description": "New name."],
            ], required: ["spaceId", "name"])
        ),
        schema(
            .removeSpace,
            "Deletes a Space (the grouping only — the underlying footage is never touched). Confirm intent before calling.",
            obj(properties: [
                "spaceId": ["type": "string", "description": "Space id to delete."],
            ], required: ["spaceId"])
        ),
    ]

    private static func schema(_ name: LibraryToolName, _ description: String, _ inputSchema: [String: Any]) -> AnthropicToolSchema {
        AnthropicToolSchema(name: name.rawValue, description: description, inputSchema: inputSchema)
    }

    private static func obj(
        properties: [String: [String: Any]] = [:],
        required: [String] = []
    ) -> [String: Any] {
        var dict: [String: Any] = ["type": "object"]
        if !properties.isEmpty { dict["properties"] = properties }
        if !required.isEmpty { dict["required"] = required }
        return dict
    }
}
