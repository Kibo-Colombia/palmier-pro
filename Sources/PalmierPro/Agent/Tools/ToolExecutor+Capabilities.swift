import CryptoKit
import Foundation

extension ToolExecutor {
    func getCapabilities(_ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: [], path: "get_capabilities")
        let schemas = ToolDefinitions.all.map {
            ["name": $0.name.rawValue, "description": $0.description, "inputSchema": $0.inputSchema] as [String: Any]
        } + LibraryToolDefinitions.all.map {
            ["name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema] as [String: Any]
        }
        let schemaData = try JSONSerialization.data(withJSONObject: schemas, options: [.sortedKeys])
        let fingerprint = SHA256.hash(data: schemaData).map { String(format: "%02x", $0) }.joined()
        var receipt: [String: Any] = [
            "apiVersion": 1,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
            "sourceRevision": Bundle.main.object(forInfoDictionaryKey: "KomaSourceRevision") as? String ?? "unavailable",
            "sourceDirty": Bundle.main.object(forInfoDictionaryKey: "KomaSourceDirty") as? Bool ?? true,
            "schemaFingerprint": fingerprint,
            "tools": schemas.compactMap { $0["name"] as? String }.sorted(),
            "features": ["projectLifecycle", "atomicEdits", "revisionGuards", "idempotentEdits", "beatTiming", "trackMute", "exportJobs", "markers", "playRange"],
            "audioUnits": ["clipVolume": "linear", "keyframesDefault": "linear", "keyframesSupported": ["linear", "db"], "projectVolumeTrack": "db", "silenceDb": VolumeScale.floorDb],
            "timingUnits": "frames"
        ]
        if let editor {
            receipt["revision"] = editor.editRevision
            receipt["projectId"] = editor.projectId
        }
        guard let json = Self.jsonString(receipt) else { throw ToolError("Failed to encode capabilities") }
        return .ok(json)
    }
}
