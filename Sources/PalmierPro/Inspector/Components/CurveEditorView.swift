import SwiftUI

/// An interactive tone-curve editor: a square canvas with a grid, the identity diagonal,
/// the evaluated spline (same Fritsch–Carlson evaluator the render uses, so what you see is
/// exactly what bakes), and draggable control points.
///
/// Interactions: drag a point to move it (x clamped between its neighbors) · drag on empty
/// curve to add a point there · drag a point far outside the canvas to delete it ·
/// right-click resets the channel. Empty points = identity (seeded with (0,0),(1,1) plus
/// the new point on first touch).
struct CurveEditorView: View {
    let points: [CurvePoint]           // committed points for the active channel
    let accent: Color
    let onChange: ([CurvePoint]) -> Void
    let onCommit: ([CurvePoint]) -> Void
    let onReset: () -> Void

    @State private var livePoints: [CurvePoint]? = nil   // non-nil while dragging
    @State private var dragIndex: Int? = nil

    private let hitRadius: CGFloat = 12
    private let deleteMargin: CGFloat = 44
    private let minGap: Double = 0.02

    private var displayPoints: [CurvePoint] { livePoints ?? points }
    /// The points as drawn: identity endpoints stand in when the channel is empty.
    private var drawnPoints: [CurvePoint] {
        displayPoints.isEmpty ? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)] : displayPoints
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, canvasSize in
                drawGrid(ctx, canvasSize)
                drawCurve(ctx, canvasSize)
                drawPoints(ctx, canvasSize)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(size))
            .contextMenu {
                Button("Reset Channel") { onReset() }
            }
        }
        .aspectRatio(1.35, contentMode: .fit)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(Color.black.opacity(AppTheme.Opacity.subtle))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(Color.white.opacity(AppTheme.Opacity.faint), lineWidth: AppTheme.BorderWidth.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
    }

    // MARK: - Drawing

    private func drawGrid(_ ctx: GraphicsContext, _ size: CGSize) {
        var grid = Path()
        for i in 1..<4 {
            let f = CGFloat(i) / 4
            grid.move(to: CGPoint(x: f * size.width, y: 0))
            grid.addLine(to: CGPoint(x: f * size.width, y: size.height))
            grid.move(to: CGPoint(x: 0, y: f * size.height))
            grid.addLine(to: CGPoint(x: size.width, y: f * size.height))
        }
        ctx.stroke(grid, with: .color(.white.opacity(0.06)), lineWidth: 1)

        var diagonal = Path()
        diagonal.move(to: toCanvas(CurvePoint(x: 0, y: 0), size))
        diagonal.addLine(to: toCanvas(CurvePoint(x: 1, y: 1), size))
        ctx.stroke(diagonal, with: .color(.white.opacity(0.12)), lineWidth: 1)
    }

    private func drawCurve(_ ctx: GraphicsContext, _ size: CGSize) {
        let table = GradeMath.sampleCurve(drawnPoints, count: 128)
        var path = Path()
        for (i, y) in table.enumerated() {
            let p = toCanvas(CurvePoint(x: Double(i) / 127, y: Double(y)), size)
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        ctx.stroke(path, with: .color(accent), lineWidth: 2)
    }

    private func drawPoints(_ ctx: GraphicsContext, _ size: CGSize) {
        guard !displayPoints.isEmpty else { return }
        for (i, pt) in displayPoints.enumerated() {
            let c = toCanvas(pt, size)
            let r: CGFloat = dragIndex == i ? 6 : 4.5
            let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(.white))
            ctx.stroke(Path(ellipseIn: rect), with: .color(accent), lineWidth: 1.5)
        }
    }

    // MARK: - Gesture

    private func dragGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                var pts = livePoints ?? seededPoints()
                let model = fromCanvas(value.location, size)

                if dragIndex == nil {
                    // Grab an existing point if the drag starts near one, else add one here.
                    if let i = nearestPointIndex(in: pts, to: value.startLocation, size: size) {
                        dragIndex = i
                    } else {
                        let newPoint = CurvePoint(x: model.x, y: model.y)
                        let at = pts.firstIndex { $0.x > newPoint.x } ?? pts.endIndex
                        pts.insert(newPoint, at: at)
                        dragIndex = at
                    }
                }

                guard let i = dragIndex, pts.indices.contains(i) else { return }
                // Off-canvas by a wide margin = delete (shown live by dropping the point).
                let out = value.location.x < -deleteMargin || value.location.x > size.width + deleteMargin
                    || value.location.y < -deleteMargin || value.location.y > size.height + deleteMargin
                if out && pts.count > 1 {
                    pts.remove(at: i)
                    dragIndex = nil
                } else {
                    let lo = i > 0 ? pts[i - 1].x + minGap : 0
                    let hi = i < pts.count - 1 ? pts[i + 1].x - minGap : 1
                    pts[i] = CurvePoint(x: min(max(model.x, lo), max(lo, hi)), y: min(max(model.y, 0), 1))
                }
                livePoints = pts
                onChange(pts)
            }
            .onEnded { _ in
                let final = livePoints ?? points
                dragIndex = nil
                livePoints = nil
                // Two points sitting exactly on the diagonal = identity → store empty.
                onCommit(CurveSet.channelIsIdentity(final) ? [] : final)
            }
    }

    /// First touch on an identity channel seeds the endpoints so the user drags a real point set.
    private func seededPoints() -> [CurvePoint] {
        displayPoints.isEmpty ? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)] : displayPoints
    }

    private func nearestPointIndex(in pts: [CurvePoint], to location: CGPoint, size: CGSize) -> Int? {
        var best: (Int, CGFloat)? = nil
        for (i, pt) in pts.enumerated() {
            let c = toCanvas(pt, size)
            let d = hypot(c.x - location.x, c.y - location.y)
            if d <= hitRadius && (best == nil || d < best!.1) { best = (i, d) }
        }
        return best?.0
    }

    // MARK: - Coordinate mapping (y is flipped: canvas y-down, curve y-up)

    private func toCanvas(_ p: CurvePoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(p.x) * size.width, y: (1 - CGFloat(p.y)) * size.height)
    }

    private func fromCanvas(_ p: CGPoint, _ size: CGSize) -> CurvePoint {
        CurvePoint(
            x: Double(min(max(p.x / max(size.width, 1), 0), 1)),
            y: Double(min(max(1 - p.y / max(size.height, 1), 0), 1))
        )
    }
}
