import Foundation

/// Persistent references to user-granted folders (M2c roots). Stores a bookmark so a root
/// survives drive rename/remount and a future sandbox, falling back to a plain bookmark when
/// security-scoped creation isn't available (the app is currently unsandboxed).
enum Bookmarks {
    static func create(for url: URL) -> Data? {
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            return data
        }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves a bookmark to its current URL. Caller should bracket file access with
    /// `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`
    /// (a no-op while unsandboxed, required once sandboxed).
    static func resolve(_ data: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale) {
            return (url, isStale)
        }
        isStale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
            return (url, isStale)
        }
        return nil
    }
}
