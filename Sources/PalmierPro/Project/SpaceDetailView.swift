import AVFoundation
import SwiftUI

/// A Space's workspace (M3, "The Organizer"): the moments curated into it, rendered as cards over
/// the Library's footage. Drag clips from the Library here to add them — pointer materialization,
/// so nothing is copied and the raw bytes never move. The Space is a saved view, not a folder.
struct SpaceDetailView: View {
    let spaceID: UUID
    /// Called when the Space is deleted, so the host can leave this dead selection.
    var onDeleted: () -> Void = {}

    @State private var registry = SpaceRegistry.shared
    @State private var roots = RootsRegistry.shared
    @State private var isTargeted = false
    @State private var editingName = ""
    @FocusState private var nameFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: AppTheme.Spacing.lg)]

    private var space: Space? { registry.space(spaceID) }

    var body: some View {
        Group {
            if let space {
                VStack(alignment: .leading, spacing: 0) {
                    header(space)
                    if space.items.isEmpty {
                        emptyState
                    } else {
                        grid(space)
                    }
                }
            } else {
                missingState
            }
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(AppTheme.Accent.primary, lineWidth: AppTheme.BorderWidth.thick)
                    .padding(AppTheme.Spacing.smMd)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.text], isTargeted: $isTargeted) { handleDrop($0) }
        .task(id: spaceID) {
            registry.touch(spaceID)
            editingName = space?.name ?? ""
        }
    }

    // MARK: - Header

    private func header(_ space: Space) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            TextField("Space name", text: $editingName)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                .tracking(AppTheme.Tracking.tight)
                .foregroundStyle(AppTheme.Text.primaryColor)
                .focused($nameFocused)
                .onSubmit { commitName() }
                .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                .fixedSize()

            Text("\(space.items.count) \(space.items.count == 1 ? "moment" : "moments")")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .monospacedDigit()

            Spacer()

            Menu {
                Button(role: .destructive) {
                    registry.remove(spaceID)
                    onDeleted()
                } label: {
                    Label("Delete Space", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: AppTheme.FontSize.mdLg))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, AppTheme.Spacing.xlXxl)
        .padding(.top, AppTheme.Spacing.lg)
        .padding(.bottom, AppTheme.Spacing.md)
    }

    private func commitName() {
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != space?.name else {
            editingName = space?.name ?? ""
            return
        }
        registry.rename(spaceID, to: trimmed)
    }

    // MARK: - Grid

    private func grid(_ space: Space) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: AppTheme.Spacing.lg) {
                ForEach(space.items) { address in
                    SpaceMomentCard(address: address) {
                        registry.removeItem(address, from: spaceID)
                    }
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
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                .foregroundStyle(AppTheme.Text.mutedColor)
            Text("Drag clips from the Library here")
                .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text("A Space is a saved view of your footage — nothing is copied or moved.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var missingState: some View {
        Text("This Space no longer exists.")
            .font(.system(size: AppTheme.FontSize.md))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        MomentDrop.handle(providers, into: spaceID)
    }
}

/// One moment in a Space, resolved through its root's bookmark. Whole-file moments reuse the
/// Library card atoms (hover-scrub + label chips); a shot-range moment shows its key frame with a
/// duration badge. A remove control appears on hover.
private struct SpaceMomentCard: View {
    let address: MomentAddress
    let onRemove: () -> Void

    @State private var roots = RootsRegistry.shared
    @State private var poster: NSImage?
    @State private var isHovered = false

    private var url: URL? { roots.fileURL(for: address) }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            ZStack {
                Rectangle().fill(Color.black)
                if let url {
                    if address.isWholeFile {
                        HoverScrubThumbnail(url: url, poster: poster)
                    } else {
                        MomentFrame(url: url, time: address.shotStart ?? 0)
                    }
                } else {
                    missingFootage
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            .overlay(alignment: .bottomLeading) {
                if let url, address.isWholeFile {
                    LabelChips(url: url).padding(AppTheme.Spacing.xs)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !address.isWholeFile { rangeBadge.padding(AppTheme.Spacing.xs) }
            }
            .overlay(alignment: .topTrailing) {
                if isHovered { removeButton.padding(AppTheme.Spacing.xs) }
            }
            Text(address.fileName)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .onHover { isHovered = $0 }
        .task(id: address.id) {
            if address.isWholeFile, let url { poster = await Self.makePoster(url: url) }
        }
    }

    private var missingFootage: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: AppTheme.FontSize.lg))
            Text("Footage not found")
                .font(.system(size: AppTheme.FontSize.xxs))
        }
        .foregroundStyle(AppTheme.Text.mutedColor)
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark")
                .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
                .background(.black.opacity(AppTheme.Opacity.strong), in: .circle)
        }
        .buttonStyle(.plain)
        .help("Remove from this Space")
    }

    private var rangeBadge: some View {
        Text(Self.durationLabel(start: address.shotStart ?? 0, end: address.shotEnd ?? 0))
            .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(.black.opacity(AppTheme.Opacity.strong), in: .capsule)
    }

    private static func durationLabel(start: Double, end: Double) -> String {
        let secs = max(0, end - start)
        return String(format: "%.1fs", secs)
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

/// A single frame rendered at a source time — used for shot-range moments (no hover-scrub).
private struct MomentFrame: View {
    let url: URL
    let time: Double
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .task(id: "\(url.path)@\(time)") {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        }
    }
}
