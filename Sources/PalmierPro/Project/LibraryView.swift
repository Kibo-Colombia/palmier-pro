import AVFoundation
import SwiftUI

/// The home-screen Library (M2c → M3): footage from user-added roots, understood in place.
/// Reuses the project Media panel's atoms — hover-scrub key moments and label chips — so a clip
/// reads the same here as inside a project. Raw bytes never move; Koma reads the folders directly.
struct LibraryView: View {
    @State private var roots = RootsRegistry.shared
    @State private var indexer = LibraryIndexer.shared
    /// Newest-first is the default: the freshest footage is what you're most likely here for.
    @AppStorage("library.sortNewestFirst") private var sortNewestFirst = true
    /// Files bucketed per root (nil label when only one root), sorted per the toggle.
    @State private var groups: [LibraryFileGroup] = []
    @State private var search = LibrarySearchModel()
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: AppTheme.Spacing.lg)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if roots.roots.isEmpty {
                emptyState
            } else if search.isActive {
                searchResults
            } else {
                rootsBar
                grid
            }
        }
        .task(id: roots.files) {
            indexer.ensureIndexed(roots.files)
        }
        .task(id: "\(roots.files.hashValue)|\(sortNewestFirst)") {
            groups = await LibraryFileGroup.make(
                files: roots.files, roots: roots.roots, newestFirst: sortNewestFirst
            )
        }
        .background {
            // ⌘F focuses search from anywhere in the Library.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
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
            } else if let issue = indexer.issue {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(Color.orange)
                    Text(issue)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                        .help(issue)
                    Button("Retry") { indexer.ensureIndexed(roots.files) }
                        .buttonStyle(.plain)
                        .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                        .foregroundStyle(AppTheme.Accent.primary)
                }
            }
            Spacer()
            if !roots.roots.isEmpty {
                searchField
                Menu {
                    Picker("Sort", selection: $sortNewestFirst) {
                        Text("Newest first").tag(true)
                        Text("By name").tag(false)
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Order the library grid")
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

    /// One field, three layers: what the frames show, what was said, what files are named.
    private var searchField: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            TextField("Search moments, words, files…", text: $search.query)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm))
                .focused($searchFocused)
                .onChange(of: search.query) { _, _ in search.scheduleSearch() }
                .onExitCommand { search.clear(); searchFocused = false }
            if search.isActive {
                if search.isSearching {
                    ProgressView().controlSize(.mini)
                }
                Button {
                    search.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                .buttonStyle(.plain)
                .help("Clear search (Esc)")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs)
        .frame(width: 260)
        .background(Color.white.opacity(AppTheme.Opacity.subtle), in: .capsule)
        .overlay(
            Capsule().strokeBorder(
                searchFocused ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium) : Color.white.opacity(AppTheme.Opacity.hint),
                lineWidth: AppTheme.BorderWidth.hairline
            )
        )
    }

    // MARK: - Search results

    private var searchResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                if !search.moments.isEmpty {
                    resultHeader("Moments", icon: "sparkle.magnifyingglass", count: search.moments.count)
                    LazyVGrid(columns: columns, spacing: AppTheme.Spacing.lg) {
                        ForEach(search.moments) { MomentResultCard(hit: $0) }
                    }
                } else if search.visualUnavailable, !search.isSearching {
                    Label("Visual model is still loading — moment search will join in a moment.", systemImage: "sparkle.magnifyingglass")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                if !search.spoken.isEmpty {
                    resultHeader("Spoken", icon: "waveform", count: search.spoken.count)
                    VStack(spacing: AppTheme.Spacing.sm) {
                        ForEach(search.spoken) { SpokenResultRow(hit: $0) }
                    }
                }
                if !search.files.isEmpty {
                    resultHeader("Files", icon: "doc", count: search.files.count)
                    LazyVGrid(columns: columns, spacing: AppTheme.Spacing.lg) {
                        ForEach(search.files, id: \.self) { LibraryVideoCard(url: $0) }
                    }
                }
                if search.isEmpty {
                    VStack(spacing: AppTheme.Spacing.sm) {
                        if search.isSearching {
                            ProgressView().controlSize(.small)
                            Text("Searching what your footage shows and says…")
                        } else {
                            Text("No matches for “\(search.query.trimmingCharacters(in: .whitespacesAndNewlines))”")
                        }
                    }
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(maxWidth: .infinity)
                    .padding(.top, AppTheme.Spacing.xxl)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.xlXxl)
            .padding(.bottom, AppTheme.Spacing.xlXxl)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultHeader(_ title: String, icon: String, count: Int) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: AppTheme.FontSize.xs))
            Text(title)
                .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
            Text("\(count)")
                .font(.system(size: AppTheme.FontSize.xs).monospacedDigit())
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .foregroundStyle(AppTheme.Text.secondaryColor)
        .padding(.top, AppTheme.Spacing.sm)
    }

    private var rootsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppTheme.Spacing.xs) {
                ForEach(roots.roots) { root in
                    let isBroken = roots.brokenRootIDs.contains(root.id)
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        Image(systemName: isBroken ? "exclamationmark.triangle.fill" : "folder.fill")
                            .font(.system(size: AppTheme.FontSize.xxs))
                            .foregroundStyle(isBroken ? Color.orange : AppTheme.Accent.primary.opacity(0.85))
                        Text(root.label)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .lineLimit(1)
                        if isBroken {
                            Button("Re-link…") { relink(root) }
                                .buttonStyle(.plain)
                                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                                .foregroundStyle(Color.orange)
                                .help("This folder can't be found. Point \(root.label) at its new location — Spaces keep working as long as the files inside kept their relative paths.")
                        } else {
                            Button {
                                if let url = Bookmarks.resolve(root.bookmark)?.url {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                Image(systemName: "arrow.up.forward.square")
                                    .font(.system(size: AppTheme.FontSize.xxs))
                                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                            }
                            .buttonStyle(.plain)
                            .help("Open \(root.label) in Finder — drop footage there and Koma understands it automatically")
                        }
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
            LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                ForEach(groups) { group in
                    if let label = group.label {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Image(systemName: "folder")
                                .font(.system(size: AppTheme.FontSize.xs))
                            Text(label)
                                .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                            Text("\(group.files.count)")
                                .font(.system(size: AppTheme.FontSize.xs).monospacedDigit())
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .padding(.top, AppTheme.Spacing.sm)
                    }
                    LazyVGrid(columns: columns, spacing: AppTheme.Spacing.lg) {
                        ForEach(group.files, id: \.self) { url in
                            LibraryVideoCard(url: url)
                        }
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

    /// Re-point a broken root at the folder's new location (moved footage, migrated drive).
    private func relink(_ root: Root) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Re-link"
        panel.message = "Choose the new location of “\(root.label)”."
        panel.begin { response in
            if response == .OK, let url = panel.url {
                RootsRegistry.shared.relink(root.id, to: url)
            }
        }
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

/// Files bucketed per root for the Library grid. Label is nil when there's a single root
/// (no point captioning the obvious); ordering follows the roots bar.
struct LibraryFileGroup: Identifiable, Equatable {
    let label: String?
    let files: [URL]
    var id: String { label ?? "·" }

    /// Off-main: stats every file once for the newest-first order.
    static func make(files: [URL], roots: [Root], newestFirst: Bool) async -> [LibraryFileGroup] {
        await Task.detached(priority: .userInitiated) {
            let bases: [(label: String, prefix: String)] = roots.compactMap { root in
                guard let resolved = Bookmarks.resolve(root.bookmark) else { return nil }
                let base = resolved.url.standardizedFileURL.path
                return (root.label, base.hasSuffix("/") ? base : base + "/")
            }
            func sorted(_ urls: [URL]) -> [URL] {
                guard newestFirst else { return urls.sorted { $0.lastPathComponent < $1.lastPathComponent } }
                let stamped = urls.map { url -> (URL, Date) in
                    let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
                    return (url, date)
                }
                return stamped.sorted { $0.1 > $1.1 }.map(\.0)
            }
            var buckets: [String: [URL]] = [:]
            var stray: [URL] = []
            for file in files {
                let path = file.standardizedFileURL.path
                if let base = bases.first(where: { path.hasPrefix($0.prefix) }) {
                    buckets[base.label, default: []].append(file)
                } else {
                    stray.append(file)
                }
            }
            if bases.count <= 1 {
                return [LibraryFileGroup(label: nil, files: sorted(files))]
            }
            var groups = bases.compactMap { base -> LibraryFileGroup? in
                guard let bucket = buckets[base.label], !bucket.isEmpty else { return nil }
                return LibraryFileGroup(label: base.label, files: sorted(bucket))
            }
            if !stray.isEmpty { groups.append(LibraryFileGroup(label: "Other", files: sorted(stray))) }
            return groups
        }.value
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
        .contextMenu { LibraryCardMenu(url: url) }
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

/// Right-click actions for any library file card — the macOS-native path to the same
/// actions the inspector offers, without having to select first.
struct LibraryCardMenu: View {
    let url: URL
    /// Optional shot range (search moment results) so "Add to Space" keeps the moment precise.
    var shotStart: Double?
    var shotEnd: Double?

    var body: some View {
        Button {
            LibrarySelection.shared.selectFile(url)
        } label: {
            Label("Details", systemImage: "info.circle")
        }
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        Divider()
        Menu("Add to Space") {
            ForEach(SpaceRegistry.shared.spaces) { space in
                Button(space.name) { add(to: space.id) }
            }
            if !SpaceRegistry.shared.spaces.isEmpty { Divider() }
            Button("New Space…") {
                let space = SpaceRegistry.shared.create(name: url.deletingPathExtension().lastPathComponent)
                add(to: space.id)
            }
        }
    }

    private func add(to spaceID: UUID) {
        guard let address = RootsRegistry.shared.address(for: url, shotStart: shotStart, shotEnd: shotEnd) else { return }
        SpaceRegistry.shared.add([address], to: spaceID)
    }
}

/// A semantic search hit: the matching key frame with its shot range. Drags as a
/// *moment* (shot-range address), so a search result lands in a Space pre-trimmed —
/// search "sunset", drag the exact shot.
private struct MomentResultCard: View {
    let hit: LibrarySearchModel.MomentHit
    @State private var isHovered = false

    private let cardRadius = AppTheme.Radius.sm
    private var range: String {
        String(format: "%@–%@", Timecode.short(hit.shotStart), Timecode.short(hit.shotEnd))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            LibraryFrameThumb(url: hit.url, time: hit.time)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                        .strokeBorder(
                            Color.white.opacity(isHovered ? AppTheme.Opacity.muted : AppTheme.Opacity.hint),
                            lineWidth: AppTheme.BorderWidth.hairline
                        )
                }
                .overlay(alignment: .bottomTrailing) {
                    Text(range)
                        .font(.system(size: AppTheme.FontSize.xxs, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, AppTheme.Spacing.xs)
                        .padding(.vertical, AppTheme.Spacing.xxs)
                        .background(.black.opacity(AppTheme.Opacity.prominent), in: .capsule)
                        .padding(AppTheme.Spacing.xs)
                }
            Text(hit.url.deletingPathExtension().lastPathComponent)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture { LibrarySelection.shared.selectFile(hit.url) }
        .contextMenu { LibraryCardMenu(url: hit.url, shotStart: hit.shotStart, shotEnd: hit.shotEnd) }
        .draggable(
            RootsRegistry.shared.address(for: hit.url, shotStart: hit.shotStart, shotEnd: hit.shotEnd)?.dragString ?? ""
        ) {
            LibraryFrameThumb(url: hit.url, time: hit.time)
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        }
    }
}

/// A spoken-word hit: the segment's frame, the quote, and where it was said. Drags as a
/// moment covering the spoken segment.
private struct SpokenResultRow: View {
    let hit: LibrarySearchModel.SpokenHit
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            LibraryFrameThumb(url: hit.url, time: hit.start)
                .frame(width: 128, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("\u{201C}\(hit.text)\u{201D}")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(3)
                Text("\(hit.url.deletingPathExtension().lastPathComponent) · \(Timecode.short(hit.start))")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(AppTheme.Spacing.xs)
        .background(
            Color.white.opacity(isHovered ? AppTheme.Opacity.subtle : 0),
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { LibrarySelection.shared.selectFile(hit.url) }
        .contextMenu { LibraryCardMenu(url: hit.url, shotStart: hit.start, shotEnd: hit.end) }
        .draggable(
            RootsRegistry.shared.address(for: hit.url, shotStart: hit.start, shotEnd: hit.end)?.dragString ?? ""
        ) {
            LibraryFrameThumb(url: hit.url, time: hit.start)
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
        }
    }
}

/// One async frame at a source time — the search results' thumbnail atom.
private struct LibraryFrameThumb: View {
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
            generator.maximumSize = CGSize(width: 320, height: 320)
            let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        }
    }
}

/// Shared short timecode ("m:ss" / "h:mm:ss") for search results.
private enum Timecode {
    static func short(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }
}
