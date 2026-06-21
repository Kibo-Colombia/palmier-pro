import Foundation

/// Resolves a look id → `LUTCube` **synchronously**, which the render path requires:
/// `VideoEngine.refreshVisuals` rebuilds the video composition on every grade tweak with no async,
/// so cube data must come from an in-memory cache, never a per-frame disk read. Bundled looks are
/// generated at launch; imported `.cube` files live in a reusable app-support folder (not in any
/// project, not Caches) and are registered at launch — so they resolve without touching MediaResolver.
final class LUTStore: @unchecked Sendable {
    static let shared = LUTStore()

    struct ImportedLook: Sendable, Equatable { let id: String; let name: String; let url: URL }
    enum LUTImportError: Error { case invalid }

    private let lock = NSLock()
    private var cache: [String: LUTCube] = [:]
    private var misses: Set<String> = []
    private var imported: [String: ImportedLook] = [:]

    static let looksDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(Log.subsystem)/Looks", isDirectory: true)

    private init() {}

    /// Call once at launch (beside the font registration): generate bundled looks + register imports.
    func warm() {
        warmBundledLooks()
        scanImportedLooks()
    }

    func warmBundledLooks() {
        lock.lock(); defer { lock.unlock() }
        for id in BundledLooks.ids where cache[id] == nil {
            if let c = BundledLooks.cube(for: id) { cache[id] = c }
        }
    }

    private func scanImportedLooks() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: Self.looksDirectory, includingPropertiesForKeys: nil) else { return }
        for url in urls where url.pathExtension.lowercased() == "cube" { register(url: url) }
    }

    /// nil → render no look (graceful degrade). `resolveURL` is a last-resort fallback for ids that
    /// are neither bundled nor in the imported registry (unused in practice, kept for flexibility).
    func cube(for id: String, resolveURL: (String) -> URL?) -> LUTCube? {
        lock.lock()
        if let c = cache[id] { lock.unlock(); return c }
        if misses.contains(id) { lock.unlock(); return nil }
        let importedURL = imported[id]?.url
        lock.unlock()

        let resolved: LUTCube? = BundledLooks.cube(for: id)
            ?? importedURL.flatMap { CubeLUTParser.parse(contentsOf: $0) }
            ?? resolveURL(id).flatMap { CubeLUTParser.parse(contentsOf: $0) }

        lock.lock(); defer { lock.unlock() }
        if let resolved { cache[id] = resolved } else { misses.insert(id) }
        return resolved
    }

    /// Copy an imported `.cube` into the Looks folder and register it. Throws if it isn't a valid 3D LUT.
    @discardableResult
    func importLook(suggestedName: String, data: Data) throws -> ImportedLook {
        guard let text = String(data: data, encoding: .utf8), CubeLUTParser.parse(text: text) != nil else {
            throw LUTImportError.invalid
        }
        try FileManager.default.createDirectory(at: Self.looksDirectory, withIntermediateDirectories: true)
        let id = Self.safeId(suggestedName)
        let dest = Self.looksDirectory.appendingPathComponent("\(id).cube")
        try data.write(to: dest, options: .atomic)
        guard let look = register(url: dest) else { throw LUTImportError.invalid }
        return look
    }

    @discardableResult
    private func register(url: URL) -> ImportedLook? {
        guard let cube = CubeLUTParser.parse(contentsOf: url) else { return nil }
        let id = url.deletingPathExtension().lastPathComponent
        let look = ImportedLook(id: id, name: id, url: url)
        lock.lock(); imported[id] = look; cache[id] = cube; misses.remove(id); lock.unlock()
        return look
    }

    func exists(_ id: String, resolveURL: (String) -> URL?) -> Bool {
        cube(for: id, resolveURL: resolveURL) != nil
    }

    var bundledLooks: [BundledLooks.Look] { BundledLooks.all }
    var importedLooks: [ImportedLook] {
        lock.lock(); defer { lock.unlock() }
        return imported.values.sorted { $0.name < $1.name }
    }

    private static func safeId(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let allowed = CharacterSet.alphanumerics
        let cleaned = base.unicodeScalars.map {
            allowed.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "-"
        }
        let id = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return id.isEmpty ? "look" : id
    }
}
