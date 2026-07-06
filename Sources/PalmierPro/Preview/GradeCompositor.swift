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
    let cube: LUTCube?                      // resolved (and skin-protected) at instruction-build time so the compositor never touches disk
    let correctionCube: LUTCube?            // pre-baked for STATIC grades; nil when keyframed (fetched from GradeCubeCache per frame)

    init(clip: Clip, natSize: CGSize, preferredTransform: CGAffineTransform,
         cube: LUTCube?, correctionCube: LUTCube? = nil) {
        self.clip = clip
        self.natSize = natSize
        self.preferredTransform = preferredTransform
        self.cube = cube
        self.correctionCube = correctionCube
    }
}

struct GradeTrackRender: Sendable {
    let trackID: CMPersistentTrackID
    let hidden: Bool
    let clips: [GradeClipRender]            // sequential clips sharing this composition track
    /// Timeline track position (0 = frontmost) — orders media vs adjustment layers in the paint.
    let timelineTrackIndex: Int

    init(trackID: CMPersistentTrackID, hidden: Bool, clips: [GradeClipRender], timelineTrackIndex: Int = 0) {
        self.trackID = trackID
        self.hidden = hidden
        self.clips = clips
        self.timelineTrackIndex = timelineTrackIndex
    }
}

/// A media-less adjustment-layer clip: its grade (+ canvas-space mask) applies to the
/// composited result of everything on lower tracks, across the clip's timeline range.
struct GradeAdjustmentRender: Sendable {
    let clip: Clip
    let cube: LUTCube?
    let correctionCube: LUTCube?
    let timelineTrackIndex: Int
    let hidden: Bool
}

/// One snapshot of everything the compositor needs, distilled to Sendable values.
struct GradeRenderModel: Sendable {
    let fps: Int
    let renderSize: CGSize
    /// Video tracks in `trackMappings` order (same order the built-in layer instructions use:
    /// array[0] is frontmost, last is backmost). We paint back-to-front, i.e. reversed, over black.
    let tracks: [GradeTrackRender]
    let adjustments: [GradeAdjustmentRender]

    init(fps: Int, renderSize: CGSize, tracks: [GradeTrackRender], adjustments: [GradeAdjustmentRender] = []) {
        self.fps = fps
        self.renderSize = renderSize
        self.tracks = tracks
        self.adjustments = adjustments
    }

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

    // Creative LUTs (and our synthesized looks) are authored in gamma-encoded sRGB. Telling
    // CIColorCubeWithColorSpace to sample in sRGB stops CI from converting to linear light first,
    // which would wash the look out.
    static let lutColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

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

            // Merge media tracks and adjustment layers into one back-to-front paint sequence:
            // larger timeline index = further back = painted first; at the same index the
            // track's own media paints before its adjustment applies.
            enum PaintStep { case media(GradeTrackRender); case adjustment(GradeAdjustmentRender) }
            var steps: [(index: Int, order: Int, step: PaintStep)] =
                model.tracks.map { ($0.timelineTrackIndex, 0, .media($0)) }
            steps.append(contentsOf: model.adjustments.map { ($0.timelineTrackIndex, 1, .adjustment($0)) })
            steps.sort { a, b in a.index != b.index ? a.index > b.index : a.order < b.order }

