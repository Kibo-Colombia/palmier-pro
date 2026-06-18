import SwiftUI

/// Compact classification chips for a media card (M2). Loads the file's top labels lazily and
/// shows them as terse value chips ("outdoor", "aerial", "talking-head"). The root is an
/// always-present HStack (empty until labels arrive) so the `.task` reliably fires; the task
/// waits for the model to finish loading rather than giving up if a card appears first.
/// Reused by Spaces in M3.
struct LabelChips: View {
    let url: URL
    var maxChips = 3

    @State private var labels: [FileLabel] = []

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            ForEach(labels.prefix(maxChips), id: \.token) { label in
                chip(label.value)
            }
        }
        .frame(minWidth: 1, minHeight: 1, alignment: .leading)
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
