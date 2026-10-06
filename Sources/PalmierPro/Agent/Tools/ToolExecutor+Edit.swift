import Foundation

extension ToolExecutor {
    func applyEdit(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let request: TimelineEditRequest = try decodeToolArgs(args, path: "apply_edit")
        try TimelineEditPlanner.validateShapes(args)
        if let projectId = request.projectId, projectId != editor.projectId {
            throw ToolError("Project conflict: requested \(projectId), current \(editor.projectId ?? "unsaved")")
        }
        guard !request.operationId.isEmpty else { throw ToolError("operationId must not be empty") }
        let payload = try JSONSerialization.data(withJSONObject: args.filter { $0.key != "dryRun" }, options: [.sortedKeys])
        let payloadHash = TimelineEditPlanner.hash(payload)
        let receiptKey = (editor.projectURL?.standardizedFileURL.path ?? "unsaved") + ":" + request.operationId
        if let receipt = editor.editReceipts[receiptKey] {
            guard receipt.payloadHash == payloadHash else { throw ToolError("operationId has already been used for a different edit") }
            if request.dryRun != true { return .ok(receipt.resultJSON) }
        }
        let currentRevision = editor.editRevision
        guard request.expectedRevision == currentRevision else {
            throw ToolError("Revision conflict: expected \(request.expectedRevision), current \(currentRevision). Read get_timeline before editing.")
        }
        let plan = try TimelineEditPlanner.plan(timeline: editor.timeline, operations: request.operations, collisionPolicy: request.collisionPolicy ?? "reject")
        try TimelineEditPlanner.validateSourceBounds(plan, assets: editor.mediaAssets, fps: editor.timeline.fps)
        let nextRevision = try TimelineEditPlanner.revision(timeline: plan.timeline, manifest: editor.mediaManifest)
        struct Receipt: Encodable {
            let ok: Bool
            let projectId: String?
            let operationId: String
            let dryRun: Bool
            let previousRevision: String
            let revision: String
            let totalFrames: Int
            let clipChanges: [ClipEditChange]
            let trackChanges: [TrackEditChange]
        }
        let receipt = Receipt(ok: true, projectId: editor.projectId, operationId: request.operationId, dryRun: request.dryRun == true, previousRevision: currentRevision, revision: nextRevision, totalFrames: plan.timeline.totalFrames, clipChanges: plan.clipChanges, trackChanges: plan.trackChanges)
        let resultJSON = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        if request.dryRun != true {
            if plan.timeline != editor.timeline {
                withUndoGroup(editor, actionName: "Edit Timeline (Agent)") {
                    editor.withTimelineSwap(actionName: "Edit Timeline (Agent)") { editor.timeline = plan.timeline }
                }
            }
            editor.editReceipts[receiptKey] = TimelineEditReceipt(payloadHash: payloadHash, resultJSON: resultJSON)
        }
        return .ok(resultJSON)
    }

    func setTrackProperties(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["projectId", "expectedRevision", "operationId", "dryRun", "trackId", "muted", "hidden", "syncLocked"], path: "set_track_properties")
        var operation = args.filter { ["trackId", "muted", "hidden", "syncLocked"].contains($0.key) }
        operation["type"] = "set_track"
        var request = args.filter { ["projectId", "expectedRevision", "operationId", "dryRun"].contains($0.key) }
        request["operations"] = [operation]
        return try applyEdit(editor, request)
    }
}

extension EditorViewModel {
    var editRevision: String {
        (try? TimelineEditPlanner.revision(timeline: timeline, manifest: mediaManifest)) ?? "invalid-timeline"
    }
}
