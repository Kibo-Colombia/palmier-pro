import SwiftUI

/// The inspector's Color section — a collapsible header plus the CapCut-style sub-tabs
/// (Basic / HSL / Curves / Wheels / Mask). Extracted from InspectorView so the color surface
/// can grow without turning the inspector into a monolith.
struct ColorSectionView: View {
    @Environment(EditorViewModel.self) var editor
    let clips: [Clip]

    @State private var expanded = false
    @State private var subTab: ColorSubTab = .basic

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            header
            if expanded {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    subTabBar
                    switch subTab {
                    case .basic:  ColorBasicTab(clips: clips)
                    case .hsl:    ColorHSLTab(clips: clips)
                    case .curves: ColorCurvesTab(clips: clips)
                    case .wheels: ColorWheelsTab(clips: clips)
                    case .mask:   comingSoon("Mask")
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text("Color".uppercased())
                        .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                        .tracking(AppTheme.Tracking.wide)
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .fixedSize()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if expanded {
                resetButton
            }
        }
    }

    private var resetButton: some View {
        Button {
            commitGradeToClips(editor, clips, actionName: "Reset Color") { c in
                editor.commitClipProperty(clipId: c.id) { $0.grade = ColorGrade(); $0.gradeTrack = nil }
            }
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help("Reset the entire color grade")
    }

    // MARK: - Sub-tabs

    private var subTabBar: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            ForEach(ColorSubTab.allCases, id: \.self) { tab in
                let selected = subTab == tab
                Button {
                    subTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: AppTheme.FontSize.xs, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                        .padding(.horizontal, AppTheme.Spacing.sm)
                        .padding(.vertical, AppTheme.Spacing.xxs)
                        .background(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                .fill(selected ? Color.white.opacity(AppTheme.Opacity.subtle) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private func comingSoon(_ name: String) -> some View {
        Text("\(name) is coming in the next update.")
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.mutedColor)
            .padding(.vertical, AppTheme.Spacing.sm)
    }
}
