import Foundation

/// Tool names for the home-screen agent. These operate on the cross-project Library (footage from
/// user-added roots, understood in place) and Spaces (saved, non-destructive groupings) — never on
/// a project timeline. Whole files for V1; a Space is the home analog of the editor's folders.
enum LibraryToolName: String, CaseIterable, Sendable {
    case listLibrary = "list_library"
    case searchLibrary = "search_library"
    case getTranscript = "get_transcript"
    case setSummary = "set_summary"
    case listSpaces = "list_spaces"
    case createSpace = "create_space"
    case addToSpace = "add_to_space"
    case removeFromSpace = "remove_from_space"
    case renameSpace = "rename_space"
    case removeSpace = "remove_space"
    case listFolder = "list_folder"
    case createFolder = "create_folder"
    case moveFile = "move_file"
    case renameFile = "rename_file"
}

enum LibraryToolDefinitions {
    static let all: [AnthropicToolSchema] = [
        schema(
            .listLibrary,
            "Lists the Library and what's understood about it. Each file carries: on-device visual label tokens (e.g. 'set:night'); seen (true once visually indexed); said ('speech' = transcribed spoken words, 'silent' = no audio/no speech, 'pending' = not transcribed yet); plus spoken (a transcript preview) and lang (auto-detected per clip, e.g. 'es' or 'en') when there is speech; plus summary (the caption shown in the file's (i) popover) and summaryTier (0 = local gist, 1 = AI-written) when one exists. Top-level 'understanding' counts seen/labeled/heardSpeech/silent/saidPending across the whole Library, and 'indexing' reports the live pass (phase 'seeing' = visual, 'hearing' = transcribing). Call this first. While indexing.isIndexing is true, seen/said are still filling in.",
            obj()
        ),
        schema(
            .searchLibrary,
            "Finds Library files by filename OR spoken words (query), label tokens, and/or transcription state. All provided filters are ANDed. Use 'query' to match both the filename and what is said in the clip; use 'said' to narrow to transcribed/silent/not-yet clips. Results include said, summary/summaryTier when one exists, and spoken/lang when there is speech.",
            obj(properties: [
                "query": ["type": "string", "description": "Case-insensitive substring matched against BOTH the filename and the spoken transcript."],
                "labels": ["type": "array", "items": ["type": "string"], "description": "Label tokens to require, e.g. ['night', 'set:beach']. A file matches a token if any of its labels contains it."],
                "said": ["type": "string", "enum": ["speech", "silent", "pending"], "description": "Filter by transcription state: 'speech' = has spoken words, 'silent' = no audio/no speech, 'pending' = not transcribed yet."],
                "limit": ["type": "integer", "description": "Max matches to return (default 50)."],
            ])
        ),
        schema(
            .getTranscript,
            "Returns the FULL on-device transcript text for the given Library files — list_library/search_library only include a short 'spoken' preview. Use this before set_summary so a summary reflects everything that's said. Passive read: files with no cached transcript yet come back as said='pending' (let the background indexer's 'hearing' pass finish); this never triggers transcription itself.",
            obj(properties: [
                "paths": ["type": "array", "items": ["type": "string"], "description": "Absolute file paths (from list_library/search_library)."],
            ], required: ["paths"])
        ),
        schema(
            .setSummary,
            "Saves the AI summary shown in a Library file's (i) popover — for one or many files. Use this to persist summaries written by THIS assistant (on the user's own Claude plan) instead of the app's paid in-app model: read each clip's transcript (get_transcript) and labels (list_library), write a concrete one- or two-sentence, present-tense description of what the clip is about (≤240 chars, no quotes/markdown), and save it here. Stored as an AI ('sparkles', tier 1) summary that persists across launches and replaces any prior one. Re-indexing or (re)transcribing a file invalidates its summary by design, so summarize after indexing settles.",
            obj(properties: [
                "summaries": ["type": "array", "description": "One entry per file.", "items": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute file path (from list_library/search_library)."],
                        "summary": ["type": "string", "description": "The caption: one or two concrete present-tense sentences, ≤240 chars, no quotes or markdown."],
                    ],
                    "required": ["path", "summary"],
                ]],
            ], required: ["summaries"])
        ),
        schema(
            .listSpaces,
            "Lists existing Spaces as {id, name, itemCount, labelFilter?, linkedProject?}. labelFilter is the Space's saved-search tokens; linkedProject is the name of the editor project it spun off, when one exists. Use the id with the other Space tools.",
            obj()
        ),
        schema(
            .createSpace,
            "Creates a new empty Space and returns its id. A Space is a SAVED VIEW of the library — never a folder; adding footage to one moves nothing on disk. Don't create many tiny Spaces; prefer a few meaningful ones. Optionally give it a labelFilter so it also live-matches every library file carrying those label tokens (a label is a saved search).",
            obj(properties: [
                "name": ["type": "string", "description": "Space name."],
                "labelFilter": ["type": "array", "items": ["type": "string"], "description": "Optional label tokens (e.g. ['set:night']) the Space live-matches in addition to manually added moments."],
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
        schema(
            .listFolder,
            "Lists a folder's contents — ANY file type, not just video (this is how you see .m4a, .LRF proxies, project scratch, etc.). Each entry: {name, path, kind: file|folder, sizeBytes, modified, isVideo, indexed (visually understood)}. Scope: library roots and ~/Movies only. Use together with list_library when proposing how to physically organize footage.",
            obj(properties: [
                "path": ["type": "string", "description": "Absolute folder path (under a library root or ~/Movies)."],
                "depth": ["type": "integer", "description": "How many levels to descend (default 1 = just this folder)."],
            ], required: ["path"])
        ),
        schema(
            .createFolder,
            "Creates a folder (with intermediate folders) under a library root or ~/Movies.",
            obj(properties: [
                "path": ["type": "string", "description": "Absolute folder path to create."],
            ], required: ["path"])
        ),
        schema(
            .moveFile,
            "Moves files on disk — the ONLY tool that physically reorganizes footage. Content-based identity means a moved file keeps ALL its understanding (labels, transcript, summaries) and its Space memberships are repaired automatically. Safety: never overwrites, never deletes, both ends must be under a library root or ~/Movies. ALWAYS run with dryRun:true first, show the user the plan, and only execute after they confirm. Batch related moves into one call. Remember: a DJI .MP4 has a matching .LRF proxy — move them together.",
            obj(properties: [
                "moves": ["type": "array", "description": "One entry per file.", "items": [
                    "type": "object",
                    "properties": [
                        "source": ["type": "string", "description": "Absolute path of the file to move."],
                        "destination": ["type": "string", "description": "Absolute target path INCLUDING the filename. Parent folders are created as needed."],
                    ],
                    "required": ["source", "destination"],
                ]],
                "dryRun": ["type": "boolean", "description": "true = validate and report what would happen without touching the disk (default false)."],
            ], required: ["moves"])
        ),
        schema(
            .renameFile,
            "Renames a file in place (a rename is a move). Same identity guarantees and safety rails as move_file. Files whose names already carry a date (DJI_YYYYMMDD…, timestamped phone clips) should usually keep them.",
            obj(properties: [
                "path": ["type": "string", "description": "Absolute path of the file to rename."],
                "newName": ["type": "string", "description": "New filename (with extension), no directory components."],
            ], required: ["path", "newName"])
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
