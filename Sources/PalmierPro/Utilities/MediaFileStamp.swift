import Foundation

/// Size + modification date of a media file, so a rewrite at the same path reads as a change.
struct MediaFileStamp: Hashable, Sendable {
    let size: Int64
    let modified: TimeInterval

    init?(url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let modified = attrs[.modificationDate] as? Date else { return nil }
        self.size = size
        self.modified = modified.timeIntervalSince1970
    }

    /// Short filename-safe token for derived caches.
    var token: String {
        "\(String(size, radix: 36))-\(String(Int64(modified * 1000), radix: 36))"
    }
}
