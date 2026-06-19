import SwiftUI

/// Classification labels + summary for a media card (M2/M4), surfaced unobtrusively: a small (i)
/// badge in the corner that opens a popover on click. Click (not hover) so the popover stays put
/// while you read it and tap "Summarize with AI". The popover floats in its own layer, so its
/// content can extend beyond the thumbnail. The root is always a concrete node so the loading
/// `.task` reliably attaches; the task waits for the model rather than bailing if a card appears
/// first. Reused by Spaces in M3.
struct LabelChips: View {
    let url: URL
    var maxChips = 5

    @State private var labels: [FileLabel] = []
    @State private var summary: AssetSummary?
    @State private var expanded = false
    @State private var isSummarizing = false

    private var hasContent: Bool { !labels.isEmpty || summary != nil }

    var body: some View {
        Group {
            if hasContent {
                Button { expanded.toggle() } label: { infoBadge }
                    .buttonStyle(.plain)
                    .popover(isPresented: $expanded, arrowEdge: .top) {
                        infoPanel
                    }
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .frame(minWidth: 1, minHeight: 1, alignment: .bottomLeading)
        .task(id: url.path) {
            guard let key = EmbeddingStore.key(for: url) else { return }
            // Tier-0 summary needs no model — load it right away (transcript / existing labels).
            summary = await SummaryService.shared.fileSummary(forURL: url, key: key)
            // Labels need the search model; wait for it instead of bailing.
            for _ in 0..<40 where !VisualModelLoader.shared.isReady {
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
            }
            guard VisualModelLoader.shared.isReady,
                  let result = await ClassificationService.shared.fileLabels(forURL: url, key: key) else { return }
            labels = result
            // A silent clip's summary is its tokens — now that labels exist, fill it in.
            if summary == nil { summary = await SummaryService.shared.fileSummary(forURL: url, key: key) }
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

    /// Floating popover content: a one-line summary (M4) over the label chips, plus the opt-in
    /// "Summarize with AI" action. Adapts to the popover background, so it reads in any appearance.
    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if let summary {
                HStack(alignment: .top, spacing: AppTheme.Spacing.xs) {
                    if summary.fileTier == 1 {
                        Image(systemName: "sparkles")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Accent.primary)
                    }
                    Text(summary.fileSummary)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 260, alignment: .leading)
            }
            if !labels.isEmpty {
                HStack(spacing: AppTheme.Spacing.xs) {
                    ForEach(labels.prefix(maxChips), id: \.token) { label in
                        Text(label.value)
                            .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                            .padding(.horizontal, AppTheme.Spacing.sm)
                            .padding(.vertical, AppTheme.Spacing.xxs)
                            .background(Color.primary.opacity(0.08), in: .capsule)
                    }
                }
            }
            if showSummarize {
                Button(action: summarize) {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        if isSummarizing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(isSummarizing ? "Summarizing…" : "Summarize with AI")
                            .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    }
                    .foregroundStyle(AppTheme.Accent.primary)
                }
                .buttonStyle(.plain)
                .disabled(isSummarizing)
            }
        }
        .padding(AppTheme.Spacing.sm)
        .frame(maxWidth: 280, alignment: .leading)
    }

    /// Offer the LLM tier when it's available and we don't already have an LLM summary.
    private var showSummarize: Bool {
        SummaryService.shared.canUseLLM && (summary?.fileTier ?? 0) < 1
    }

    private func summarize() {
        guard let key = EmbeddingStore.key(for: url) else { return }
        isSummarizing = true
        Task {
            if let result = await SummaryService.shared.generateLLMSummary(forURL: url, key: key) {
                summary = result
            }
            isSummarizing = false
        }
    }
}

private extension FileLabel {
    /// "set:night" → "night"
    var value: String { String(token.drop { $0 != ":" }.dropFirst()) }
}
