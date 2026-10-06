import Foundation

extension ToolExecutor {
    func startExport(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: ExportVideoArgs = try decodeToolArgs(args, path: "start_export")
        try checkProjectRevision(editor, expected: input.expectedRevision)
        let receipt = try ExportJobService.shared.start(
            timeline: editor.timeline, manifest: editor.mediaManifest, projectURL: editor.projectURL,
            path: input.path, formatName: input.format ?? "h264", resolutionName: input.resolution ?? "1080p",
            overwrite: input.overwrite ?? false, idempotencyKey: input.idempotencyKey)
        return try exportReceipt(receipt)
    }

    func getExportJob(_ args: [String: Any]) throws -> ToolResult {
        let input: ExportJobArgs = try decodeToolArgs(args, path: "get_export_job")
        return try exportReceipt(ExportJobService.shared.receipt(jobId: input.jobId))
    }

    func cancelExport(_ args: [String: Any]) throws -> ToolResult {
        let input: ExportJobArgs = try decodeToolArgs(args, path: "cancel_export")
        return try exportReceipt(ExportJobService.shared.cancel(jobId: input.jobId))
    }

    func exportVideo(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: ExportVideoArgs = try decodeToolArgs(args, path: "export_video")
        try checkProjectRevision(editor, expected: input.expectedRevision)
        let job = try ExportJobService.shared.start(
            timeline: editor.timeline, manifest: editor.mediaManifest, projectURL: editor.projectURL,
            path: input.path, formatName: input.format ?? "h264", resolutionName: input.resolution ?? "1080p",
            overwrite: input.overwrite ?? false, idempotencyKey: input.idempotencyKey)
        let receipt = try await ExportJobService.shared.wait(jobId: job.jobId)
        guard receipt.state == .completed else { throw ToolError(receipt.error ?? "Export \(receipt.state.rawValue)") }
        return try exportReceipt(receipt)
    }

    private func exportReceipt(_ receipt: ExportJobReceipt) throws -> ToolResult {
        let data = try JSONEncoder().encode(receipt)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["ok"] = receipt.state != .failed
        object["durationSeconds"] = Double(receipt.totalFrames) / Double(receipt.fps)
        return .ok(Self.jsonString(object)!)
    }
}

private struct ExportVideoArgs: DecodableToolArgs {
    static let allowedKeys: Set<String> = ["path", "format", "resolution", "overwrite", "expectedRevision", "idempotencyKey"]
    let path: String
    let format: String?
    let resolution: String?
    let overwrite: Bool?
    let expectedRevision: String?
    let idempotencyKey: String?
}

private struct ExportJobArgs: DecodableToolArgs {
    static let allowedKeys: Set<String> = ["jobId"]
    let jobId: String
}
