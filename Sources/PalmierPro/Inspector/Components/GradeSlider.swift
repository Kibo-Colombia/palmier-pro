import AppKit
import SwiftUI

/// A compact color-grade control: a horizontal track (fill + neutral tick + thumb) and a value,
/// scrubbed by dragging **vertically** (up = increase). Vertical because the inspector is docked on
/// the right with no room to drag horizontally. The throw is long for precision (hold ⇧ for finer);
/// click the value to type; right-click to reset to neutral. An AppKit mouse area drives the drag so
/// it never fights the inspector's scroll view.
struct GradeSlider: View {
    let label: String
    let value: Double?                 // nil = mixed selection
    let range: ClosedRange<Double>
    var neutral: Double = 0
    var format: String = "%.2f"
    var displayMultiplier: Double = 1
    var valueSuffix: String = ""
    /// Vertical points to traverse the whole range — bigger = finer / longer throw.
    var throwPoints: CGFloat = 480
    var onChanged: (Double) -> Void
    var onCommit: (Double) -> Void
    var onReset: () -> Void

    @State private var isDragging = false
    @State private var dragStartValue = 0.0
    @State private var liveValue = 0.0
    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var editFocused: Bool

    private var span: Double { Swift.max(0.0001, range.upperBound - range.lowerBound) }
    private var isMixed: Bool { value == nil && !isDragging }
    private var current: Double { isDragging ? liveValue : (value ?? liveValue) }
    private var fraction: Double { clamp01((current - range.lowerBound) / span) }
    private var neutralFraction: Double { clamp01((neutral - range.lowerBound) / span) }
    private var displayText: String {
        isMixed ? "—" : String(format: format, current * displayMultiplier) + valueSuffix
    }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: 64, alignment: .leading)
            track
            valueLabel
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .overlay { if !isEditing { scrubArea } }
        .onAppear { liveValue = value ?? neutral }
        .onChange(of: value) { _, new in if !isDragging { liveValue = new ?? liveValue } }
        .onChange(of: editFocused) { _, focused in if !focused && isEditing { commitEdit(); isEditing = false } }
    }

    private var track: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(AppTheme.Opacity.faint)).frame(height: 4)
                Capsule().fill(AppTheme.Accent.primary.opacity(0.6))
                    .frame(width: Swift.max(0, w * fraction), height: 4)
                Rectangle().fill(Color.white.opacity(AppTheme.Opacity.muted))
                    .frame(width: 1.5, height: 9)
                    .offset(x: w * neutralFraction - 0.75)
                Circle().fill(isMixed ? AppTheme.Text.tertiaryColor : AppTheme.Accent.primary)
                    .frame(width: 9, height: 9)
                    .offset(x: Swift.max(0, Swift.min(w - 9, w * fraction - 4.5)))
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 22)
    }

    private var valueLabel: some View {
        ZStack(alignment: .trailing) {
            if isEditing {
                TextField("", text: $editText)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium).monospacedDigit())
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .focused($editFocused)
                    .onAppear { editFocused = true }
                    .onSubmit { editFocused = false }
                    .onExitCommand { isEditing = false; editFocused = false }
            } else {
                Text(displayText)
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium).monospacedDigit())
                    .foregroundStyle(isMixed ? AppTheme.Text.tertiaryColor : AppTheme.Accent.primary)
            }
        }
        .frame(width: 48, alignment: .trailing)
    }

    private var scrubArea: some View {
        VerticalScrubArea(
            canScrub: !isMixed,
            onDragStart: { dragStartValue = value ?? liveValue; isDragging = true },
            onDragChanged: { dy, mods in
                var perPoint = span / Double(throwPoints)
                if mods.contains(.shift) { perPoint /= 5 }   // finer
                let next = clampToRange(dragStartValue + Double(dy) * perPoint)
                if next != liveValue { liveValue = next; onChanged(next) }
            },
            onDragEnd: { if isDragging { onCommit(liveValue); isDragging = false } },
            onClick: { editText = isMixed ? "" : String(format: format, current * displayMultiplier); isEditing = true },
            onReset: onReset
        )
    }

    private func commitEdit() {
        let cleaned = editText
            .replacingOccurrences(of: valueSuffix, with: "")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let parsed = Double(cleaned) else { return }
        let mult = displayMultiplier == 0 ? 1 : displayMultiplier
        let raw = clampToRange(parsed / mult)
        liveValue = raw
        onCommit(raw)
    }

    private func clampToRange(_ v: Double) -> Double { Swift.min(range.upperBound, Swift.max(range.lowerBound, v)) }
    private func clamp01(_ v: Double) -> Double { Swift.min(1, Swift.max(0, v)) }
}

/// AppKit mouse area for vertical scrubbing: up = increase. Bypasses SwiftUI gestures so a vertical
/// drag scrubs instead of scrolling the enclosing ScrollView. Left-click (no drag) types; right-click resets.
private struct VerticalScrubArea: NSViewRepresentable {
    var canScrub: Bool
    var onDragStart: () -> Void
    var onDragChanged: (CGFloat, NSEvent.ModifierFlags) -> Void
    var onDragEnd: () -> Void
    var onClick: () -> Void
    var onReset: () -> Void

    func makeNSView(context: Context) -> Area { let v = Area(); apply(v); return v }
    func updateNSView(_ v: Area, context: Context) { apply(v) }
    private func apply(_ v: Area) {
        v.canScrub = canScrub
        v.onDragStart = onDragStart; v.onDragChanged = onDragChanged; v.onDragEnd = onDragEnd
        v.onClick = onClick; v.onReset = onReset
    }

    final class Area: NSView {
        var canScrub = true
        var onDragStart: (() -> Void)?
        var onDragChanged: ((CGFloat, NSEvent.ModifierFlags) -> Void)?
        var onDragEnd: (() -> Void)?
        var onClick: (() -> Void)?
        var onReset: (() -> Void)?

        private var startY: CGFloat = 0
        private var dragging = false

        override var acceptsFirstResponder: Bool { false }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }

        override func mouseDown(with e: NSEvent) { startY = e.locationInWindow.y; dragging = false }

        override func mouseDragged(with e: NSEvent) {
            guard canScrub else { return }
            let dy = e.locationInWindow.y - startY   // AppKit y increases upward → up = positive = increase
            if !dragging && abs(dy) > 3 { dragging = true; onDragStart?() }
            if dragging { onDragChanged?(dy, e.modifierFlags) }
        }

        override func mouseUp(with e: NSEvent) {
            if dragging { onDragEnd?() } else { onClick?() }
            dragging = false
        }

        override func rightMouseDown(with e: NSEvent) { onReset?() }
    }
}
