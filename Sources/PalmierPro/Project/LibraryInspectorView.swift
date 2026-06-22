import AppKit
import AVFoundation
import SwiftUI

/// What the home Library inspector is showing: one file's dossier, or a Space/root overview.
enum LibraryInspectorTarget: Equatable {
    case file(URL)
    case overview(name: String, files: [URL])
}

/// Single selection model for the home Library inspector (mirrors the app's other `.shared` stores).
/// Library/Space cards set a target; HomeView shows the side panel when one is set.
@MainActor
@Observable
final class LibrarySelection {
    static let shared = LibrarySelection()
    var target: LibraryInspectorTarget?

    func isSelected(_ url: URL) -> Bool {
        if case .file(let u) = target { return u == url }
        return false
    }
    func selectFile(_ url: URL) { target = .file(url) }
    func showOverview(name: String, files: [URL]) { target = .overview(name: name, files: files) }
    func clear() { target = nil }
}

/// The home-screen right-hand inspector: the full per-file/per-Space record that the cramped (i)
/// popover never had room for. Renders the SAME `FileDossier`/`SpaceDossier` the editor-handoff
/// markdown does, so the in-app view and the exported `_SPACE.md` can't drift.
struct LibraryInspectorView: View {
    let target: LibraryInspectorTarget
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch target {
            case .file(let url): FileDossierPane(url: url)
            case .overview(let name, let files): SpaceOverviewPane(name: name, files: files)
            }
        }
        .frame(width: AppTheme.Window.libraryInspectorWidth)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: headerIcon)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Text(headerTitle)
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .buttonStyle(.plain)
            .help("Close inspector")
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
    }

    private var headerIcon: String {
        if case .overview = target { return "square.grid.2x2" }
        return "info.circle"
    }
    private var headerTitle: String {
        if case .overview = target { return "Overview" }
        return "Inspector"
    }
}

// MARK: - File dossier

