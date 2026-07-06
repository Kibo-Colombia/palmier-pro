import AppKit
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
    /// Sticks across exports: whether the editor-handoff package renames copies to readable names.
    @AppStorage("space.renameForEditor") private var renameForEditor = true
    /// One-time mental-model banner ("a Space is a saved view, not a folder").
    @AppStorage("space.modelBannerDismissed") private var bannerDismissed = false
    @State private var filterDraft = ""
    /// Library files matching the Space's saved label filter (minus manual items).
    @State private var matchedFiles: [URL] = []

    private var handoffOptions: SpaceMaterializer.Options {
        SpaceMaterializer.Options(writeBriefs: true, renameToDescription: renameForEditor)
    }

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: AppTheme.Spacing.lg)]

    private var space: Space? { registry.space(spaceID) }

    var body: some View {
        Group {
            if let space {
                VStack(alignment: .leading, spacing: 0) {
                    header(space)
                    if !space.items.isEmpty, !bannerDismissed {
                        modelBanner
                    }
                    filterBar(space)
                    if space.items.isEmpty, matchedFiles.isEmpty {
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
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .strokeBorder(AppTheme.Accent.primary, lineWidth: AppTheme.BorderWidth.thick)
                    .padding(AppTheme.Spacing.smMd)
                    .overlay(
                        // Subtle accent fill behind the border for extra weight
                        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                            .fill(AppTheme.Accent.primary.opacity(AppTheme.Opacity.subtle))
                            .padding(AppTheme.Spacing.smMd)
                    )
                    .allowsHitTesting(false)
                    .transition(.opacity.animation(.easeOut(duration: AppTheme.Anim.hover)))
            }
        }
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: isTargeted)
        .onDrop(of: [.text], isTargeted: $isTargeted) { handleDrop($0) }
        .task(id: spaceID) {
            registry.touch(spaceID)
            editingName = space?.name ?? ""
        }
        .task(id: "\(spaceID)|\((space?.labelFilter ?? []).joined(separator: ","))|\(roots.files.count)|\(space?.items.count ?? 0)") {
            await recomputeMatches()
        }
    }

    // MARK: - Header

    private func header(_ space: Space) -> some View {
        let linkedProject = registry.linkedProjectURL(for: spaceID)
        return HStack(spacing: AppTheme.Spacing.md) {
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

            Button {
                LibrarySelection.shared.showOverview(
                    name: space.name,
                    files: space.items.filter(\.isWholeFile).compactMap { roots.fileURL(for: $0) })
            } label: {
                Label("Overview", systemImage: "square.grid.2x2")
            }
            .disabled(space.items.isEmpty)
            .help("Show a live overview of this Space")
            .fixedSize()

            if let project = linkedProject {
                Button {
                    AppState.shared.openProject(at: project)
                } label: {
                    Label("Open Project “\(project.deletingPathExtension().lastPathComponent)”", systemImage: "film.stack")
                }
                .help("Reopen the project this Space spun off")
                .fixedSize()
            } else {
                Button {
                    AppState.shared.createProject(from: space)
                } label: {
                    Label("Create Project from Space", systemImage: "film.stack.badge.plus")
                }
                .disabled(space.items.isEmpty)
                .help("Snapshots these \(space.items.count) moments onto a new timeline. The Space is untouched.")
                .fixedSize()
            }

            Menu {
                if linkedProject != nil {
                    Button { AppState.shared.createProject(from: space) } label: {
                        Label("Create Another Project…", systemImage: "film.stack.fill")
                    }
                    .disabled(space.items.isEmpty)
                    Divider()
                }
                Button { materialize(.symlink) } label: {
                    Label("Show in Finder (Symlinks)", systemImage: "link")
                }
                .disabled(space.items.isEmpty)
                Button { materialize(.copy) } label: {
                    Label("Export Copies…", systemImage: "doc.on.doc")
                }
                .disabled(space.items.isEmpty)

                Divider()

                Section("Editor Handoff") {
                    Toggle(isOn: $renameForEditor) {
                        Label("Rename files to descriptions", systemImage: "character.cursor.ibeam")
                    }
                    Button { materialize(.copy, options: handoffOptions) } label: {
                        Label("Export for Editor…", systemImage: "person.crop.rectangle.stack")
                    }
                    .disabled(space.items.isEmpty)
                }

                Divider()

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

    // MARK: - Mental-model banner

    /// One line, once: the distinction Spaces live or die on. The empty-state says this
    /// too, but the confusion happens on *populated* Spaces at project-creation time.
    private var modelBanner: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "info.circle")
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Text("A Space is a saved view of your library — not a folder. Nothing here moves or copies footage; a Project is an edit you spin off.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer()
            Button {
                bannerDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .buttonStyle(.plain)
            .help("Got it")
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(Color.white.opacity(AppTheme.Opacity.subtle), in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
        .padding(.horizontal, AppTheme.Spacing.xlXxl)
        .padding(.bottom, AppTheme.Spacing.sm)
    }

    // MARK: - Label filter ("a label is a saved search")

    private func filterBar(_ space: Space) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            ForEach(space.labelFilter ?? [], id: \.self) { token in
                HStack(spacing: AppTheme.Spacing.xxs) {
                    Text(token)
                        .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                    Button {
                        var tokens = space.labelFilter ?? []
                        tokens.removeAll { $0 == token }
                        registry.setLabelFilter(tokens, for: spaceID)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, AppTheme.Spacing.xs)
                .padding(.vertical, AppTheme.Spacing.xxs)
                .background(AppTheme.Accent.primary.opacity(AppTheme.Opacity.hint), in: .capsule)
                .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            TextField(
                (space.labelFilter?.isEmpty ?? true) ? "Filter by label (e.g. set:night)…" : "Add label…",
                text: $filterDraft
            )
            .textFieldStyle(.plain)
            .font(.system(size: AppTheme.FontSize.xs))
            .frame(maxWidth: 200)
            .onSubmit {
                let token = filterDraft.trimmingCharacters(in: .whitespaces)
                guard !token.isEmpty else { return }
                registry.setLabelFilter((space.labelFilter ?? []) + [token], for: spaceID)
                filterDraft = ""
            }
            Spacer()
        }
        .padding(.horizontal, AppTheme.Spacing.xlXxl)
        .padding(.bottom, AppTheme.Spacing.sm)
    }

    /// Matches are computed off-main from the label sidecars (passive reads); manual items
    /// are excluded so a file never appears twice.
    private func recomputeMatches() async {
        guard let space, let filter = space.labelFilter, !filter.isEmpty else {
            matchedFiles = []
            return
        }
        let files = roots.files
        let itemPaths = Set(space.items.compactMap { roots.fileURL(for: $0)?.path })
        let matches = await Task.detached(priority: .utility) {
            files.filter { LabelReader.matches(url: $0, filter: filter) }
        }.value
        matchedFiles = matches.filter { !itemPaths.contains($0.path) }
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
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            registry.removeItem(address, from: spaceID)
                        }
                    }
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
                }
            }
            .padding(.horizontal, AppTheme.Spacing.xlXxl)
            .padding(.bottom, AppTheme.Spacing.xlXxl)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: space.items.map(\.id))

            if !matchedFiles.isEmpty {
                matchedSection(space)
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Live results of the Space's saved label filter — library files that match but were
    /// never manually added. The ＋ affordance promotes one into the Space's own moments.
    private func matchedSection(_ space: Space) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text("Matched by filter")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Text("\(matchedFiles.count)")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .monospacedDigit()
            }
            LazyVGrid(columns: columns, spacing: AppTheme.Spacing.lg) {
                ForEach(matchedFiles, id: \.path) { url in
                    MatchedFileCard(url: url) {
                        guard let address = roots.address(for: url) else { return }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            registry.add([address], to: spaceID)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xlXxl)
        .padding(.bottom, AppTheme.Spacing.xlXxl)
    }

    private var emptyState: some View {
        ZStack {
            // Dashed drop zone — brightens when a drag is in flight
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: AppTheme.BorderWidth.medium, dash: [6, 5] as [CGFloat])
                )
                .foregroundStyle(
                    isTargeted
                        ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium)
                        : Color.white.opacity(AppTheme.Opacity.faint)
                )
                .padding(AppTheme.Spacing.xlXxl)

            VStack(spacing: AppTheme.Spacing.smMd) {
                ZStack {
                    Circle()
                        .fill(
                            isTargeted
                                ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.hint)
                                : Color.white.opacity(AppTheme.Opacity.subtle)
                        )
                        .frame(width: 52, height: 52)
                    Image(systemName: isTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                        .font(.system(size: AppTheme.FontSize.title1, weight: .light))
                        .foregroundStyle(
                            isTargeted
                                ? AppTheme.Accent.primary
                                : AppTheme.Text.mutedColor
                        )
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isTargeted)

                Text("Drag clips from the Library here")
                    .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Text("A Space is a saved view of your footage — nothing is copied or moved.")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: isTargeted)
    }

    private var missingState: some View {
        VStack(spacing: AppTheme.Spacing.smMd) {
            Image(systemName: "xmark.circle")
                .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                .foregroundStyle(AppTheme.Text.mutedColor)
            Text("Space not found")
                .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text("This Space no longer exists.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        MomentDrop.handle(providers, into: spaceID)
    }

    // MARK: - Materialize (symlink / copy)

    private func materialize(_ mode: SpaceMaterializer.Mode, options: SpaceMaterializer.Options = .plain) {
        guard let space else { return }
        chooseDestination(for: space, mode: mode) { destination in
            Task { @MainActor in
                do {
                    let result = try await SpaceMaterializer.materialize(space, mode: mode, into: destination, options: options)
                    NSWorkspace.shared.activateFileViewerSelecting([result.directory])
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    /// Reuse the Space's saved destination folder if it still resolves; otherwise prompt once and
    /// remember it (security-scoped bookmark), recording the chosen materialization mode.
    private func chooseDestination(for space: Space, mode: SpaceMaterializer.Mode, _ completion: @escaping (URL) -> Void) {
        let materialization: Materialization = mode == .symlink ? .symlink : .copy
        if let data = space.destinationBookmark, let resolved = Bookmarks.resolve(data) {
            _ = resolved.url.startAccessingSecurityScopedResource()
            registry.setMaterialization(materialization, for: spaceID)
            completion(resolved.url)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Where should Koma place this Space's files?"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let bookmark = Bookmarks.create(for: url)
            registry.setMaterialization(materialization, for: spaceID, destinationBookmark: bookmark)
            completion(url)
        }
    }
}

/// One moment in a Space, resolved through its root's bookmark. Whole-file moments reuse the
/// Library card atoms (hover-scrub + label chips); a shot-range moment shows its key frame with a
/// duration badge. A remove control appears on hover with a scale press feel.
private struct SpaceMomentCard: View {
    let address: MomentAddress
    let onRemove: () -> Void

    @State private var roots = RootsRegistry.shared
    @State private var poster: NSImage?
    @State private var isHovered = false
    @State private var selection = LibrarySelection.shared

    private let cardRadius = AppTheme.Radius.sm
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
            .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .overlay {
                // Subtle hover border; accent when selected into the inspector.
                let isSelected = url.map { selection.isSelected($0) } ?? false
                RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? AppTheme.Accent.primary : Color.white.opacity(isHovered ? AppTheme.Opacity.muted : AppTheme.Opacity.hint),
                        lineWidth: isSelected ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.hairline
                    )
            }
            .overlay(alignment: .bottomLeading) {
                if let url, address.isWholeFile {
                    LabelChips(url: url).padding(AppTheme.Spacing.xs)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !address.isWholeFile { rangeBadge.padding(AppTheme.Spacing.xs) }
            }
            .overlay(alignment: .topTrailing) {
                removeButton
                    .padding(AppTheme.Spacing.xs)
                    .opacity(isHovered ? 1 : 0)
            }
            Text(address.fileName)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .scaleEffect(isHovered ? 1.015 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture { if address.isWholeFile, let url { selection.selectFile(url) } }
        .task(id: address.id) {
            if address.isWholeFile, let url { poster = await Self.makePoster(url: url) }
        }
    }

    /// Shown when the source file can't be resolved — styled as a plate, not a bare label.
    private var missingFootage: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: AppTheme.FontSize.xl, weight: .light))
                .foregroundStyle(AppTheme.Text.mutedColor)
            Text("Footage not found")
                .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.raisedColor)
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark")
                .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
                .background(
                    Circle().fill(.black.opacity(AppTheme.Opacity.prominent))
                )
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(AppTheme.Opacity.faint), lineWidth: AppTheme.BorderWidth.hairline)
                )
        }
        .buttonStyle(.plain)
        .help("Remove from this Space")
        // Tiny spring scale on the button itself for press feel
        .scaleEffect(isHovered ? 1.0 : 0.85)
        .animation(.spring(response: 0.2, dampingFraction: 0.65), value: isHovered)
    }

    private var rangeBadge: some View {
        Text(Self.durationLabel(start: address.shotStart ?? 0, end: address.shotEnd ?? 0))
            .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(.black.opacity(AppTheme.Opacity.prominent), in: .capsule)
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(AppTheme.Opacity.faint), lineWidth: AppTheme.BorderWidth.hairline)
            )
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

