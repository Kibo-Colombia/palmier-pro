import Foundation

/// Spins an editor Project off a Space (M3, "The Organizer"). The Space stays the durable,
/// non-destructive workspace; the Project it produces is a disposable *output* — exactly the
/// inversion the spec calls for ("the editor-project becomes an output of a Space, not the entry
/// point"). Resolves the Space's moment addresses to files and lays each onto the timeline
/// pre-trimmed to its shot range (whole-file moments span the clip), reusing the editor's
/// existing trimmed-add path (`addClips` with source-second segments).
@MainActor
enum SpaceProjectSpinoff {
    struct ResolvedMoment {
        let url: URL
        /// Source-second range, or nil for a whole-file moment (filled from the asset duration).
        let segment: ClosedRange<Double>?
    }

    /// Resolve a Space's addresses to existing files + their source-second segments, in order.
    /// Drops moments whose footage no longer resolves (root removed, file gone).
    static func resolve(_ space: Space) -> [ResolvedMoment] {
        space.items.compactMap { address in
            guard let url = RootsRegistry.shared.fileURL(for: address),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            let segment = address.shotStart.flatMap { start in
                address.shotEnd.map { end in start...end }
            }
            return ResolvedMoment(url: url, segment: segment)
        }
    }

    /// Import each moment as media and lay it on the first video track, back-to-back, pre-trimmed.
    /// Awaits metadata first so durations, linked audio, and the fit transform are correct before
    /// placement (the asset's own finalize runs concurrently on the same main actor — harmless).
    static func load(_ moments: [ResolvedMoment], into editor: EditorViewModel) async {
        var assets: [MediaAsset] = []
        var segments: [String: ClosedRange<Double>] = [:]
        for moment in moments {
            guard let asset = editor.addMediaAsset(from: moment.url) else { continue }
            await asset.loadMetadata()
            // Provide an explicit segment for every moment so clip durations never depend on the
            // asset's async finalize — whole-file moments span 0...duration.
            let segment = moment.segment ?? (asset.duration > 0 ? 0...asset.duration : nil)
            if let segment { segments[asset.id] = segment }
            assets.append(asset)
        }
        guard !assets.isEmpty else { return }
        let trackIndex = editor.timeline.tracks.firstIndex { $0.type == .video }
            ?? editor.insertTrack(at: 0, type: .video)
        editor.addClips(assets: assets, trackIndex: trackIndex, startFrame: 0, segments: segments)
    }
}