private struct FileDossierPane: View {
    let url: URL
    @State private var dossier: FileDossier?
    @State private var poster: NSImage?
    @State private var isSummarizing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                poster16x9
                if let d = dossier {
                    content(d)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            }
            .padding(AppTheme.Spacing.lg)
        }
        .task(id: url.path) {
            let u = url
            poster = nil  // drop the previous clip's frame so it can't linger while the new one loads
            dossier = await Task.detached { FileDossier(url: u) }.value
            poster = await DossierPoster.make(url: u)
        }
    }

    private var poster16x9: some View {
        ZStack {
            Rectangle().fill(Color.black)
            HoverScrubThumbnail(url: url, poster: poster)
                .id(url)  // reset the thumbnail's cached keyframes when the selected clip changes
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
    }

    @ViewBuilder
    private func content(_ d: FileDossier) -> some View {
        Text(d.oneLiner)
            .font(.system(size: AppTheme.FontSize.md, weight: .medium))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .fixedSize(horizontal: false, vertical: true)

        InspectorBits.section("File") {
            InspectorBits.row("Name", url.lastPathComponent)
            if let dur = d.approxDuration { InspectorBits.row("Length", "~" + InspectorBits.timecode(dur)) }
            if let lang = d.language { InspectorBits.row("Language", lang) }
            InspectorBits.row("Audio", d.sayValue.map { "\(d.said) · \($0)" } ?? d.said)
        }

        let seen = d.fileLabels.map(FileDossier.value)
        let heard = d.heardLabels.map(FileDossier.value)
        if !seen.isEmpty { InspectorBits.section("Seen") { InspectorBits.chips(seen) } }
        if !heard.isEmpty { InspectorBits.section("Heard") { InspectorBits.chips(heard) } }

        if let s = d.summary, !s.isEmpty {
            InspectorBits.section("Summary") {
                HStack(alignment: .top, spacing: AppTheme.Spacing.xs) {
                    if d.summaryIsAI {
                        Image(systemName: "sparkles").font(.system(size: AppTheme.FontSize.xs)).foregroundStyle(AppTheme.Accent.primary)
                    }
                    Text(s).font(.system(size: AppTheme.FontSize.sm)).foregroundStyle(AppTheme.Text.secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        let events = d.timelineEvents
        if !events.isEmpty {
            InspectorBits.section("Timeline") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    ForEach(events.prefix(200)) { e in
                        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                            Text(InspectorBits.timecode(e.time))
                                .font(.system(size: AppTheme.FontSize.xxs).monospacedDigit())
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                                .frame(width: 38, alignment: .leading)
                            Text(e.isSpeech ? "\u{201C}\(e.text)\u{201D}" : "▸ \(e.text)")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(e.isSpeech ? AppTheme.Text.secondaryColor : AppTheme.Text.tertiaryColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }

        if let t = d.transcript, !t.text.isEmpty {
            InspectorBits.section("Transcript") {
                Text(t.text)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        actions(d)
    }

    @ViewBuilder
    private func actions(_ d: FileDossier) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            InspectorBits.actionButton("Reveal in Finder", "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            if !SpaceRegistry.shared.spaces.isEmpty, let address = RootsRegistry.shared.address(for: url) {
                Menu {
                    ForEach(SpaceRegistry.shared.spaces) { space in
                        Button(space.name) { SpaceRegistry.shared.add([address], to: space.id) }
                    }
                } label: {
                    InspectorBits.actionLabel("Add to Space", "plus.rectangle.on.folder")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if SummaryService.shared.canUseLLM && !d.summaryIsAI {
                InspectorBits.actionButton(isSummarizing ? "Summarizing…" : "Summarize with AI", "sparkles", disabled: isSummarizing) {
                    summarize()
                }
            }
        }
    }

    private func summarize() {
        guard let key = EmbeddingStore.key(for: url) else { return }
        isSummarizing = true
        Task {
            _ = await SummaryService.shared.generateLLMSummary(forURL: url, key: key)
            dossier = await Task.detached { [url] in FileDossier(url: url) }.value
            isSummarizing = false
        }
    }
}

// MARK: - Space / root overview (the live _SPACE.md view)

private struct SpaceOverviewPane: View {
    let name: String
    let files: [URL]
    @State private var dossier: SpaceDossier?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                Text(name)
                    .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                if let d = dossier {
                    Text("\(d.clipCount) clip\(d.clipCount == 1 ? "" : "s")" + (d.languages.isEmpty ? "" : " · " + d.languages.joined(separator: ", ")))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    InspectorBits.section("Clips") {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                            ForEach(d.files) { f in row(f) }
                        }
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            }
            .padding(AppTheme.Spacing.lg)
        }
        .task(id: files) {
            let fs = files
            dossier = await Task.detached { SpaceDossier(name: name, files: fs) }.value
        }
    }

    private func row(_ f: FileDossier) -> some View {
        Button { LibrarySelection.shared.selectFile(f.url) } label: {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(f.url.lastPathComponent)
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .lineLimit(1).truncationMode(.middle)
                Text(truncate(f.oneLiner, 70))
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "\u{2026}"
    }
}

// MARK: - Small shared UI pieces

private enum InspectorBits {
    @ViewBuilder
    static func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(title.uppercased())
                .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                .foregroundStyle(AppTheme.Text.mutedColor)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func chips(_ values: [String]) -> some View {
        FlowChips(values: values)
    }

    static func timecode(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func actionButton(_ title: String, _ icon: String, disabled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(title, icon) }
            .buttonStyle(.plain)
            .disabled(disabled)
    }

    static func actionLabel(_ title: String, _ icon: String) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: icon).font(.system(size: AppTheme.FontSize.xs))
            Text(title).font(.system(size: AppTheme.FontSize.xs, weight: .medium))
        }
        .foregroundStyle(AppTheme.Text.secondaryColor)
        .contentShape(Rectangle())
    }
}

/// Wrapping chip row (capsules) — labels can be many, so they flow onto multiple lines.
private struct FlowChips: View {
    let values: [String]
    var body: some View {
        FlowLayout(spacing: AppTheme.Spacing.xs) {
            ForEach(values, id: \.self) { v in
                Text(v)
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, AppTheme.Spacing.xxs)
                    .background(Color.primary.opacity(0.08), in: .capsule)
            }
        }
    }
}

/// Minimal flow layout for wrapping chips (no dependency on a shared one).
private struct FlowLayout: SwiftUI.Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(ProposedViewSize.unspecified)
            if x + s.width > maxWidth, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(ProposedViewSize.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

/// A still poster for the inspector header (reuses the Library card's approach).
private enum DossierPoster {
    static func make(url: URL) async -> NSImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        guard let cg = try? await gen.image(at: CMTime(seconds: 0, preferredTimescale: 600)).image else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}
