import Foundation

/// Session persistence for the home-screen chat. The editor stores sessions inside each `.palmier`
/// document package; the home chat has no document, so it gets its own namespace under the app's
/// storage directory (alongside roots-registry.json / spaces-registry.json). One JSON file per
/// non-empty session; sessions deleted in the UI are pruned from disk on the next save.
enum HomeChatSessionStore {
    private static let dirURL = Project.storageDirectory.appendingPathComponent("home-chat", isDirectory: true)

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func load() -> [ChatSession] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dirURL, includingPropertiesForKeys: nil
        ) else { return [] }
        return urls.compactMap { url in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(ChatSession.self, from: data)
        }
    }

    static func save(_ sessions: [ChatSession]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)

        var valid = Set<String>()
        for session in sessions where !session.messages.isEmpty {
            let filename = "\(session.id.uuidString).json"
            valid.insert(filename)
            guard let data = try? encoder.encode(session) else { continue }
            try? data.write(to: dirURL.appendingPathComponent(filename), options: .atomic)
        }

        // Prune files for sessions that were emptied or deleted.
        if let existing = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil) {
            for url in existing where url.pathExtension == "json" && !valid.contains(url.lastPathComponent) {
                try? fm.removeItem(at: url)
            }
        }
    }
}
