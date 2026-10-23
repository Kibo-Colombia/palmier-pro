import Foundation

/// A named point or range on the timeline ruler, like a DaVinci Resolve marker.
struct TimelineMarker: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var color: MarkerColor = .blue
    var startFrame: Int
    /// 0 is a point marker; anything longer is a range.
    var durationFrames: Int = 0
    var note: String?

    var endFrame: Int { startFrame + durationFrames }
    var isRange: Bool { durationFrames > 0 }

    private enum CodingKeys: String, CodingKey {
        case id, name, color, startFrame, durationFrames, note
    }
}

extension TimelineMarker {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString,
            name: (try? c.decode(String.self, forKey: .name)) ?? "",
            color: (try? c.decode(String.self, forKey: .color)).flatMap(MarkerColor.init(rawValue:)) ?? .blue,
            startFrame: max(0, try c.decode(Int.self, forKey: .startFrame)),
            durationFrames: max(0, (try? c.decode(Int.self, forKey: .durationFrames)) ?? 0),
            note: try? c.decodeIfPresent(String.self, forKey: .note)
        )
    }
}

/// Resolve's marker palette, so names carry over for people who know it.
enum MarkerColor: String, Codable, CaseIterable, Sendable {
    case blue, cyan, green, yellow, red, pink, purple, fuchsia
    case rose, lavender, sky, mint, lemon, sand, cocoa, cream
}

extension Array where Element == TimelineMarker {
    /// Matches an id exactly, then a name case-insensitively, then a unique name prefix
    /// ending at a word boundary ("HOOK 2" finds "HOOK 2 · The tiny clock", never "HOOK 20").
    func resolve(_ query: String) throws -> TimelineMarker {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw ToolError("marker must not be empty") }
        if let byId = first(where: { $0.id == q }) { return byId }
        let exact = filter { $0.name.compare(q, options: .caseInsensitive) == .orderedSame }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { throw ToolError("Several markers are named '\(q)'. Use the marker id.") }
        let prefixed = filter { marker in
            guard marker.name.count > q.count,
                  marker.name.range(of: q, options: [.caseInsensitive, .anchored]) != nil else { return false }
            let next = marker.name[marker.name.index(marker.name.startIndex, offsetBy: q.count)]
            return !(next.isLetter || next.isNumber)
        }
        if prefixed.count == 1 { return prefixed[0] }
        if prefixed.count > 1 {
            throw ToolError("'\(q)' matches several markers: \(prefixed.map(\.name).joined(separator: ", ")). Use the full name or id.")
        }
        throw ToolError("No marker named '\(q)'. Markers: \(isEmpty ? "none" : map(\.name).joined(separator: ", ")).")
    }
}
