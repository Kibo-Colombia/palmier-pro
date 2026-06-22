import AVFoundation
import SwiftUI

/// The home-screen Library (M2c → M3): footage from user-added roots, understood in place.
/// Reuses the project Media panel's atoms — hover-scrub key moments and label chips — so a clip
/// reads the same here as inside a project. Raw bytes never move; Koma reads the folders directly.
struct LibraryView: View {
    @State private var roots = RootsRegistry.shared
    @State private var indexer = LibraryIndexer.shared

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: AppTheme.Spacing.lg)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if roots.roots.isEmpty {
                emptyState
            } else {
                rootsBar
                grid
            }
        }
        .task(id: roots.files) {
            indexer.ensureIndexed(roots.files)
        }
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Text("Library")
                .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                .tracking(AppTheme.Tracking.tight)
                .foregroundStyle(AppTheme.Text.primaryColor)
            if indexer.isIndexing {
                HStack(spacing: AppTheme.Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("\(indexer.phaseLabel) \(indexer.done)/\(indexer.total)")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .monospacedDigit()
                }
            }
            Spacer()
            if !roots.roots.isEmpty {
                Button { LibrarySelection.shared.showOverview(name: "Library", files: roots.files) } label: {
                    Label("Overview", systemImage: "square.grid.2x2")
                }
                .help("Show a live overview of the whole Library")
                Button(action: addFolder) {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xlXxl)
        .padding(.top, AppTheme.Spacing.lg)
        .padding(.bottom, AppTheme.Spacing.md)
    }

    private var rootsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppTheme.Spacing.xs) {
                ForEach(roots.roots) { root in
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: AppTheme.FontSize.xxs))
                            .foregroundStyle(AppTheme.Accent.primary.opacity(0.85))
                        Text(root.label)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .lineLimit(1)
                        Button { RootsRegistry.shared.remove(root.id) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(root.label) from the library")
                    }
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, AppTheme.Spacing.xxs)
                    .background(Color.white.opacity(AppTheme.Opacity.faint), in: .capsule)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.xlXxl)
            .padding(.bottom, AppTheme.Spacing.sm)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: AppTheme.Spacing.lg) {
                ForEach(roots.files, id: \.self) { url in
                    LibraryVideoCard(url: url)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.xlXxl)
            .padding(.bottom, AppTheme.Spacing.xlXxl)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.smMd) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                .foregroundStyle(AppTheme.Text.mutedColor)
            Text("Add a folder of footage")
                .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text("Koma understands it in place — no copying, nothing leaves your Mac.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Button("Add Folder…", action: addFolder)
                .padding(.top, AppTheme.Spacing.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder"
        panel.message = "Choose a folder of footage for Koma to understand."
        panel.begin { response in
            if response == .OK, let url = panel.url {
                RootsRegistry.shared.addFolder(url)
            }
        }
    }
}

/// A library card: poster at rest, hover-scrub key moments on hover, label chips behind the (i).
/// Hover state surfaces a subtle border + scale nudge so the card reads as draggable before
/// the gesture starts. The drag preview matches the MediaTab house style (accent border + shadow).
private struct LibraryVideoCard: View {
    let url: URL
    @State private var poster: NSImage?
    @State private var isHovered = false
    @State private var selection = LibrarySelection.shared

    private let cardRadius = AppTheme.Radius.sm

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            ZStack {
                Rectangle().fill(Color.black)
                HoverScrubThumbnail(url: url, poster: poster)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                    .strokeBorder(
                        AppTheme.Accent.primary.opacity(selection.isSelected(url) ? 1 : (isHovered ? AppTheme.Opacity.medium : 0)),
                        lineWidth: AppTheme.BorderWidth.medium
                    )
            }
            .overlay(alignment: .bottomLeading) {
                LabelChips(url: url).padding(AppTheme.Spacing.xs)
            }
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture { selection.selectFile(url) }
        .task(id: url.path) {
            poster = await Self.makePoster(url: url)
        }
        // Drag a clip into a Space as a whole-file moment (M3). The address resolves lazily on
        // drag start; "" when the file is outside every root (the drop handler ignores it).
        .draggable(RootsRegistry.shared.address(for: url)?.dragString ?? "") {
            dragPreview
        }
    }

    /// Ghost shown while the drag is in flight. Thumbnail + accent border + drop shadow —
    /// matches the MediaTab house style so all drags read consistently.
    private var dragPreview: some View {
        ZStack {
            Rectangle().fill(Color.black)
            if let poster {
                Image(nsImage: poster).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "film")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .strokeBorder(AppTheme.Accent.primary, lineWidth: AppTheme.BorderWidth.medium)
        )
        .shadow(color: .black.opacity(AppTheme.Opacity.medium), radius: 8, y: 4)
    }

    private static func makePoster(url: URL) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        guard let cg = try? await generator.image(at: CMTime(seconds: 0, preferredTimescale: 600)).image else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}
