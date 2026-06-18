import SwiftUI

/// Compact classification chips for a media card (M2). Loads the file's top labels lazily and
/// shows them as terse value chips ("outdoor", "aerial", "talking-head"). Renders nothing
/// until labels are available, so it's safe to drop in as an overlay. Reused by Spaces in M3.
struct LabelChips: View {
    let url: URL
    var maxChips = 3

    @State private var labels: [FileLabel] = []

    var body: some View {
        Group {
            if !labels.isEmpty {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    ForEach(labels.prefix(maxChips), id: \.token) { label in
                        chip(label.value)
                    }
                }
            }
        }
        .task(id: url.path) {
            guard let key = EmbeddingStore.key(for: url),
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
