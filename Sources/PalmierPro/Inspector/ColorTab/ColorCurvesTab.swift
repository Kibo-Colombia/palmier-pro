import SwiftUI

/// The Curves color sub-tab: channel picker (combined RGB luma + per-channel R/G/B) over
/// the shared curve editor. Curves render through the correction cube, and the editor uses
/// the identical spline evaluator, so the drawn curve is exactly the baked response.
struct ColorCurvesTab: View {
    @Environment(EditorViewModel.self) var editor
    let clips: [Clip]

    enum Channel: String, CaseIterable {
        case rgb = "RGB"
        case red = "R"
        case green = "G"
        case blue = "B"

        var keyPath: WritableKeyPath<ColorGrade, [CurvePoint]> {
            switch self {
            case .rgb:   \.curves.rgb
            case .red:   \.curves.red
            case .green: \.curves.green
            case .blue:  \.curves.blue
            }
        }

        var accent: Color {
            switch self {
            case .rgb:   .white
            case .red:   Color(red: 0.95, green: 0.35, blue: 0.35)
            case .green: Color(red: 0.35, green: 0.85, blue: 0.4)
            case .blue:  Color(red: 0.4, green: 0.55, blue: 0.95)
            }
        }
    }

    @State private var channel: Channel = .rgb

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            channelPicker
            CurveEditorView(
                points: sharedClipValue(clips) { $0.grade[keyPath: channel.keyPath] } ?? [],
                accent: channel.accent,
                onChange: { pts in
                    let kp = channel.keyPath
                    for c in clips { editor.applyClipProperty(clipId: c.id) { $0.grade[keyPath: kp] = pts } }
                },
                onCommit: { pts in
                    let kp = channel.keyPath
                    commitGradeToClips(editor, clips, actionName: "Adjust \(channel.rawValue) Curve") { c in
                        editor.commitClipProperty(clipId: c.id) { $0.grade[keyPath: kp] = pts }
                    }
                },
                onReset: {
                    let kp = channel.keyPath
                    commitGradeToClips(editor, clips, actionName: "Reset \(channel.rawValue) Curve") { c in
                        editor.commitClipProperty(clipId: c.id) { $0.grade[keyPath: kp] = [] }
                    }
                }
            )
            Text("Drag the curve to add a point · drag a point out to delete · right-click resets")
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
    }

    private var channelPicker: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            ForEach(Channel.allCases, id: \.self) { ch in
                let selected = channel == ch
                let touched = clips.contains { !CurveSet.channelIsIdentity($0.grade[keyPath: ch.keyPath]) }
                Button {
                    channel = ch
                } label: {
                    Text(ch.rawValue)
                        .font(.system(size: AppTheme.FontSize.xs, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? ch.accent : AppTheme.Text.tertiaryColor)
                        .padding(.horizontal, AppTheme.Spacing.sm)
                        .padding(.vertical, AppTheme.Spacing.xxs)
                        .background(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                .fill(selected ? Color.white.opacity(AppTheme.Opacity.subtle) : Color.clear)
                        )
                        .overlay(alignment: .topTrailing) {
                            if touched && !selected {
                                Circle().fill(ch.accent).frame(width: 4, height: 4)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}
