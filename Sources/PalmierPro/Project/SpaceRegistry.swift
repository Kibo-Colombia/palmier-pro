import Foundation

/// How a Space's moments are represented on disk (M3, "The Organizer"):
/// - `pointer` (default): in-app only — the registry JSON *is* the materialization. Zero disk
///   writes; raw bytes never move. The only honest non-destructive default, since a symlink
///   can't represent a frame range.
/// - `symlink`: Finder-visible whole-file shortcuts (the moment range stays in-app metadata).
/// - `copy`: isolated copies / re-encoded sub-clips. Explicit user action.
enum Materialization: String, Codable, Sendable { case pointer, symlink, copy }

/// A saved, non-destructive workspace carved from the understood Library: a set of moment
/// addresses (+ optional label filter), organized without ever moving the raw footage. A Space
/// spins off editor Projects; the editor Project is an *output* of a Space, not the entry point.
struct Space: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var items: [MomentAddress]
    var materialization: Materialization
    /// Optional saved label tokens that scope the Space ("a label is a saved search").
    var labelFilter: [String]?
    /// Bookmarked output folder for `symlink`/`copy` materialization.
    var destinationBookmark: Data?
    /// Bookmark to the editor Project this Space last spun off, so "Open as Project" reopens it
    /// instead of always creating a new one. Survives the project file being moved.
    var projectBookmark: Data?
    var createdDate: Date
    var lastOpenedDate: Date

    init(
        id: UUID = UUID(),
        name: String,
        items: [MomentAddress] = [],
        materialization: Materialization = .pointer,
        labelFilter: [String]? = nil,
        destinationBookmark: Data? = nil,
        projectBookmark: Data? = nil,
        createdDate: Date = Date(),
        lastOpenedDate: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.items = items
        self.materialization = materialization
        self.labelFilter = labelFilter
        self.destinationBookmark = destinationBookmark
        self.projectBookmark = projectBookmark
        self.createdDate = createdDate
        self.lastOpenedDate = lastOpenedDate
    }
}

/// Persists Spaces, mirroring `ProjectRegistry`: a JSON sidecar in the app's storage directory,
/// observable so the home screen reacts to mutations.
@Observable
@MainActor
final class SpaceRegistry {
    static let shared = SpaceRegistry()

    private(set) var spaces: [Space] = []

    var sortedSpaces: [Space] {
        spaces.sorted { $0.lastOpenedDate > $1.lastOpenedDate }
    }

    private let fileURL = Project.storageDirectory.appendingPathComponent(Project.spacesRegistryFilename)

    private init() { load() }

    func space(_ id: UUID) -> Space? { spaces.first { $0.id == id } }

    // MARK: - Mutations

    @discardableResult
    func create(name: String) -> Space {
        let space = Space(name: name)
        spaces.append(space)
        save()
        return space
    }

    func remove(_ id: UUID) {
        spaces.removeAll { $0.id == id }
        save()
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[i].name = name
        save()
    }

    /// Add moment addresses to a Space, de-duplicating against what's already there.
    func add(_ addresses: [MomentAddress], to id: UUID) {
        guard let i = spaces.firstIndex(where: { $0.id == id }), !addresses.isEmpty else { return }
        let existing = Set(spaces[i].items)
        spaces[i].items.append(contentsOf: addresses.filter { !existing.contains($0) })
        spaces[i].lastOpenedDate = Date()
        save()
    }

    func removeItem(_ address: MomentAddress, from id: UUID) {
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[i].items.removeAll { $0 == address }
        save()
    }

    func setMaterialization(_ mode: Materialization, for id: UUID, destinationBookmark: Data? = nil) {
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[i].materialization = mode
        if let destinationBookmark { spaces[i].destinationBookmark = destinationBookmark }
        save()
    }

    /// Stamp last-opened (for sort order) when a Space is viewed.
    func touch(_ id: UUID) {
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[i].lastOpenedDate = Date()
        save()
    }

    /// Remember the editor Project a Space spun off, so it can be reopened later.
    func setProject(_ url: URL, for id: UUID) {
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[i].projectBookmark = Bookmarks.create(for: url)
        save()
    }

    /// The Space's linked Project URL, if it was spun off and the file still exists.
    func linkedProjectURL(for id: UUID) -> URL? {
        guard let space = spaces.first(where: { $0.id == id }),
              let data = space.projectBookmark,
              let resolved = Bookmarks.resolve(data),
              FileManager.default.fileExists(atPath: resolved.url.path) else { return nil }
        return resolved.url
    }

    /// Number of moments in a Space — used for the sidebar badge.
    func itemCount(for id: UUID) -> Int {
        spaces.first { $0.id == id }?.items.count ?? 0
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Space].self, from: data) else { return }
        spaces = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(spaces) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Shared handling for `palmier-moment://` drops (one address per line), so the sidebar Space
/// rows and a Space's detail view add moments identically. Returns true if any provider carried
/// text we'll try to parse (so the drop site reports it accepted the drag).
@MainActor
enum MomentDrop {
    static func handle(_ providers: [NSItemProvider], into spaceID: UUID) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
            handled = true
            _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                guard let text = obj as? String else { return }
                let addresses = text
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .compactMap { MomentAddress(dragString: String($0)) }
                guard !addresses.isEmpty else { return }
                Task { @MainActor in SpaceRegistry.shared.add(addresses, to: spaceID) }
            }
        }
        return handled
    }
}
