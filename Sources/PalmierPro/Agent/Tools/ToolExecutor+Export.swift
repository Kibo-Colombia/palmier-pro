import Foundation

extension ToolExecutor {
    private static let exportVideoAllowedKeys: Set<String> = ["path", "format", "resolution"]

    func exportVideo(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.exportVideoAllowedKeys, path: "export_video")
        guard let path = args.string("path"), path.hasPrefix("/") else {
            throw ToolError("Missing required field 'path' (absolute output file path)")
        }

        let format: ExportFormat
        switch args.string("format") ?? "h264" {
        case "h264": format = .h264
        case "h265": format = .h265
        case "prores": format = .prores
        case let other: throw ToolError("Unknown format '\(other)' — use h264, h265, or prores")
        }

        let resolution: ExportResolution
        switch args.string("resolution") ?? "1080p" {
        case "720p": resolution = .r720p
        case "1080p": resolution = .r1080p
        case "4K", "4k": resolution = .r4k
        case let other: throw ToolError("Unknown resolution '\(other)' — use 720p, 1080p, or 4K")
        }

        let outputURL = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let service = ExportService()
        await service.export(
            timeline: editor.timeline,
            resolver: editor.mediaResolver,
            format: format,
            resolution: resolution,
            outputURL: outputURL
        )
        if let error = service.error {
            throw ToolError("Export failed: \(error)")
        }
        let sizeMB = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
            .flatMap { $0.map { Double($0) / 1_048_576 } } ?? 0
        return .ok("{\"ok\":true,\"path\":\"\(path)\",\"sizeMB\":\(Int(sizeMB.rounded()))}")
    }
}
