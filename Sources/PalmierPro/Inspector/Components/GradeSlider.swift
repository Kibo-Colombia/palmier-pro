import AppKit
import SwiftUI

/// A compact horizontal slider for color-grade channels: label · track (fill + neutral tick +
/// thumb) · value. The thumb follows the pointer — click anywhere on the track to jump, drag to
/// slide; hold ⇧ while dragging for fine relative adjustment; right-click resets to neutral;
/// click the value to type. An AppKit mouse area drives the track so the drag never fights the
/// inspector's scroll view.
struct GradeSlider: View {
    let label: String
    let value: Double?                 // nil = mixed selection
    let range: ClosedRange<Double>
    var neutral: Double = 0
    var format: String = "%.2f"
    var displayMultiplier: Double = 1
    var valueSuffix: String = ""
    var onChanged: (Double) -> Void
    var onCommit: (Double) -> Void
    var onReset: () -> Void

    @State private var isDragging = false
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
            .contentShape(Rectangle())
            .overlay {
                HorizontalScrubArea(
                    canScrub: true,
                    onDragStart: { x, mods in
                        liveValue = value ?? liveValue
                        isDragging = true
                        // Plain press jumps the thumb to the pointer; ⇧ keeps the current
                        // value so the fine drag adjusts from where it was.
                        if !mods.contains(.shift) {
                            update(valueAtX(x, width: w))
                        }
                    },
                    onDragChanged: { x, dx, mods in
                        guard isDragging else { return }
                        if mods.contains(.shift) {
                            update(clampToRange(liveValue + Double(dx) * span / Double(Swift.max(1, w)) / 8))
                        } else {
                            update(valueAtX(x, width: w))
                        }
                    },
                    onDragEnd: {
                        if isDragging { onCommit(liveValue); isDragging = false }
                    },
                    onReset: onReset
                )
            }
        }
        .frame(height: 22)
    }

    private func valueAtX(_ x: CGFloat, width: CGFloat) -> Double {
        range.lowerBound + span * clamp01(Double(x / Swift.max(1, width)))
    }

    private func update(_ next: Double) {
        if next != liveValue { liveValue = next; onChanged(next) }
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
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editText = isMixed ? "" : String(format: format, current * displayMultiplier)
                        isEditing = true
                    }
                    .contextMenu { Button("Reset") { onReset() } }
                    .help("Click to type a value")
            }
        }
        .frame(width: 48, alignment: .trailing)
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

/// AppKit mouse area for horizontal slider scrubbing. Reports x in the view's own coordinates
/// (left = 0) plus per-event deltas for ⇧-fine mode. Bypasses SwiftUI gestures so the press
/// starts scrubbing immediately without wrestling the enclosing ScrollView. Right-click resets.
private struct HorizontalScrubArea: NSViewRepresentable {
    var canScrub: Bool
    var onDragStart: (CGFloat, NSEvent.ModifierFlags) -> Void
    var onDragChanged: (CGFloat, CGFloat, NSEvent.ModifierFlags) -> Void
    var onDragEnd: () -> Void
    var onReset: () -> Void

    func makeNSView(context: Context) -> Area { let v = Area(); apply(v); return v }
    func updateNSView(_ v: Area, context: Context) { apply(v) }
    private func apply(_ v: Area) {
        v.canScrub = canScrub
        v.onDragStart = onDragStart; v.onDragChanged = onDragChanged; v.onDragEnd = onDragEnd
        v.onReset = onReset
    }

    final class Area: NSView {
        var canScrub = true
        var onDragStart: ((CGFloat, NSEvent.ModifierFlags) -> Void)?
        var onDragChanged: ((CGFloat, CGFloat, NSEvent.ModifierFlags) -> Void)?
        var onDragEnd: (() -> Void)?
        var onReset: (() -> Void)?

        private var lastX: CGFloat = 0
        private var active = false

        override var acceptsFirstResponder: Bool { false }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

        override func mouseDown(with e: NSEvent) {
            guard canScrub else { return }
            let x = convert(e.locationInWindow, from: nil).x
            lastX = x
            active = true
            onDragStart?(x, e.modifierFlags)
        }

        override func mouseDragged(with e: NSEvent) {
            guard canScrub, active else { return }
            let x = convert(e.locationInWindow, from: nil).x
            onDragChanged?(x, x - lastX, e.modifierFlags)
            lastX = x
        }

        override func mouseUp(with e: NSEvent) {
            if active { onDragEnd?() }
            active = false
        }

        override func rightMouseDown(with e: NSEvent) { onReset?() }
    }
}
