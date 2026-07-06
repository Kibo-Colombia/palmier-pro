import SwiftUI

/// Shared plumbing for the color sub-tabs (Basic / HSL / Curves / Wheels / Mask).

enum ColorSubTab: String, CaseIterable, Hashable {
    case basic = "Basic"
    case hsl = "HSL"
    case curves = "Curves"
    case wheels = "Wheels"
    case mask = "Mask"
}

/// One undoable action across a set of clips (mirror of InspectorView's commitToClips).
@MainActor
func commitGradeToClips(_ editor: EditorViewModel, _ clips: [Clip], actionName: String, _ commit: (Clip) -> Void) {
    editor.undoManager?.beginUndoGrouping()
    for c in clips { commit(c) }
    editor.undoManager?.endUndoGrouping()
    editor.undoManager?.setActionName(actionName)
}

/// A `GradeSlider` bound to one scalar channel of every selected clip's grade.
/// Live-applies during the drag, commits once (one undo group) on release.
struct GradeSliderRow: View {
    @Environment(EditorViewModel.self) private var editor
    let label: String
    let clips: [Clip]
    let range: ClosedRange<Double>
    var neutral: Double = 0
    let keyPath: WritableKeyPath<ColorGrade, Double>
    var format: String = "%.2f"
    var multiplier: Double = 1
    var suffix: String = ""
    let action: String

    var body: some View {
        GradeSlider(
            label: label,
            value: sharedClipValue(clips) { $0.grade[keyPath: keyPath] },
            range: range, neutral: neutral, format: format,
            displayMultiplier: multiplier, valueSuffix: suffix,
            onChanged: { v in
                for c in clips { editor.applyClipProperty(clipId: c.id) { $0.grade[keyPath: keyPath] = v } }
            },
            onCommit: { v in
                commitGradeToClips(editor, clips, actionName: action) { c in
                    editor.commitClipProperty(clipId: c.id) { $0.grade[keyPath: keyPath] = v }
                }
            },
            onReset: {
                commitGradeToClips(editor, clips, actionName: action) { c in
                    editor.commitClipProperty(clipId: c.id) { $0.grade[keyPath: keyPath] = neutral }
                }
            }
        )
    }
}

/// The muted scrub-hint line shown under a slider stack.
struct GradeScrubHint: View {
    var body: some View {
        Text("Click or drag along a slider · ⇧ drag for fine · right-click resets · click the number to type")
            .font(.system(size: AppTheme.FontSize.xxs))
            .foregroundStyle(AppTheme.Text.mutedColor)
            .padding(.top, AppTheme.Spacing.xxs)
    }
}