/// A library file surfaced by the Space's label filter — same footage atoms as a moment
/// card, with a ＋ control to promote it into the Space's own moments.
private struct MatchedFileCard: View {
    let url: URL
    let onAdd: () -> Void

    @State private var isHovered = false

    private let cardRadius = AppTheme.Radius.sm

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            ZStack {
                Rectangle().fill(Color.black)
                HoverScrubThumbnail(url: url, poster: nil)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(isHovered ? AppTheme.Opacity.muted : AppTheme.Opacity.hint),
                        lineWidth: AppTheme.BorderWidth.hairline
                    )
            }
            .overlay(alignment: .bottomLeading) {
                LabelChips(url: url).padding(AppTheme.Spacing.xs)
            }
            .overlay(alignment: .topTrailing) {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
                        .background(Circle().fill(.black.opacity(AppTheme.Opacity.prominent)))
                        .overlay(
                            Circle().strokeBorder(Color.white.opacity(AppTheme.Opacity.faint), lineWidth: AppTheme.BorderWidth.hairline)
                        )
                }
                .buttonStyle(.plain)
                .help("Add to this Space")
                .padding(AppTheme.Spacing.xs)
                .opacity(isHovered ? 1 : 0)
            }
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .scaleEffect(isHovered ? 1.015 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
        .onHover { isHovered = $0 }
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
