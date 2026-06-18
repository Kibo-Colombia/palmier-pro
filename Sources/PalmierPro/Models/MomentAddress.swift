import Foundation

/// The durable, portable address of a "moment" in the understood Library (M3, "The Organizer").
///
/// A moment is a shot range within a file: `(rootLabel) / relativePath @ shotStart..shotEnd`.
/// Spaces store these instead of raw absolute paths, so a Space survives a drive rename/remount
/// or a parent-folder move as long as the same root is still registered. `shotStart`/`shotEnd`
/// nil means the whole file (the honest default for a Library card, which represents a file).
///
/// This is the load-bearing addressing core: the understanding engine (SigLIP → next) is a
/// rented hand, but a moment stays addressable as `(root) / path @ scene` regardless.
struct MomentAddress: Codable, Hashable, Identifiable, Sendable {
    var rootLabel: String
    var relativePath: String
    var shotStart: Double?
    var shotEnd: Double?

    var id: String { dragString }

    var isWholeFile: Bool { shotStart == nil || shotEnd == nil }

    /// The file's display name (no extension), derived from the relative path.
    var fileName: String {
        (relativePath as NSString).lastPathComponent
    }

    init(rootLabel: String, relativePath: String, shotStart: Double? = nil, shotEnd: Double? = nil) {
        self.rootLabel = rootLabel
        self.relativePath = relativePath
        self.shotStart = shotStart
        self.shotEnd = shotEnd
    }

    // MARK: - Drag payload (`palmier-moment://<rootLabel>/<relpath>#start-end`)

    static let dragScheme = "palmier-moment://"

    /// Drag payload form. Label and path are percent-encoded (alphanumerics-only) so spaces and
    /// slashes in names survive the round-trip without colliding with the literal `/` separator.
    var dragString: String {
        var s = "\(Self.dragScheme)\(Self.encode(rootLabel))/\(Self.encode(relativePath))"
        if let start = shotStart, let end = shotEnd {
            s += String(format: "#%.3f-%.3f", start, end)
        }
        return s
    }

    init?(dragString line: String) {
        guard line.hasPrefix(Self.dragScheme) else { return nil }
        let body = line.dropFirst(Self.dragScheme.count)
        let hashSplit = body.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let addrPart = hashSplit[0]
        guard let slash = addrPart.firstIndex(of: "/") else { return nil }
        guard let label = Self.decode(String(addrPart[..<slash])),
              let path = Self.decode(String(addrPart[addrPart.index(after: slash)...])) else { return nil }
        rootLabel = label
        relativePath = path
        if hashSplit.count == 2 {
            let parts = hashSplit[1].split(separator: "-", omittingEmptySubsequences: false)
            if parts.count == 2, let start = Double(parts[0]), let end = Double(parts[1]), end > start {
                shotStart = start
                shotEnd = end
            }
        }
    }

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
    private static func decode(_ s: String) -> String? {
        s.removingPercentEncoding
    }
}
