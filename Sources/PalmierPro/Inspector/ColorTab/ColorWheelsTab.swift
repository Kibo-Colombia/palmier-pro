import SwiftUI

/// The Wheels color sub-tab: lift (shadows) / gamma (midtones) / gain (highlights) / offset,
/// each a 2D color wheel plus a luma slider. Rendered through the correction cube with the
/// conventional LGG formula (see GradeMath.applyWheels).
struct ColorWheelsTab: View {
    @Environment(EditorViewModel.self) var editor
    let clips: [Clip]

    private struct Wheel {
        let name: String
        let hint: String
        let keyPath: WritableKeyPath<ColorGrade, WheelAdjust>
        let lumaPath: WritableKeyPath<ColorGrade, Double>
    }

    private let wheels: [Wheel] = [
        Wheel(name: "Lift", hint: "Shadows", keyPath: \.wheels.lift, lumaPath: \.wheels.lift.luma),
        Wheel(name: "Gamma", hint: "Midtones", keyPath: \.wheels.gamma, lumaPath: \.wheels.gamma.luma),
        Wheel(name: "Gain", hint: "Highlights", keyPath: \.wheels.gain, lumaPath: \.wheels.gain.luma),
        Wheel(name: "Offset", hint: "Everything", keyPath: \.wheels.offset, lumaPath: \.wheels.offset.luma),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            ForEach(wheels, id: \.name) { wheel in
                wheelRow(wheel)
            }
            Text("Drag inside a wheel to shift its color balance · double-click recenters")
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
    }

    private func wheelRow(_ wheel: Wheel) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            ColorWheelControl(
                value: sharedClipValue(clips) { $0.grade[keyPath: wheel.keyPath] },
                onChanged: { v in
                    for c in clips { editor.applyClipProperty(clipId: c.id) { $0.grade[keyPath: wheel.keyPath] = v } }
                },
                onCommit: { v in
                    commitGradeToClips(editor, clips, actionName: "Adjust \(wheel.name)") { c in
                        editor.commitClipProperty(clipId: c.id) { $0.grade[keyPath: wheel.keyPath] = v }
                    }
                }
            )
            .frame(width: 76, height: 76)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(wheel.name)
                        .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Text(wheel.hint)
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                    Spacer()
                    resetWheelButton(wheel)
                }
                GradeSliderRow(label: "Luma", clips: clips, range: -1...1, neutral: 0,
                               keyPath: wheel.lumaPath,
                               format: "%.0f", multiplier: 100,
                               action: "Adjust \(wheel.name) Luma")
            }
        }
    }

    private func resetWheelButton(_ wheel: Wheel) -> some View {
        Button {
            commitGradeToClips(editor, clips, actionName: "Reset \(wheel.name)") { c in
                editor.commitClipProperty(clipId: c.id) { $0.grade[keyPath: wheel.keyPath] = WheelAdjust() }
            }
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help("Reset \(wheel.name)")
    }
}
