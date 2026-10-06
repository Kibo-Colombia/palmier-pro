import Foundation

enum ProjectAutomationFiles {
    static func outputURL(_ path: String, extension expectedExtension: String? = nil) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw ToolError("path must be an absolute file path")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.lastPathComponent != "/", !url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError("path must include a file name")
        }
        if let expectedExtension, url.pathExtension.lowercased() != expectedExtension {
            throw ToolError("path must end in .\(expectedExtension)")
        }
        return url
    }

    static func commit(staging: URL, to destination: URL, overwrite: Bool) throws {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: destination.path)
        guard overwrite || !exists else {
            throw ToolError("Destination already exists: \(destination.path). Set overwrite=true to replace it.")
        }
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".koma-backup-\(UUID().uuidString)")
        if exists { try fm.moveItem(at: destination, to: backup) }
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch {
            if exists {
                do { try fm.moveItem(at: backup, to: destination) }
                catch {
                    throw ToolError("Could not restore the previous output. Its backup remains at \(backup.path): \(error.localizedDescription)")
                }
            }
            throw error
        }
        if exists { try? fm.removeItem(at: backup) }
    }
}
