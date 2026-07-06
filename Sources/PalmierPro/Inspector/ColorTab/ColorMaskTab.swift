import SwiftUI

/// The Mask color sub-tab: limits WHERE the clip's grade applies. Shape picker plus
/// position/size/rotation/feather sliders and an invert toggle. Coordinates are normalized
/// to the clip's visible frame, so the mask travels with the clip.
struct ColorMaskTab: View {
    @Environment(EditorViewModel.self) var editor
    let clips: [Clip]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            shapePicker
            if activeShape != MaskShape.none {
                editOnCanvasToggle
                maskSlider("Center X", \.centerX, range: 0...1, neutral: 0.5)
                maskSlider("Center Y", \.centerY, range: 0...1, neutral: 0.5)
                if activeShape != .linear {
                    if activeShape != .mirror {
                        maskSlider("Width", \.width, range: 0.02...2, neutral: 0.5)
                    }
                    maskSlider("Height", \.height, range: 0.02...2, neutral: 0.5)
                }
                maskSlider("Rotation", \.rotation, range: -180...180, neutral: 0, format: "%.0f", suffix: "°")
                maskSlider("Feather", \.feather, range: 0...1, neutral: 0.1, format: "%.0f", multiplier: 100, suffix: "%")
                invertToggle
                Text("The grade applies inside the mask (invert flips it) · masks animate via the Mask keyframe lane")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            } else {
                Text("Pick a shape to limit where the color grade applies.")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .padding(.vertical, AppTheme.Spacing.xs)
            }
        }
        .onDisappear { editor.maskEditingActive = false }
    }

    /// Shows the draggable mask controls in the preview (Esc or re-click exits).
    private var editOnCanvasToggle: some View {
        let on = editor.maskEditingActive
        return Button {
            editor.maskEditingActive.toggle()
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "hand.draw")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                Text(on ? "Editing on canvas" : "Edit on canvas")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
            }
            .foregroundStyle(on ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(Color.white.opacity(on ? AppTheme.Opacity.muted : AppTheme.Opacity.subtle))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(clips.count != 1)
        .help(clips.count == 1 ? "Drag the mask directly in the preview (Esc exits)"
                               : "Select a single clip to edit the mask on canvas")
    }

    /// The shape shared by every selected clip, or nil when mixed.
    private var activeShape: MaskShape? {
        sharedClipValue(clips) { $0.mask.shape }
    }

    private var shapePicker: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            ForEach(MaskShape.allCases, id: \.self) { shape in
                let selected = activeShape == shape
                Button {
                    commitGradeToClips(editor, clips, actionName: "Set Mask Shape") { c in
                        editor.commitClipProperty(clipId: c.id) { $0.mask.shape = shape }
                    }
                } label: {
                    VStack(spacing: AppTheme.Spacing.xxs) {
                        Image(systemName: shape.sfSymbolName)
                            .font(.system(size: AppTheme.FontSize.md))
                            .foregroundStyle(selected ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                            .frame(width: 36, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                    .fill(selected ? Color.white.opacity(AppTheme.Opacity.subtle) : Color.clear)
                            )
                        Text(shape.displayName)
                            .font(.system(size: AppTheme.FontSize.xxs))
                            .foregroundStyle(selected ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(shape.displayName)
            }
            Spacer()
        }
        .padding(.vertical, AppTheme.Spacing.xxs)
    }

    private func maskSlider(
        _ label: String, _ kp: WritableKeyPath<AdjustMask, Double>,
        range: ClosedRange<Double>, neutral: Double,
        format: String = "%.2f", multiplier: Double = 1, suffix: String = ""
    ) -> some View {
        GradeSlider(
            label: label,
            value: sharedClipValue(clips) { $0.mask[keyPath: kp] },
            range: range, neutral: neutral, format: format,
            displayMultiplier: multiplier, valueSuffix: suffix,
            onChanged: { v in
                for c in clips { editor.applyClipProperty(clipId: c.id) { $0.mask[keyPath: kp] = v } }
            },
            onCommit: { v in
                commitGradeToClips(editor, clips, actionName: "Adjust Mask") { c in
                    editor.commitClipProperty(clipId: c.id) { $0.mask[keyPath: kp] = v }
                }
            },
            onReset: {
                commitGradeToClips(editor, clips, actionName: "Adjust Mask") { c in
                    editor.commitClipProperty(clipId: c.id) { $0.mask[keyPath: kp] = neutral }
                }
            }
        )
    }

    private var invertToggle: some View {
        let shared = sharedClipValue(clips) { $0.mask.invert }
        return HStack(spacing: AppTheme.Spacing.sm) {
            Text("Invert")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer()
            Toggle("", isOn: Binding(
                get: { shared ?? false },
                set: { on in
                    commitGradeToClips(editor, clips, actionName: "Invert Mask") { c in
                        editor.commitClipProperty(clipId: c.id) { $0.mask.invert = on }
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .help("Grade outside the shape instead of inside")
    }
}
