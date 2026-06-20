import SwiftUI

enum HomeSection: Hashable { case projects, library, space(UUID) }

struct HomeView: View {
    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 170), spacing: AppTheme.Spacing.xl)
    ]

    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @AppStorage("homeChatVisible") private var chatVisible = false
    @State private var section: HomeSection = .projects

    var body: some View {
        HStack(spacing: 0) {
            HomeSidebar(section: $section, chatVisible: $chatVisible)
                .frame(width: 220)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(AppTheme.Opacity.medium))

            if chatVisible {
                Divider()
                LibraryChatPanel(service: HomeAgent.shared, onClose: { chatVisible = false })
                    .frame(width: AppTheme.Window.homeChatWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(minWidth: chatVisible ? 760 + AppTheme.Window.homeChatWidth : 760, minHeight: 480)
        .background(.ultraThinMaterial)
        .focusEffectDisabled()
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: chatVisible)
        .task { await VisualModelLoader.shared.prepare() }
        .overlay {
            if !hasSeenWelcome {
                WelcomeOverlay { withAnimation { hasSeenWelcome = true } }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .projects: projectsContent
        case .library: LibraryView()
        case .space(let id): SpaceDetailView(spaceID: id, onDeleted: { section = .library })
        }
    }

    private var projectsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            SampleProjectsStrip()
            Text("My Projects")
                .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .padding(.horizontal, AppTheme.Spacing.xlXxl)
                .padding(.bottom, AppTheme.Spacing.sm)
            projectGrid
        }
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            WelcomeTitle()

            UpdateBadgeView()

            Spacer()
        }
        .padding(.horizontal, AppTheme.Spacing.xlXxl)
        .padding(.top, AppTheme.Spacing.lg)
        .padding(.bottom, AppTheme.Spacing.xxl)
    }

    private var projectGrid: some View {
        let entries = ProjectRegistry.shared.sortedEntries
        return ScrollView {
            LazyVGrid(columns: columns, spacing: AppTheme.Spacing.xl) {
                if entries.isEmpty {
                    NewProjectCard(action: { AppState.shared.createNewProject() })
                } else {
                    ForEach(entries) { entry in
                        ProjectCard(
                            entry: entry,
                            onOpen: { AppState.shared.openProject(at: $0) },
                            onRemove: { ProjectRegistry.shared.remove($0) }
                        )
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.xlXxl)
            .padding(.bottom, AppTheme.Spacing.xlXxl)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NewProjectCard: View {
    let action: () -> Void

    @State private var isHovered = false

    private let cardRadius: CGFloat = AppTheme.Radius.mdLg

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AppTheme.Background.placeholderColor
                .aspectRatio(5.0/4.0, contentMode: .fit)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .clipped()

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.7), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 60)
            .allowsHitTesting(false)

            Text("Untitled")
                .font(.system(size: AppTheme.FontSize.smMd, weight: .regular))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.bottom, AppTheme.Spacing.smMd)
        }
        .contentShape(Rectangle())
        .onTapGesture { action() }
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(isHovered ? AppTheme.Opacity.muted : AppTheme.Opacity.hint),
                    lineWidth: AppTheme.BorderWidth.hairline
                )
        )
        .shadow(color: .black.opacity(isHovered ? 0.4 : 0.2), radius: isHovered ? 12 : 4, y: isHovered ? 4 : 2)
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .padding(AppTheme.Spacing.xs)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

private struct WelcomeTitle: View {
    @Bindable private var account = AccountService.shared

    var body: some View {
        Text(title)
            .font(.system(size: AppTheme.FontSize.title2, weight: .light))
            .tracking(AppTheme.Tracking.tight)
            .foregroundStyle(AppTheme.Text.primaryColor)
    }

    private var title: String {
        if let first = account.account?.user.firstName {
            return "Welcome to Koma, \(first)"
        }
        return "Welcome to Koma"
    }
}

