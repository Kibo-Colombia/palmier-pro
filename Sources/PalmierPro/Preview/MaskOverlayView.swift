import SwiftUI

/// On-canvas editor for the color-grade mask: draws the active shape's outline over the
/// selected clip, with drag-to-move, edge handles for width/height, and a rotation handle.
/// Activated from the inspector's Mask sub-tab (`editor.maskEditingActive`, Esc exits).
///
/// Mask coordinates are normalized to the clip's DISPLAY frame; on canvas the visible
/// (cropped) part of that frame maps onto the clip's transform rect, so the math here maps
/// display-normalized → crop-relative → canvas points (and back for gestures).
struct MaskOverlayView: View {
    @Environment(EditorViewModel.self) var editor

    private let accent = AppTheme.Accent.timecodeColor
    private let handleSize: CGFloat = AppTheme.Spacing.smMd

    @State private var dragStart: AdjustMask?

    var body: some View {
        GeometryReader { geo in
            let videoRect = videoContentRect(in: geo.size)
            if let clip = selectedClip, clip.maskAt(frame: editor.activeFrame).shape != .none {
                let frame = editor.activeFrame
                let mask = clip.maskAt(frame: frame)
                let clipRect = clipFrame(clip.transformAt(frame: frame), videoRect: videoRect)
                let crop = clip.cropAt(frame: frame)
                let center = canvasPoint(x: mask.centerX, y: mask.centerY, crop: crop, clipRect: clipRect)
                let extents = canvasExtents(mask, crop: crop, clipRect: clipRect)

                outline(mask: mask, center: center, extents: extents, clipRect: clipRect)
                    .allowsHitTesting(false)

                // Move: a generous invisible puck at the mask center.
                Circle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: 60, height: 60)
                    .position(center)
                    .onHover { $0 ? NSCursor.openHand.push() : NSCursor.pop() }
                    .gesture(moveGesture(clip: clip, crop: crop, clipRect: clipRect))

                // Center dot.
                Circle()
                    .fill(accent)
                    .frame(width: 7, height: 7)
                    .position(center)
                    .allowsHitTesting(false)

                // Size handles (not for linear — it has no extents).
                if mask.shape != .linear {
                    if mask.shape != .mirror {
                        handle(at: offsetPoint(center, dx: extents.width, dy: 0, rotation: mask.rotation))
                            .gesture(sizeGesture(clip: clip, axis: .width, crop: crop, clipRect: clipRect, mask: mask))
                    }
                    handle(at: offsetPoint(center, dx: 0, dy: extents.height, rotation: mask.rotation))
                        .gesture(sizeGesture(clip: clip, axis: .height, crop: crop, clipRect: clipRect, mask: mask))
                }

                // Rotation handle above the shape.
                let rotHandle = offsetPoint(center, dx: 0, dy: -(extents.height + 28), rotation: mask.rotation)
                Circle()
                    .strokeBorder(accent, lineWidth: AppTheme.BorderWidth.medium)
                    .frame(width: handleSize, height: handleSize)
                    .position(rotHandle)
                    .gesture(rotationGesture(clip: clip, center: center))
            }
        }
        .coordinateSpace(name: "maskOverlay")
        .allowsHitTesting(selectedClip != nil)
    }

    // MARK: - Outline drawing

    @ViewBuilder
    private func outline(mask: AdjustMask, center: CGPoint, extents: CGSize, clipRect: CGRect) -> some View {
        Canvas { ctx, _ in
            var path = Path()
            switch mask.shape {
            case .none:
                break
            case .radial:
                path.addEllipse(in: CGRect(x: -extents.width, y: -extents.height,
                                           width: extents.width * 2, height: extents.height * 2))
            case .rectangle:
                path.addRect(CGRect(x: -extents.width, y: -extents.height,
                                    width: extents.width * 2, height: extents.height * 2))
            case .linear:
                path.move(to: CGPoint(x: -clipRect.width, y: 0))
                path.addLine(to: CGPoint(x: clipRect.width, y: 0))
            case .mirror:
                path.move(to: CGPoint(x: -clipRect.width, y: -extents.height))
                path.addLine(to: CGPoint(x: clipRect.width, y: -extents.height))
                path.move(to: CGPoint(x: -clipRect.width, y: extents.height))
                path.addLine(to: CGPoint(x: clipRect.width, y: extents.height))
            }
            let placed = path.applying(
                CGAffineTransform(rotationAngle: mask.rotation * .pi / 180)
                    .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
            )
            ctx.stroke(placed, with: .color(accent), style: StrokeStyle(
                lineWidth: AppTheme.BorderWidth.medium, dash: [6, 4]))
        }
    }

    private func handle(at point: CGPoint) -> some View {
        Rectangle()
            .fill(accent)
            .frame(width: handleSize, height: handleSize)
            .position(point)
    }

    /// A point offset from the center in the mask's rotated axes (screen coords, y down;
    /// positive rotation = clockwise, matching the model).
    private func offsetPoint(_ center: CGPoint, dx: CGFloat, dy: CGFloat, rotation: Double) -> CGPoint {
        let a = rotation * .pi / 180
        let rx = dx * Foundation.cos(a) - dy * Foundation.sin(a)
        let ry = dx * Foundation.sin(a) + dy * Foundation.cos(a)
        return CGPoint(x: center.x + rx, y: center.y + ry)
    }

    // MARK: - Gestures

    private func moveGesture(clip: Clip, crop: Crop, clipRect: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil { dragStart = clip.maskAt(frame: editor.activeFrame) }
                guard let start = dragStart else { return }
                var m = start
                let visW = max(0.0001, crop.visibleWidthFraction)
                let visH = max(0.0001, crop.visibleHeightFraction)
                m.centerX = min(2, max(-1, start.centerX + Double(value.translation.width / clipRect.width) * visW))
                m.centerY = min(2, max(-1, start.centerY + Double(value.translation.height / clipRect.height) * visH))
                apply(m, to: clip)
            }
            .onEnded { _ in commit(clip) }
    }

    private enum SizeAxis { case width, height }

    private func sizeGesture(clip: Clip, axis: SizeAxis, crop: Crop, clipRect: CGRect, mask: AdjustMask) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil { dragStart = clip.maskAt(frame: editor.activeFrame) }
                guard let start = dragStart else { return }
                var m = start
                // Project the drag onto the handle's rotated axis.
                let a = mask.rotation * .pi / 180
                switch axis {
                case .width:
                    let along = Double(value.translation.width) * Foundation.cos(a) + Double(value.translation.height) * Foundation.sin(a)
                    let deltaNorm = along / Double(clipRect.width) * crop.visibleWidthFraction
                    m.width = min(4, max(0.02, start.width + deltaNorm * (start.shape == .radial ? 1 : 2)))
                case .height:
                    let along = -Double(value.translation.width) * Foundation.sin(a) + Double(value.translation.height) * Foundation.cos(a)
                    let deltaNorm = along / Double(clipRect.height) * crop.visibleHeightFraction
                    let factor: Double = (start.shape == .radial) ? 1 : (start.shape == .mirror ? 2 : 2)
                    m.height = min(4, max(0.02, start.height + deltaNorm * factor))
                }
                apply(m, to: clip)
            }
            .onEnded { _ in commit(clip) }
    }

    private func rotationGesture(clip: Clip, center: CGPoint) -> some Gesture {
        DragGesture(coordinateSpace: .named("maskOverlay"))
            .onChanged { value in
                if dragStart == nil { dragStart = clip.maskAt(frame: editor.activeFrame) }
                guard var m = dragStart else { return }
                let dx = value.location.x - center.x
                let dy = value.location.y - center.y
                // Handle sits at -90° (above center); rotation = angle from that reference.
                let angle = Foundation.atan2(dy, dx) * 180 / .pi + 90
                m.rotation = (angle > 180 ? angle - 360 : angle).rounded()
                apply(m, to: clip)
            }
            .onEnded { _ in commit(clip) }
    }

    private func apply(_ mask: AdjustMask, to clip: Clip) {
        editor.applyClipProperty(clipId: clip.id) { $0.mask = mask }
    }

    private func commit(_ clip: Clip) {
        guard let _ = dragStart else { return }
        let final = editor.clipFor(id: clip.id)?.mask
        dragStart = nil
        guard let final else { return }
        editor.undoManager?.beginUndoGrouping()
        editor.commitClipProperty(clipId: clip.id) { $0.mask = final }
        editor.undoManager?.endUndoGrouping()
        editor.undoManager?.setActionName("Adjust Mask")
    }

    // MARK: - Coordinate mapping

    /// Display-normalized mask point → canvas point (through the crop window).
    private func canvasPoint(x: Double, y: Double, crop: Crop, clipRect: CGRect) -> CGPoint {
        let visW = max(0.0001, crop.visibleWidthFraction)
        let visH = max(0.0001, crop.visibleHeightFraction)
        return CGPoint(
            x: clipRect.minX + CGFloat((x - crop.left) / visW) * clipRect.width,
            y: clipRect.minY + CGFloat((y - crop.top) / visH) * clipRect.height
        )
    }

    /// The mask's half-extents in canvas points (radial: radii; rectangle/mirror: half sizes).
    private func canvasExtents(_ mask: AdjustMask, crop: Crop, clipRect: CGRect) -> CGSize {
        let visW = max(0.0001, crop.visibleWidthFraction)
        let visH = max(0.0001, crop.visibleHeightFraction)
        let wPts = CGFloat(mask.width / visW) * clipRect.width
        let hPts = CGFloat(mask.height / visH) * clipRect.height
        switch mask.shape {
        case .radial:
            return CGSize(width: wPts, height: hPts)
        case .rectangle:
            return CGSize(width: wPts / 2, height: hPts / 2)
        case .mirror:
            return CGSize(width: 0, height: hPts / 2)
        case .linear, .none:
            return CGSize(width: 0, height: 0)
        }
    }

    private func videoContentRect(in viewSize: CGSize) -> CGRect {
        let videoAspect = CGFloat(editor.timeline.width) / CGFloat(editor.timeline.height)
        let viewAspect = viewSize.width / viewSize.height
        let w: CGFloat, h: CGFloat
        if viewAspect > videoAspect {
            h = viewSize.height; w = h * videoAspect
        } else {
            w = viewSize.width; h = w / videoAspect
        }
        return CGRect(x: (viewSize.width - w) / 2, y: (viewSize.height - h) / 2, width: w, height: h)
    }

    private func clipFrame(_ t: Transform, videoRect: CGRect) -> CGRect {
        let tl = t.topLeft
        return CGRect(
            x: videoRect.origin.x + tl.x * videoRect.width,
            y: videoRect.origin.y + tl.y * videoRect.height,
            width: t.width * videoRect.width,
            height: t.height * videoRect.height
        )
    }

    // MARK: - Selection (single visual clip, like CropOverlayView)

    private var selectedClip: Clip? {
        guard editor.activePreviewTab == .timeline,
              !editor.selectedClipIds.isEmpty else { return nil }
        var match: Clip?
        for track in editor.timeline.tracks where track.type != .audio {
            for clip in track.clips where editor.selectedClipIds.contains(clip.id) && clip.mediaType != .text {
                if match != nil { return nil }
                match = clip
            }
        }
        return match
    }
}