            for entry in steps {
                if case .adjustment(let adj) = entry.step {
                    if !adj.hidden, frame >= adj.clip.startFrame, frame < adj.clip.endFrame {
                        output = Self.applyAdjustmentLayer(adj, frame: frame, to: output, renderSize: renderSize)
                    }
                    continue
                }
                guard case .media(let track) = entry.step, !track.hidden else { continue }
                guard let cr = model.clip(onTrack: track, atFrame: frame),
                      let srcBuffer = request.sourceFrame(byTrackID: track.trackID) else { continue }

                var img = CIImage(cvPixelBuffer: srcBuffer)
                let sourceHeight = img.extent.height

                // 1. Grade in the clip's own space (before geometry/opacity), per the chosen render order.
                // An active mask limits the grade spatially: graded-over-original via CIBlendWithMask.
                let grade = cr.clip.gradeAt(frame: frame)
                if !grade.isIdentity {
                    let correction = cr.correctionCube
                        ?? (grade.needsCorrectionCube ? GradeCubeCache.shared.correctionCube(for: grade) : nil)
                    let graded = Self.applyGrade(grade, cube: cr.cube, correctionCube: correction, to: img)
                    let mask = cr.clip.maskAt(frame: frame)
                    if mask.isIdentity {
                        img = graded
                    } else {
                        let displayToSourceCI = Self.flipY(cr.natSize.height)
                            .concatenating(cr.preferredTransform.inverted())
                            .concatenating(Self.flipY(sourceHeight))
                        let maskImage = MaskRenderer.image(
                            for: mask, natSize: cr.natSize,
                            displayToSourceCI: displayToSourceCI, extent: img.extent)
                        img = graded.applyingFilter("CIBlendWithMask", parameters: [
                            kCIInputBackgroundImageKey: img,
                            kCIInputMaskImageKey: maskImage,
                        ])
                    }
                }

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

                // 2b. Vignette on the visible (post-crop) extent — pre-crop it would sit off-center
                // on cropped clips.
                if grade.vignette > 0 {
                    img = Self.applyVignette(img, amount: grade.vignette)
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

    /// Edge darkening centered on the image's extent (CIVignetteEffect for the explicit center).
    static func applyVignette(_ image: CIImage, amount: Double) -> CIImage {
        let ext = image.extent
        guard ext.width > 1, ext.height > 1 else { return image }
        return image.applyingFilter("CIVignetteEffect", parameters: [
            "inputCenter": CIVector(x: ext.midX, y: ext.midY),
            "inputRadius": max(ext.width, ext.height) * 0.75,
            "inputIntensity": min(1, max(0, amount)),
            "inputFalloff": 0.5,
        ]).cropped(to: ext)
    }

    /// Apply an adjustment layer's grade (+ canvas-space mask) to the composited stack below it.
    /// The layer's clip opacity scales the whole grade (free CapCut parity: fading an adjustment
    /// layer fades its effect), and its vignette darkens the composite.
    static func applyAdjustmentLayer(_ adj: GradeAdjustmentRender, frame: Int,
                                     to output: CIImage, renderSize: CGSize) -> CIImage {
        var grade = adj.clip.gradeAt(frame: frame)
        let opacity = adj.clip.opacityAt(frame: frame)
        if opacity < 1 { grade.intensity *= max(0, opacity) }
        guard !grade.isIdentity, grade.intensity > 0 else { return output }

        let correction = adj.correctionCube
            ?? (grade.needsCorrectionCube ? GradeCubeCache.shared.correctionCube(for: grade) : nil)
        let graded = applyGrade(grade, cube: adj.cube, correctionCube: correction, to: output)

        var result: CIImage
        let mask = adj.clip.maskAt(frame: frame)
        if mask.isIdentity {
            result = graded
        } else {
            // Canvas space: natSize = renderSize and no display→source mapping needed.
            let maskImage = MaskRenderer.image(
                for: mask, natSize: renderSize,
                displayToSourceCI: .identity, extent: output.extent)
            result = graded.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: output,
                kCIInputMaskImageKey: maskImage,
            ])
        }
        if grade.vignette > 0 {
            result = applyVignette(result, amount: grade.vignette * grade.intensity)
        }
        return result
    }

    /// The color-correction CIFilter chain (vignette excluded — it is spatial and runs post-crop
    /// in `startRequest`). Identity grade is a no-op passthrough. Order:
    /// LUT → exposure → color controls → temperature/tint → correction cube (wheels/curves/HSL/tonal)
    /// → hue → sharpen → clarity → intensity (wet/dry) mix.
    static func applyGrade(_ grade: ColorGrade, cube: LUTCube?, correctionCube: LUTCube? = nil,
                           to image: CIImage) -> CIImage {
        guard !grade.isIdentity else { return image }
        var img = image

        // LUT base look first — everything below rides on top of it. Its own lookIntensity
        // mixes the cube result back over the ungraded image. Skin-tone protection is already
        // baked into the cube (see GradeMath.skinProtected), so it costs nothing here.
        if grade.lut != nil, let cube {
            let looked = img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": cube.dimension,
                "inputCubeData": cube.data,
                "inputColorSpace": lutColorSpace,
            ]).cropped(to: img.extent)
            let li = CGFloat(max(0, min(1, grade.lookIntensity)))
            img = li >= 1 ? looked
                : looked.applyingFilter("CIColorMatrix",
                    parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: li)]).composited(over: img)
        }

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

        // Secondary corrections — wheels → curves → HSL → highlights/shadows → fade, pre-baked
        // into one 3D cube (GradeMath). Sampled in the same gamma sRGB space as creative LUTs.
        if grade.needsCorrectionCube, let correctionCube {
            img = img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": correctionCube.dimension,
                "inputCubeData": correctionCube.data,
                "inputColorSpace": lutColorSpace,
            ])
        }

        if grade.hue != 0 {
            img = img.applyingFilter("CIHueAdjust", parameters: [
                "inputAngle": grade.hue * .pi / 180
            ])
        }
        if grade.sharpen > 0 {
            img = img.applyingFilter("CISharpenLuminance", parameters: [
                "inputSharpness": min(1, max(0, grade.sharpen)) * 1.6
            ])
        }
        if grade.clarity > 0 {
            // Local contrast: wide-radius unsharp mask scaled to the source size so the
            // effect strength is resolution-stable.
            let radius = max(2, min(image.extent.width, image.extent.height) / 40)
            img = img.applyingFilter("CIUnsharpMask", parameters: [
                "inputRadius": radius,
                "inputIntensity": min(1, max(0, grade.clarity)) * 0.8
            ])
        }

        // Keep extent stable through color/convolution filters, then mix wet/dry by intensity.
        img = img.cropped(to: image.extent)
        if grade.intensity < 1 {
            let a = CGFloat(max(0, min(1, grade.intensity)))
            let wet = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)])
            img = wet.composited(over: image)
        }
        return img
    }
}