private struct HomeSidebar: View {
    @Bindable private var account = AccountService.shared
    @State private var spaces = SpaceRegistry.shared
    @Binding var section: HomeSection
    @Binding var chatVisible: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if account.isSignedIn {
                IdentityStrip()
            }

            VStack(alignment: .leading, spacing: 2) {
                if !account.isSignedIn && !account.isMisconfigured {
                    SidebarRowButton(
                        label: "Sign in with Google",
                        systemImage: "person.crop.circle",
                        action: { Task { await account.signInWithGoogle() } }
                    )
                }
                SidebarRowButton(
                    label: "Projects",
                    systemImage: "square.grid.2x2",
                    isSelected: section == .projects,
                    action: { section = .projects }
                )
                SidebarRowButton(
                    label: "Library",
                    systemImage: "rectangle.stack",
                    isSelected: section == .library,
                    action: { section = .library }
                )

                spacesSection

                Divider()
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, AppTheme.Spacing.xs)

                SidebarRowButton(
                    label: "New Project",
                    systemImage: "plus",
                    action: { AppState.shared.createNewProject() }
                )
                SidebarRowButton(
                    label: "Open Project",
                    systemImage: "folder",
                    action: { AppState.shared.openProjectFromPanel() }
                )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 2) {
                SidebarRowButton(
                    label: "Ask Kibo",
                    systemImage: chatVisible ? "bubble.left.fill" : "bubble.left",
                    isSelected: chatVisible,
                    action: { chatVisible.toggle() }
                )
                SidebarRowButton(
                    label: "Settings",
                    systemImage: "gearshape",
                    action: { SettingsWindowController.shared.show() }
                )
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Spaces = saved, non-destructive workspaces carved from the Library. Listed inline so a
    /// Space is one click from Projects and Library, the surfaces it draws from and feeds.
    @ViewBuilder
    private var spacesSection: some View {
        Text("Spaces")
            .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .tracking(AppTheme.Tracking.wide)
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.top, AppTheme.Spacing.sm)
            .padding(.bottom, AppTheme.Spacing.xxs)

        // Stable creation order — never re-sort on open/drop, or a row would slide out from
        // under the cursor mid-drag (spring-load opens the hovered Space, bumping last-opened).
        ForEach(spaces.spaces) { space in
            SpaceSidebarRow(
                space: space,
                isSelected: section == .space(space.id),
                section: $section
            )
        }
        NewSpaceDropRow(section: $section)
    }
}

/// The "New Space" row in the sidebar.
///
/// - **Tap**: creates an empty Space and navigates to it (unchanged prior behaviour).
/// - **Drop** (`palmier-moment://` text): parses the addresses; if at least one is valid,
///   creates a new Space containing those moments and navigates to it. A stray / empty drop
///   is ignored — no phantom Space is created.
private struct NewSpaceDropRow: View {
    @Binding var section: HomeSection
    @State private var isTargeted = false

    var body: some View {
        Button {
            let space = SpaceRegistry.shared.create(name: "Untitled Space")
            section = .space(space.id)
        } label: {
            HStack(spacing: AppTheme.Spacing.smMd) {
                Image(systemName: "plus")
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .frame(width: AppTheme.Spacing.lgXl)
                    .foregroundStyle(
                        isTargeted
                            ? AppTheme.Accent.primary
                            : AppTheme.Text.secondaryColor
                    )
                Text("New Space")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.vertical, AppTheme.Spacing.sm)
            .background {
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .fill(
                        isTargeted
                            ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.hint)
                            : Color.clear
                    )
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                        .strokeBorder(AppTheme.Accent.primary, lineWidth: AppTheme.BorderWidth.medium)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: isTargeted)
        }
        .buttonStyle(.plain)
        .onDrop(of: [.text], isTargeted: $isTargeted) { providers in
            var handled = false
            for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let text = obj as? String else { return }
                    let addresses = text
                        .split(separator: "\n", omittingEmptySubsequences: true)
                        .compactMap { MomentAddress(dragString: String($0)) }
                    guard !addresses.isEmpty else { return }
                    Task { @MainActor in
                        let space = SpaceRegistry.shared.create(name: "Untitled Space")
                        SpaceRegistry.shared.add(addresses, to: space.id)
                        section = .space(space.id)
                    }
                }
            }
            return handled
        }
    }
}

