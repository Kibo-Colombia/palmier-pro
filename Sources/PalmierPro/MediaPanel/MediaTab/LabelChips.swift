import SwiftUI

/// Classification labels for a media card (M2), surfaced unobtrusively: a small (i) badge in
/// the corner that reveals the file's top label chips on hover. Keeps the thumbnail clean while
/// the understanding stays one hover away. The root is always a concrete node so the loading
/// `.task` reliably attaches; the task waits for the model rather than bailing if a card appears
/// first. Reused by Spaces in M3.
struct LabelChips: View {
    let url: URL
    var maxChips = 4

    @State private var labels: [FileLabel] = []
    @State private var expanded = false

    var body: some View {
        content
            .frame(minWidth: 1, minHeight: 1, alignment: .bottomLeading)
            .onHover { hovering in
                withAnimation(.easeOut(duration: AppTheme.Anim.transition)) { expanded = hovering }
            }
            .task(id: url.path) {
                // The search model loads a beat after launch; wait for it instead of bailing.
                for _ in 0..<40 where !VisualModelLoader.shared.isReady {
                    try? await Task.sleep(for: .milliseconds(300))
                    if Task.isCancelled { return }
                }
                guard VisualModelLoader.shared.isReady,
                      let key = EmbeddingStore.key(for: url),
                      let result = await ClassificationService.shared.fileLabels(forURL: url, key: key) else { return }
                labels = result
            }
    }

    @ViewBuilder
    private var content: some View {
        if labels.isEmpty {
            Color.clear.frame(width: 1, height: 1)
        } else if expanded {
            HStack(spacing: AppTheme.Spacing.xxs) {
                ForEach(labels.prefix(maxChips), id: \.token) { label in
                    chip(label.value)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
        } else {
            infoBadge
        }
    }

    private var infoBadge: some View {
        Image(systemName: "info")
            .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
            .background(.black.opacity(AppTheme.Opacity.strong), in: .circle)
            .overlay(Circle().strokeBorder(Color.white.opacity(AppTheme.Opacity.muted), lineWidth: AppTheme.BorderWidth.hairline))
    }

    private func chip(_ value: String) -> some View {
        Text(value)
            .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, 1)
            .background(.black.opacity(AppTheme.Opacity.prominent), in: .capsule)
    }
}

private extension FileLabel {
    /// "set:night" → "night"
    var value: String { String(token.drop { $0 != ":" }.dropFirst()) }
}
