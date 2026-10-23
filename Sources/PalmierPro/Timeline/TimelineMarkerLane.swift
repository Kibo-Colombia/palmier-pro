import AppKit

/// The strip above the ruler ticks where markers draw as named colored blocks.
@MainActor
enum TimelineMarkerLane {
    private static let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: AppTheme.FontSize.xs, weight: .semibold),
        .foregroundColor: AppTheme.Text.primary,
    ]
    private static let pointLabelMaxWidth: Double = 200
    private static let pointHitSlop: Double = AppTheme.Spacing.xs

    static func draw(_ markers: [TimelineMarker], in rect: NSRect, geometry geo: TimelineGeometry, context ctx: CGContext) {
        ctx.setFillColor(AppTheme.Background.surface.cgColor)
        ctx.fill(rect)
        guard !markers.isEmpty else { return }

        for item in layout(markers, geometry: geo) {
            let block = item.block.offsetBy(dx: 0, dy: Double(rect.minY))
            guard block.maxX >= rect.minX, block.minX <= rect.maxX else { continue }
            let color = AppTheme.MarkerColors.color(item.marker.color)

            ctx.saveGState()
            ctx.clip(to: block)
            if item.marker.isRange {
                let path = CGPath(roundedRect: block, cornerWidth: AppTheme.Radius.xs, cornerHeight: AppTheme.Radius.xs, transform: nil)
                ctx.addPath(path)
                ctx.setFillColor(color.withAlphaComponent(AppTheme.Opacity.medium).cgColor)
                ctx.fillPath()
                ctx.setFillColor(color.cgColor)
                ctx.fill(NSRect(x: block.minX, y: block.minY, width: AppTheme.BorderWidth.thick, height: block.height))
            } else {
                ctx.setFillColor(color.cgColor)
                ctx.fill(NSRect(x: block.minX, y: block.minY, width: AppTheme.BorderWidth.thick, height: block.height))
                ctx.fill(NSRect(x: block.minX, y: block.minY, width: AppTheme.Spacing.sm, height: AppTheme.Spacing.sm))
            }

            let inset = AppTheme.Spacing.xs + AppTheme.BorderWidth.thick
            // Keep the name readable when the block starts left of the visible area.
            let textX = max(block.minX, Double(rect.minX)) + inset
            let label = NSAttributedString(string: item.marker.name, attributes: labelAttrs)
            let textY = block.midY - label.size().height / 2
            if block.maxX - textX > AppTheme.Spacing.smMd {
                label.draw(at: NSPoint(x: textX, y: textY))
            }
            ctx.restoreGState()
        }
    }

    /// Topmost marker under `x` (document coordinates), matching the draw order.
    static func hitTest(_ markers: [TimelineMarker], x: Double, geometry geo: TimelineGeometry) -> TimelineMarker? {
        layout(markers, geometry: geo).reversed().first { item in
            let slop = item.marker.isRange ? 0 : pointHitSlop
            return x >= item.block.minX - slop && x <= item.block.maxX
        }?.marker
    }

    private struct Item {
        let marker: TimelineMarker
        /// Lane-local: y starts at 0.
        let block: NSRect
    }

    /// Longer ranges first so shorter ones (and points) sit on top of them.
    private static func layout(_ markers: [TimelineMarker], geometry geo: TimelineGeometry) -> [Item] {
        let sorted = markers.sorted {
            $0.durationFrames != $1.durationFrames ? $0.durationFrames > $1.durationFrames : $0.startFrame < $1.startFrame
        }
        let top = AppTheme.Spacing.xxs
        let height = max(0, Double(geo.markerLaneHeight) - top * 2)
        let starts = markers.map(\.startFrame).sorted()
        return sorted.map { marker in
            let minX = geo.xForFrame(marker.startFrame)
            let maxX: Double
            if marker.isRange {
                maxX = max(minX + AppTheme.BorderWidth.thick, geo.xForFrame(marker.endFrame))
            } else {
                let nextStart = starts.first { $0 > marker.startFrame }.map(geo.xForFrame) ?? .infinity
                let label = NSAttributedString(string: marker.name, attributes: labelAttrs).size().width
                let natural = Double(AppTheme.Spacing.smMd + label + AppTheme.Spacing.xs)
                maxX = minX + min(natural, pointLabelMaxWidth, max(AppTheme.Spacing.sm, nextStart - minX))
            }
            return Item(marker: marker, block: NSRect(x: minX, y: top, width: maxX - minX, height: height))
        }
    }
}
