import SwiftUI

/// A 2D lift/gamma/gain-style color wheel. Dragging from the center pushes the wheel's RGB
/// toward the hue under the drag: `rgb = m·(cosθ, cos(θ−120°), cos(θ+120°))` — a zero-sum
/// push (r+g+b = 0) so the wheel shifts balance, and the separate luma slider shifts level.
/// Double-click resets the wheel's RGB (luma untouched).
struct ColorWheelControl: View {
    let value: WheelAdjust?            // nil = mixed selection
    let onChanged: (WheelAdjust) -> Void
    let onCommit: (WheelAdjust) -> Void

    @State private var isDragging = false
    @State private var liveValue = WheelAdjust()

    private var current: WheelAdjust { isDragging ? liveValue : (value ?? WheelAdjust()) }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            ZStack {
                // Hue ring: red at 3 o'clock, green up, blue down-left — matches the drag math.
                Circle()
                    .fill(AngularGradient(
                        colors: [.red, Color(red: 1, green: 0, blue: 1), .blue,
                                 Color(red: 0, green: 1, blue: 1), .green, .yellow, .red],
                        center: .center))
                    .overlay(
                        Circle().fill(RadialGradient(
                            colors: [Color(white: 0.25), Color(white: 0.25).opacity(0)],
                            center: .center, startRadius: 0, endRadius: radius)))
                    .overlay(Circle().strokeBorder(
                        Color.white.opacity(AppTheme.Opacity.muted),
                        lineWidth: AppTheme.BorderWidth.hairline))
                    .frame(width: size, height: size)

                // Crosshair at neutral.
                Path { p in
                    p.move(to: CGPoint(x: center.x - 5, y: center.y))
                    p.addLine(to: CGPoint(x: center.x + 5, y: center.y))
                    p.move(to: CGPoint(x: center.x, y: center.y - 5))
                    p.addLine(to: CGPoint(x: center.x, y: center.y + 5))
                }
                .stroke(Color.white.opacity(AppTheme.Opacity.muted), lineWidth: 1)

                // The value dot.
                let dot = dotPosition(current, center: center, radius: radius)
                Circle()
                    .fill(.white)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 1))
                    .position(dot)
            }
            .contentShape(Circle().path(in: CGRect(x: center.x - radius, y: center.y - radius,
                                                   width: size, height: size)))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !isDragging {
                            isDragging = true
                            liveValue = value ?? WheelAdjust()
                        }
                        let dx = (g.location.x - center.x) / radius
                        let dy = (g.location.y - center.y) / radius
                        let m = min(1, hypot(dx, dy))
                        let theta = atan2(-dy, dx)   // screen y-down → math y-up
                        var v = liveValue
                        v.r = Double(m) * cos(Double(theta))
                        v.g = Double(m) * cos(Double(theta) - 2 * .pi / 3)
                        v.b = Double(m) * cos(Double(theta) + 2 * .pi / 3)
                        liveValue = v
                        onChanged(v)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onCommit(liveValue)
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    var v = value ?? WheelAdjust()
                    v.r = 0; v.g = 0; v.b = 0
                    onCommit(v)
                }
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// Inverse of the drag decomposition: `m·cosθ = r`, `m·sinθ = (g − b)/√3`.
    private func dotPosition(_ v: WheelAdjust, center: CGPoint, radius: CGFloat) -> CGPoint {
        let x = CGFloat(v.r)
        let y = CGFloat((v.g - v.b) / 3.0.squareRoot())
        return CGPoint(x: center.x + x * radius, y: center.y - y * radius)
    }
}
