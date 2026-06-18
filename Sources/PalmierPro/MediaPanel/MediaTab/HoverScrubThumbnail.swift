import SwiftUI

/// The atom of "The Organizer" (M1): hover a video card and scrub the cursor across it to
/// cycle the file's **key moments** — the shot-start frames the visual index already found.
///
/// No new analysis: shot timestamps come from `EmbeddingStore.shots`, one thumbnail per shot
/// is rendered/cached by `KeyframeThumbnailCache`, and cursor-x maps to a shot index. Falls
/// back to the poster frame when the file isn't indexed or has a single shot. Kept standalone
/// (takes a `url` + `poster`) so the same view drops onto the Home library card in M3.
struct HoverScrubThumbnail: View {
    let url: URL
    /// Shown before any keyframes load (and as the fallback for un-indexed files).
    let poster: NSImage?

    @State private var frames: [KeyframeThumbnailCache.Keyframe] = []
    @State private var activeIndex = 0
    /// Flipped true on first hover; drives the lazy `.task` load (not on appear).
    @State private var loadRequested = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(Color.black)
                if let image = currentImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if let poster {
                    Image(nsImage: poster)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay(alignment: .bottom) { scrubIndicator(width: geo.size.width) }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    if frames.isEmpty {
                        loadRequested = true
                    } else {
                        let width = max(geo.size.width, 1)
                        let idx = min(frames.count - 1, max(0, Int(point.x / width * CGFloat(frames.count))))
                        if idx != activeIndex { activeIndex = idx }
                    }
                case .ended:
                    if activeIndex != 0 { activeIndex = 0 }
                }
            }
        }
        // Lazy load on first hover; auto-cancels on disappear and ties to the view lifecycle.
        .task(id: loadRequested) {
            guard loadRequested, frames.isEmpty, let key = EmbeddingStore.key(for: url) else { return }
            if let result = await KeyframeThumbnailCache.shared.keyframes(forURL: url, key: key), !result.isEmpty {
                frames = result
            }
        }
    }

    private var currentImage: CGImage? {
        frames.indices.contains(activeIndex) ? frames[activeIndex].image : nil
    }

    @ViewBuilder
    private func scrubIndicator(width: CGFloat) -> some View {
        if frames.count > 1 {
            let segment = width / CGFloat(frames.count)
            Rectangle()
                .fill(Color.white.opacity(0.85))
                .frame(width: max(segment, 2), height: 2)
                .offset(x: -width / 2 + segment * CGFloat(activeIndex) + segment / 2)
                .allowsHitTesting(false)
        }
    }
}
