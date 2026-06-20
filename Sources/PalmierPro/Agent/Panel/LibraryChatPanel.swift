import SwiftUI

/// The home-screen chat panel (Kibo, scoped to the Library + Spaces). Reuses the shared chat atoms
/// (`AgentMessageView`, `ThinkingDots`, `ChatHistoryList`) but binds to an explicit `AgentService`
/// instead of reading `EditorViewModel` from the environment — so it runs with no open project.
struct LibraryChatPanel: View {
    @Bindable var service: AgentService
    var onClose: (() -> Void)? = nil

    private static let starterPrompts: [LibraryStarterPrompt] = [
        LibraryStarterPrompt(
            title: "Organize my Library into Spaces",
            systemImage: "square.stack.3d.up",
            prompt: "Organize my Library into Spaces. Review every file across my roots and its labels, then group them into a few clearly named Spaces by scene, subject, or type. Create the Spaces and add the matching files. Don't move or delete any footage."
        ),
        LibraryStarterPrompt(
            title: "What's in my Library?",
            systemImage: "rectangle.stack",
            prompt: "Give me an overview of what's in my Library — how many files, and the main kinds of footage by label."
        ),
        LibraryStarterPrompt(
            title: "Find my night exterior shots",
            systemImage: "magnifyingglass",
            prompt: "Find my night exterior shots and gather them into a Space."
        ),
    ]

    private var canSend: Bool {
        !service.isStreaming &&
        service.canStream &&
        !service.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            messageList
            footer
        }
        .background(AppTheme.Background.surfaceColor)
    }

    // MARK: - Header

    @State private var showHistory = false

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Text("Kibo")
                .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer(minLength: 0)
            Button { service.newChat() } label: {
                Image(systemName: "plus")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("New chat")
            Button { showHistory.toggle() } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Chat history")
            .popover(isPresented: $showHistory, arrowEdge: .top) {
                ChatHistoryList(
                    sessions: service.sessions.sorted { $0.updatedAt > $1.updatedAt },
                    currentId: service.currentSessionId,
                    onSelect: { id in
                        service.selectSession(id)
                        showHistory = false
                    },
                    onDelete: { service.deleteSession($0) }
                )
            }
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Hide Kibo")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .frame(height: Layout.panelHeaderHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.Border.subtleColor)
                .frame(height: AppTheme.BorderWidth.hairline)
        }
    }

    // MARK: - Messages

    private var toolResults: [String: ToolRunResult] {
        var out: [String: ToolRunResult] = [:]
        for msg in service.messages where msg.role == .user {
            for block in msg.blocks {
                if case let .toolResult(id, content, isError) = block {
                    out[id] = ToolRunResult(content: content, isError: isError)
                }
            }
        }
        return out
    }

    @ViewBuilder
    private var messageList: some View {
        if service.messages.isEmpty && !service.isStreaming {
            VStack(spacing: AppTheme.Spacing.smMd) {
                emptyState
                errorBanner
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, AppTheme.Spacing.lgXl)
        } else {
            scrollingMessages
        }
    }

    private var scrollingMessages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                    let results = toolResults
                    ForEach(service.messages) { msg in
                        AgentMessageView(message: msg, toolResults: results)
                            .id(msg.id)
                    }
                    if service.isStreaming {
                        ThinkingDots().id("streaming-indicator")
                    }
                    errorBanner
                        .padding(.top, AppTheme.Spacing.sm)
                }
                .padding(.horizontal, AppTheme.Spacing.lgXl)
                .padding(.vertical, AppTheme.Spacing.smMd)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .onChange(of: service.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: service.isStreaming) { _, _ in scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if service.isStreaming {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("streaming-indicator", anchor: .bottom) }
        } else if let last = service.messages.last {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if service.canStream {
            VStack(spacing: AppTheme.Spacing.smMd) {
                Text("Ask anything, or start with:")
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .multilineTextAlignment(.center)
                VStack(spacing: AppTheme.Spacing.xs) {
                    ForEach(Self.starterPrompts) { starterPrompt in
                        LibraryStarterPromptButton(starterPrompt: starterPrompt) {
                            populatePrompt(starterPrompt.prompt)
                        }
                    }
                }
            }
        } else {
            missingKeyState
        }
    }

    @ViewBuilder
    private var missingKeyState: some View {
        let account = AccountService.shared
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Button(action: { SettingsWindowController.shared.show(tab: .account) }) {
                Text(missingKeyPrimaryAction(account: account))
                    .underline()
                    .foregroundStyle(AppTheme.Accent.primary)
            }
            .buttonStyle(.plain)

            Text("or use")
                .foregroundStyle(AppTheme.Text.tertiaryColor)

            Button(action: { SettingsWindowController.shared.show(tab: .agent) }) {
                Text("your own Anthropic key")
                    .underline()
                    .foregroundStyle(AppTheme.Accent.primary)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: AppTheme.FontSize.md, weight: .medium))
        .multilineTextAlignment(.center)
    }

    private func missingKeyPrimaryAction(account: AccountService) -> String {
        if !account.isSignedIn { return "Sign in" }
        if !account.isPaid { return "Subscribe" }
        return "Open Settings"
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let err = service.streamError {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text(err.localizedDescription)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.leading)
                if let cta = errorCTA(for: err) {
                    Button(action: cta.action) {
                        Text(cta.title)
                            .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    }
                    .buttonStyle(.capsule(.secondary))
                    .controlSize(.small)
                }
            }
        }
    }

    private struct ErrorCTA {
        let title: String
        let action: () -> Void
    }

    private func errorCTA(for error: PalmierClientError?) -> ErrorCTA? {
        guard let error else { return nil }
        switch error {
        case .unauthenticated:
            return ErrorCTA(title: "Sign in") { SettingsWindowController.shared.show(tab: .account) }
        case .insufficientCredits:
            return ErrorCTA(title: "View plans") { SettingsWindowController.shared.show(tab: .account) }
        case .upstream:
            return nil
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var modelPicker: some View {
        if service.hasApiKey {
            Menu {
                ForEach(service.availableModels, id: \.self) { m in
                    Button(m.displayName) { service.model = m }
                }
            } label: {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(service.effectiveModel.displayName)
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Image(systemName: "chevron.down")
                        .font(.system(size: AppTheme.FontSize.micro, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var byokIndicator: some View {
        if service.hasApiKey {
            Text("using API key")
                .font(.system(size: AppTheme.FontSize.xs).italic())
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .help("Streaming through your Anthropic API key (BYOK)")
        }
    }

    private var footer: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            if !service.canStream && !service.messages.isEmpty {
                missingKeyState
            }
            LibraryChatInputBox(
                draft: $service.draft,
                isSending: service.isStreaming,
                canSend: canSend,
                onSend: submit,
                onCancel: { service.cancel() }
            ) {
                modelPicker
                byokIndicator
            }
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.bottom, AppTheme.Spacing.mdLg)
        .padding(.top, AppTheme.Spacing.xs)
        .frame(maxWidth: .infinity)
    }

    private func submit() {
        guard canSend else { return }
        service.send(text: service.draft, mentions: [])
        service.draft = ""
    }

    private func populatePrompt(_ prompt: String) {
        service.draft = prompt
    }
}

private struct LibraryStarterPrompt: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let prompt: String
}

private struct LibraryStarterPromptButton: View {
    let starterPrompt: LibraryStarterPrompt
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: starterPrompt.systemImage)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
                Text(starterPrompt.title)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .fill(AppTheme.Background.raisedColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Fill prompt")
    }
}
