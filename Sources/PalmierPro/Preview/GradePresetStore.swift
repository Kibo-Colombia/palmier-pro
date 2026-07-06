import Foundation

/// User-saved color-grade presets ("save as preset" in the Color section / MCP). One JSON
/// file per preset in a reusable app-support folder (LUTStore's pattern), registered at
/// launch via `warm()` so lookups are synchronous. A preset stores a full static
/// `ColorGrade` — including a LUT id, which degrades gracefully if that LUT is missing on
/// another machine — but never masks or keyframes.
final class GradePresetStore: @unchecked Sendable {
    static let shared = GradePresetStore()

    struct GradePreset: Codable, Sendable, Equatable, Identifiable {
        let id: String
        var name: String
        var grade: ColorGrade
    }

    enum PresetError: Error { case emptyName, notFound }

    private let lock = NSLock()
    private var presets: [String: GradePreset] = [:]
    private let directory: URL

    static let presetsDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(Log.subsystem)/GradePresets", isDirectory: true)

    private init() {
        self.directory = Self.presetsDirectory
    }

    /// Test seam: an isolated store rooted at a custom folder.
    init(directory: URL) {
        self.directory = directory
    }

    /// Call once at launch (beside LUTStore.warm()): register every saved preset.
    func warm() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        lock.lock(); defer { lock.unlock() }
        for url in urls where url.pathExtension.lowercased() == "json" {
            if let data = try? Data(contentsOf: url),
               let preset = try? JSONDecoder().decode(GradePreset.self, from: data) {
                presets[preset.id] = preset
            }
        }
    }

    func all() -> [GradePreset] {
        lock.lock(); defer { lock.unlock() }
        return presets.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func preset(id: String) -> GradePreset? {
        lock.lock(); defer { lock.unlock() }
        return presets[id]
    }

    @discardableResult
    func save(name: String, grade: ColorGrade) throws -> GradePreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PresetError.emptyName }
        let preset = GradePreset(id: UUID().uuidString, name: trimmed, grade: grade)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(preset)
        try data.write(to: fileURL(preset.id), options: .atomic)
        lock.lock(); presets[preset.id] = preset; lock.unlock()
        return preset
    }

    func delete(id: String) throws {
        lock.lock()
        let known = presets.removeValue(forKey: id) != nil
        lock.unlock()
        guard known else { throw PresetError.notFound }
        try? FileManager.default.removeItem(at: fileURL(id))
    }

    private func fileURL(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }
}