/// A Space row in the sidebar that doubles as a drop target (M3).
///
/// UX polish:
/// - **Targeted state**: accent fill + crisp border, clearly distinct from plain hover/selected.
/// - **Spring-load**: hovering with a drag for ~0.7 s auto-navigates to that Space so the user
///   can drop into its grid and see context without lifting the drag.
/// - **Moment count badge**: a muted pill shows how many moments are in the Space.
private struct SpaceSidebarRow: View {
    let space: Space
    let isSelected: Bool
    @Binding var section: HomeSection

    @State private var isTargeted = false
    /// Timer that fires the spring-load navigation when a drag lingers on this row.
    @State private var springLoadTask: Task<Void, Never>?

    private var itemCount: Int { SpaceRegistry.shared.itemCount(for: space.id) }

    var body: some View {
        Button { section = .space(space.id) } label: {
            HStack(spacing: AppTheme.Spacing.smMd) {
                Image(systemName: "tray.full")
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .frame(width: AppTheme.Spacing.lgXl)
                    .foregroundStyle(
                        isTargeted
                            ? AppTheme.Accent.primary
                            : AppTheme.Text.primaryColor
                    )
                Text(space.name)
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                if itemCount > 0 {
                    Text("\(itemCount)")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: .medium).monospacedDigit())
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .padding(.horizontal, AppTheme.Spacing.xs)
                        .padding(.vertical, AppTheme.Spacing.xxs)
                        .background(Color.white.opacity(AppTheme.Opacity.faint), in: .capsule)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.vertical, AppTheme.Spacing.sm)
            // Targeted gets an accent fill; selected/hover use the standard token.
            .background {
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .fill(
                        isTargeted
                            ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.hint)
                            : isSelected
                                ? Color.white.opacity(AppTheme.Opacity.soft)
                                : Color.clear
                    )
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                        .strokeBorder(AppTheme.Accent.primary, lineWidth: AppTheme.BorderWidth.medium)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: isTargeted)
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: isSelected)
        }
        .buttonStyle(.plain)
        .onDrop(of: [.text], isTargeted: $isTargeted) { providers in
            springLoadTask?.cancel()
            springLoadTask = nil
            return MomentDrop.handle(providers, into: space.id)
        }
        .onChange(of: isTargeted) { _, targeted in
            springLoadTask?.cancel()
            guard targeted else { springLoadTask = nil; return }
            // Spring-load: auto-open after 0.7 s of hover so the user can drop into the grid.
            springLoadTask = Task {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                section = .space(space.id)
            }
        }
    }
}

// MARK: - Home window controller

@MainActor
final class HomeWindowController: NSWindowController {
    static let shared = HomeWindowController()

    private init() {
        let hostingController = NSHostingController(rootView: HomeView().tint(AppTheme.Accent.primary))
        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(AppTheme.Window.homeDefault)
        window.minSize = AppTheme.Window.homeMin
        window.title = "Koma"
        window.setFrameAutosaveName("PalmierProHome-v2")
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = AppTheme.Background.base.withAlphaComponent(0.4)
        window.isOpaque = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Move the window from the (transparent) title-bar strip, not the whole background —
        // background-move preempts the Library/Spaces card drag gestures (M3). Traffic-light
        // region still drags the window.
        window.isMovableByWindowBackground = false
        window.styleMask.insert(.fullSizeContentView)
        window.collectionBehavior = [.fullScreenNone]
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
