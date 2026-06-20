import AppKit
import SwiftUI

/// Slim chat input for the home-screen Library chat: a text editor + send/stop button, with a
/// leading tools slot (model picker / BYOK badge). Deliberately omits the editor `AgentInputBox`'s
/// @-mention popover, drag, and paste — the home chat has no per-asset mention surface — so it
/// binds to a plain draft binding instead of an `EditorViewModel`.
struct LibraryChatInputBox<LeadingTools: View>: View {
    @Binding var draft: String
    let isSending: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onCancel: () -> Void
    let leadingTools: LeadingTools

    init(
        draft: Binding<String>,
        isSending: Bool,
        canSend: Bool,
        onSend: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        @ViewBuilder leadingTools: () -> LeadingTools
    ) {
        self._draft = draft
        self.isSending = isSending
        self.canSend = canSend
        self.onSend = onSend
        self.onCancel = onCancel
        self.leadingTools = leadingTools()
    }

    @FocusState private var focused: Bool
    @Namespace private var sendStopNamespace

    var body: some View {
        VStack(spacing: 0) {
            textField
            bottomBar
        }
        .glassEffect(.regular, in: .rect(cornerRadius: AppTheme.Radius.xl))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.xl, style: .continuous)
                .strokeBorder(
                    focused ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium)
                        : Color.white.opacity(AppTheme.Opacity.hint),
                    lineWidth: focused ? AppTheme.BorderWidth.thin : AppTheme.BorderWidth.hairline
                )
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.15), value: focused)
    }

    private var textField: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .padding(.horizontal, AppTheme.Spacing.mdLg)
                .padding(.top, AppTheme.Spacing.smMd)
                .padding(.bottom, AppTheme.Spacing.xs)
                .focused($focused)
                .frame(minHeight: 32, maxHeight: 64)
                .onKeyPress(phases: [.down]) { press in handleKey(press) }

            if draft.isEmpty {
                Text("Ask about your Library, or organize it into Spaces")
                    .font(.body)
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .padding(.horizontal, AppTheme.Spacing.lgXl)
                    .padding(.top, AppTheme.Spacing.mdLg)
                    .allowsHitTesting(false)
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(AppTheme.Opacity.hint))
                .frame(height: AppTheme.BorderWidth.hairline)
            HStack(spacing: AppTheme.Spacing.md) {
                leadingTools
                Spacer(minLength: 0)
                GlassEffectContainer(spacing: AppTheme.Spacing.xs) {
                    sendStopButton
                }
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.sm)
        }
    }

    @ViewBuilder
    private var sendStopButton: some View {
        if isSending {
            Button(action: onCancel) {
                Image(systemName: "stop.fill")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .bold))
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .tint(AppTheme.Text.secondaryColor)
            .glassEffectID("sendStop", in: sendStopNamespace)
            .help("Stop")
            .transition(.scale.combined(with: .opacity))
        } else {
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .bold))
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .tint(AppTheme.Accent.primary)
            .glassEffectID("sendStop", in: sendStopNamespace)
            .disabled(!canSend)
            .opacity(canSend ? 1 : AppTheme.Opacity.strong)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.phase == .down else { return .ignored }
        if press.key == .return, !press.modifiers.contains(.shift), canSend {
            onSend()
            return .handled
        }
        return .ignored
    }
}
