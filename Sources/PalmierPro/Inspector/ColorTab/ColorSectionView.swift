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
                    case .mask:   ColorMaskTab(clips: clips)
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
                if clips.count == 1, let clip = clips.first {
                    gradeKeyframeControls(clip: clip)
                }
                resetButton
            }
        }
    }

    /// Stamp/remove/navigate color keyframes at the playhead (single-clip selection).
    /// A stamped keyframe snapshots the WHOLE grade; the lane in the Keyframes panel
    /// (row "Color") moves and retimes them.
    private func gradeKeyframeControls(clip: Clip) -> some View {
        let frame = editor.activeFrame
        let inRange = clip.contains(timelineFrame: frame)
        let onKeyframe = editor.hasKeyframe(clipId: clip.id, property: .grade, at: frame)
        let prev = editor.previousKeyframeFrame(clipId: clip.id, property: .grade, before: frame)
        let next = editor.nextKeyframeFrame(clipId: clip.id, property: .grade, after: frame)
        return HStack(spacing: 0) {
            navButton(systemName: "chevron.left", help: "Previous color keyframe", enabled: prev != nil) {
                if let f = prev { editor.seekToFrame(f) }
            }
            Button {
                if onKeyframe {
                    editor.removeKeyframe(clipId: clip.id, property: .grade, at: frame)
                } else {
                    editor.stampKeyframe(clipId: clip.id, property: .grade, frame: frame)
                }
            } label: {
                Image(systemName: onKeyframe ? "diamond.fill" : "diamond")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(onKeyframe ? AppTheme.Accent.timecodeColor : AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.sm)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!inRange)
            .opacity(inRange ? 1 : 0.4)
            .help(!inRange ? "Move playhead inside the clip"
                  : onKeyframe ? "Remove color keyframe at playhead"
                  : "Add color keyframe at playhead")
            navButton(systemName: "chevron.right", help: "Next color keyframe", enabled: next != nil) {
                if let f = next { editor.seekToFrame(f) }
            }
        }
    }

    private func navButton(systemName: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
    }

    private var resetButton: some View {
        Button {
            commitGradeToClips(editor, clips, actionName: "Reset Color") { c in
                editor.commitClipProperty(clipId: c.id) {
                    $0.grade = ColorGrade(); $0.gradeTrack = nil
                    $0.mask = AdjustMask(); $0.maskTrack = nil
                }
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
            if let reset = subTabReset {
                Button(action: reset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                        .hoverHighlight()
                }
                .buttonStyle(.plain)
                .help("Reset \(subTab.rawValue) adjustments (other tabs keep theirs)")
            }
        }
    }

    /// Per-sub-tab reset: clears only that tab's portion of the grade — on the static grade
    /// AND inside every color keyframe, so an animated grade doesn't resurrect the old values.
    private var subTabReset: (() -> Void)? {
        let portion: (inout ColorGrade) -> Void
        switch subTab {
        case .basic:
            portion = { g in
                let keep = (hsl: g.hsl, curves: g.curves, wheels: g.wheels)
                g = ColorGrade(hsl: keep.hsl, curves: keep.curves, wheels: keep.wheels)
            }
        case .hsl:    portion = { $0.hsl = HSLAdjust() }
        case .curves: portion = { $0.curves = CurveSet() }
        case .wheels: portion = { $0.wheels = ColorWheels() }
        case .mask:
            return {
                commitGradeToClips(editor, clips, actionName: "Reset Mask") { c in
                    editor.commitClipProperty(clipId: c.id) { $0.mask = AdjustMask(); $0.maskTrack = nil }
                }
            }
        }
        return {
            commitGradeToClips(editor, clips, actionName: "Reset \(subTab.rawValue)") { c in
                editor.commitClipProperty(clipId: c.id) { clip in
                    portion(&clip.grade)
                    if var track = clip.gradeTrack {
                        for i in track.keyframes.indices { portion(&track.keyframes[i].value) }
                        clip.gradeTrack = track
                    }
                }
            }
        }
    }

}
