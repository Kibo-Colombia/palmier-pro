import AVFoundation
import CoreImage

/// Per-clip color grading compositor.
///
/// Installing a custom `AVVideoCompositing` REPLACES AVFoundation's built-in compositor: it hands
/// us raw, untransformed per-track source frames and we are responsible for ALL compositing. So this
/// reproduces Koma's geometry (crop → transform → opacity → layer over black) in Core Image and adds
/// the per-clip grade. It is the same `CompositionResult.videoComposition` for preview, export,
/// range-render, and inspect_timeline, so a grade is identical everywhere.
///
/// It is engaged ONLY when some visible clip has a non-identity grade (see CompositionBuilder.buildVisuals);
/// ungraded projects keep the stock built-in-compositor path untouched.
///
/// Coordinate conversion (proven against the built-in compositor in spikes/GeometrySpike.swift):
///   AVFoundation layer transforms are top-left / Y-down; Core Image is bottom-left / Y-up.
///   The match across identity, scale+offset, and flip cases is the flip-sandwich:
///       tCI = flipY(sourceHeight) · tAV · flipY(renderHeight)

// MARK: - Sendable render model carried on the instruction

struct GradeClipRender: Sendable {
    let clip: Clip                          // Sendable; provides transformAt/cropAt/opacityAt/gradeAt
    let natSize: CGSize                     // display (oriented) size — matches CompositionBuilder.affineTransform input
    let preferredTransform: CGAffineTransform
}

struct GradeTrackRender: Sendable {
    let trackID: CMPersistentTrackID
    let hidden: Bool
    let clips: [GradeClipRender]            // sequential clips sharing this composition track
}

/// One snapshot of everything the compositor needs, distilled to Sendable values.
struct GradeRenderModel: Sendable {
    let fps: Int
    let renderSize: CGSize
    /// Video tracks in `trackMappings` order (same order the built-in layer instructions use:
    /// array[0] is frontmost, last is backmost). We paint back-to-front, i.e. reversed, over black.
    let tracks: [GradeTrackRender]

    func clip(onTrack t: GradeTrackRender, atFrame frame: Int) -> GradeClipRender? {
        t.clips.first { frame >= $0.clip.startFrame && frame < $0.clip.endFrame }
    }
}

// MARK: - Custom instruction carrying the model (avoids a global / keeps each composition self-contained)

final class GradeInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let model: GradeRenderModel

    init(timeRange: CMTimeRange, model: GradeRenderModel) {
        self.timeRange = timeRange
        self.model = model
        self.requiredSourceTrackIDs = model.tracks.map { NSNumber(value: $0.trackID) }
        super.init()
    }
}

// MARK: - The compositor

final class GradeCompositor: NSObject, AVVideoCompositing {
    // A single Metal-backed CIContext shared across all requests (CIContext is thread-safe for rendering).
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let instruction = request.videoCompositionInstruction as? GradeInstruction,
                  let dest = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "Koma.GradeCompositor", code: 1))
                return
            }
            let model = instruction.model
            let renderSize = model.renderSize
            let fps = max(1, model.fps)
            let frame = Int((request.compositionTime.seconds * Double(fps)).rounded())

            // Opaque black base (bottommost), like CompositionBuilder's black background track.
            var output = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: renderSize))

            // Paint back-to-front: trackMappings order is front→back, so iterate reversed.
            for track in model.tracks.reversed() where !track.hidden {
                guard let cr = model.clip(onTrack: track, atFrame: frame),
                      let srcBuffer = request.sourceFrame(byTrackID: track.trackID) else { continue }

                var img = CIImage(cvPixelBuffer: srcBuffer)
                let sourceHeight = img.extent.height

                // 1. Grade in the clip's own space (before geometry/opacity), per the chosen render order.
                img = Self.applyGrade(cr.clip.gradeAt(frame: frame), to: img)

                // 2. Crop (source space, top-left) → convert to CI bottom-left and clip.
                let crop = cr.clip.cropAt(frame: frame)
                if !crop.isIdentity {
                    let toSource = cr.preferredTransform.inverted()
                    let displayRect = CGRect(
                        x: crop.left * cr.natSize.width,
                        y: crop.top * cr.natSize.height,
                        width: max(1, crop.visibleWidthFraction * cr.natSize.width),
                        height: max(1, crop.visibleHeightFraction * cr.natSize.height)
                    ).applying(toSource)
                    let ciRect = CGRect(x: displayRect.minX,
                                        y: sourceHeight - displayRect.maxY,
                                        width: displayRect.width,
                                        height: displayRect.height)
                    img = img.cropped(to: ciRect)
                }

                // 3. Transform: AVFoundation matrix → CI space via the proven flip-sandwich.
                let tAV = cr.preferredTransform.concatenating(
                    CompositionBuilder.affineTransform(
                        for: cr.clip.transformAt(frame: frame),
                        natSize: cr.natSize,
                        renderSize: renderSize
                    )
                )
                let tCI = Self.flipY(sourceHeight)
                    .concatenating(tAV)
                    .concatenating(Self.flipY(renderSize.height))
                img = img.transformed(by: tCI).cropped(to: CGRect(origin: .zero, size: renderSize))

                // 4. Opacity (folds static × keyframes × fades) → scale alpha, then composite over the stack.
                let opacity = cr.clip.opacityAt(frame: frame)
                if opacity < 1 {
                    img = img.applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, min(1, opacity))))
                    ])
                }
                output = img.composited(over: output)
            }

            Self.ciContext.render(output, to: dest)
            request.finish(withComposedVideoFrame: dest)
        }
    }

    // MARK: - Helpers

    private static func flipY(_ h: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
    }

    /// The primary-correction CIFilter chain. Identity grade is a no-op passthrough.
    /// Order: exposure → color controls → temperature/tint → intensity (wet/dry) mix.
    static func applyGrade(_ grade: ColorGrade, to image: CIImage) -> CIImage {
        guard !grade.isIdentity else { return image }
        var img = image

        if grade.exposure != 0 {
            img = img.applyingFilter("CIExposureAdjust", parameters: ["inputEV": grade.exposure])
        }
        if grade.brightness != 0 || grade.contrast != 1 || grade.saturation != 1 {
            img = img.applyingFilter("CIColorControls", parameters: [
                "inputBrightness": grade.brightness,
                "inputContrast": grade.contrast,
                "inputSaturation": grade.saturation
            ])
        }
        if grade.temperature != 0 || grade.tint != 0 {
            // +temperature = warmer, +tint = magenta. Modest scale around the 6500K neutral.
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 + grade.temperature * 30, y: grade.tint * 30)
            ])
        }
        // Keep extent stable through color filters, then mix wet/dry by intensity.
        img = img.cropped(to: image.extent)
        if grade.intensity < 1 {
            let a = CGFloat(max(0, min(1, grade.intensity)))
            let wet = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)])
            img = wet.composited(over: image)
        }
        return img
    }
}
