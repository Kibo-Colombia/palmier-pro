import SwiftUI

// MARK: - Library load-status readout
//
// A context-bar pill that rolls every asset in the library up into one of a
// handful of load states, so the user can answer "did everything load, or is
// something missing?" at a glance. The pill shows the worst state present;
// tapping it opens a popover that breaks the counts down and lists every file
// that isn't fully loaded — click a row to jump straight to it.
//
// Counts are reactive: MediaAsset is @Observable, so as thumbnails finish
// generating or downloads land, the pill updates itself.

extension MediaTab {

    /// How completely a single library asset has loaded. Raw values double as a
    /// severity order — lower is more urgent — so `allCases` reads worst-first.
    enum LibraryItemState: Int, CaseIterable {
        case missing = 0    // source file isn't on disk
        case failed         // generation errored out
        case generating     // AI generation / download still running
        case loading        // imported, metadata/thumbnail still processing
        case ready          // fully loaded and on disk

        /// Singular noun for the popover rows ("Missing", "Loaded", …).
        var title: String {
            switch self {
            case .missing: "Missing"
            case .failed: "Failed"
            case .generating: "Generating"
            case .loading: "Loading"
            case .ready: "Loaded"
            }
        }

        /// Lowercase form for the pill ("2 missing", "3 loading").
        var noun: String { title.lowercased() }

        var systemImage: String {
            switch self {
            case .missing: "exclamationmark.triangle.fill"
            case .failed: "xmark.octagon.fill"
            case .generating: "sparkles"
            case .loading: "arrow.triangle.2.circlepath"
            case .ready: "checkmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .missing, .failed: AppTheme.Status.errorColor
            case .generating, .loading: AppTheme.Accent.timecodeColor
            case .ready: AppTheme.Status.successColor
            }
        }

        /// Needs the user's attention vs. just busy/done.
        var isProblem: Bool { self == .missing || self == .failed }

        /// In-progress states render a spinner instead of a glyph.
        var isBusy: Bool { self == .loading || self == .generating }
    }

    /// Classify one asset's load state.
    func libraryItemState(_ asset: MediaAsset) -> LibraryItemState {
        switch asset.generationStatus {
        case .failed: return .failed
        case .generating, .downloading, .rendering: return .generating
        case .none: break
        }
        if editor.mediaResolver.isMissing(for: asset.id) { return .missing }
        // File is present — has its metadata finished loading?
        switch asset.type {
        case .video, .image: return asset.thumbnail == nil ? .loading : .ready
        case .audio, .lottie: return asset.duration <= 0 ? .loading : .ready
        case .text: return .ready
        }
    }

    /// Count of every library asset by load state, plus the per-asset states so
    /// the popover doesn't have to re-classify.
    private func libraryStateSnapshot() -> (counts: [LibraryItemState: Int], states: [(MediaAsset, LibraryItemState)]) {
        var counts: [LibraryItemState: Int] = [:]
        var states: [(MediaAsset, LibraryItemState)] = []
        states.reserveCapacity(editor.mediaAssets.count)
        for asset in editor.mediaAssets {
            let state = libraryItemState(asset)
            counts[state, default: 0] += 1
            states.append((asset, state))
        }
        return (counts, states)
    }

    // MARK: - Pill (context bar)

    @ViewBuilder
    var libraryStatusPill: some View {
        let snapshot = libraryStateSnapshot()
        let total = editor.mediaAssets.count
        if total > 0 {
            // Worst state present drives the pill; .ready only when all are loaded.
            let summary = LibraryItemState.allCases.first { (snapshot.counts[$0] ?? 0) > 0 } ?? .ready
            Button { showLibraryStatus.toggle() } label: {
                pillContent(summary: summary, count: snapshot.counts[summary] ?? 0)
            }
            .buttonStyle(.plain)
            .help(summary == .ready ? "All \(total) files loaded" : "Library load status — \(snapshot.counts[summary] ?? 0) \(summary.noun)")
            .popover(isPresented: $showLibraryStatus, arrowEdge: .bottom) {
                libraryStatusPopover(snapshot: snapshot, total: total)
            }
        }
    }

    @ViewBuilder
    private func pillContent(summary: LibraryItemState, count: Int) -> some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            stateGlyph(summary, size: AppTheme.FontSize.xs)
            if summary != .ready {
                Text("\(count) \(summary.noun)")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(summary.isProblem ? summary.color : AppTheme.Text.tertiaryColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xxs)
        .background(
            Capsule(style: .continuous)
                .fill(summary.isProblem
                      ? summary.color.opacity(AppTheme.Opacity.muted)
                      : Color.white.opacity(AppTheme.Opacity.subtle))
        )
    }

    // MARK: - Popover

    private func libraryStatusPopover(
        snapshot: (counts: [LibraryItemState: Int], states: [(MediaAsset, LibraryItemState)]),
        total: Int
    ) -> some View {
        // Everything that isn't fully loaded, worst-first — the actionable list.
        let attention = snapshot.states
            .filter { $0.1 != .ready }
            .sorted { $0.1.rawValue < $1.1.rawValue }

        return VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text("Library")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer()
                Text(total == 1 ? "1 file" : "\(total) files")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .monospacedDigit()
            }

            // One summary row per state that's actually present, ready-first.
            VStack(spacing: AppTheme.Spacing.sm) {
                ForEach([LibraryItemState.ready, .loading, .generating, .missing, .failed], id: \.rawValue) { state in
                    let count = snapshot.counts[state] ?? 0
                    if count > 0 {
                        summaryRow(state, count: count)
                    }
                }
            }

            if !attention.isEmpty {
                Divider().overlay(AppTheme.Border.subtleColor)
                Text(attention.count == 1 ? "1 file needs attention" : "\(attention.count) files need attention")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .textCase(.uppercase)
                ScrollView {
                    VStack(spacing: AppTheme.Spacing.xxs) {
                        ForEach(attention, id: \.0.id) { asset, state in
                            attentionRow(asset: asset, state: state)
                        }
                    }
                }
                .frame(maxHeight: 200)
            } else {
                Text("Everything's loaded and accounted for.")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: 264)
    }

    private func summaryRow(_ state: LibraryItemState, count: Int) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            stateGlyph(state, size: AppTheme.FontSize.sm)
                .frame(width: AppTheme.IconSize.xxs, alignment: .center)
            Text(state.title)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer()
            Text("\(count)")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .monospacedDigit()
        }
    }

    private func attentionRow(asset: MediaAsset, state: LibraryItemState) -> some View {
        Button {
            showLibraryStatus = false
            revealAsset(id: asset.id)
        } label: {
            HStack(spacing: AppTheme.Spacing.sm) {
                stateGlyph(state, size: AppTheme.FontSize.xs)
                    .frame(width: AppTheme.IconSize.xxs, alignment: .center)
                Text(asset.name)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: AppTheme.Spacing.sm)
                Text(state.title)
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(state.isProblem ? state.color : AppTheme.Text.mutedColor)
            }
            .padding(.vertical, AppTheme.Spacing.xxs)
            .padding(.horizontal, AppTheme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Reveal \(asset.name) in the library")
    }

    @ViewBuilder
    private func stateGlyph(_ state: LibraryItemState, size: CGFloat) -> some View {
        if state.isBusy {
            ProgressView()
                .controlSize(.mini)
                .tint(state.color)
        } else {
            Image(systemName: state.systemImage)
                .font(.system(size: size, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(state.color)
        }
    }
}
