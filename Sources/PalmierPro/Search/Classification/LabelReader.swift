import Foundation

/// Passive, sidecar-only label reads — no model inference, safe anywhere (home screen,
/// MCP, Space filters). One shared implementation so the agent tools and the UI rank
/// labels identically.
enum LabelReader {
    /// Top label tokens for a file: seen (top 6 by coverage×peak) + heard (say:/topic:).
    /// Empty until the file indexes.
    static func labels(for url: URL) -> [String] {
        let key = EmbeddingStore.key(for: url)
        let visual = key.flatMap { LabelStore.load(key: $0)?.file } ?? []
        let merged = LabelMerge.merged(visual: visual, url: url, key: key)
        let seen = merged.filter { !HeardFacets.isHeard($0.token) }
            .sorted { ($0.coverage * Double($0.peak)) > ($1.coverage * Double($1.peak)) }
            .prefix(6).map(\.token)
        let heard = merged.filter { HeardFacets.isHeard($0.token) }.map(\.token)
        return Array(seen) + heard
    }

    /// True when the file carries every filter token (case-insensitive exact token match).
    static func matches(url: URL, filter: [String]) -> Bool {
        guard !filter.isEmpty else { return false }
        let have = Set(labels(for: url).map { $0.lowercased() })
        return filter.allSatisfy { have.contains($0.lowercased()) }
    }
}
