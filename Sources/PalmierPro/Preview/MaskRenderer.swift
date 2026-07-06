import CoreImage
import Foundation

/// Builds the grayscale mask image for an `AdjustMask` — white where the grade applies,
/// black where the original shows (CIBlendWithMask semantics; `invert` flips it).
///
/// Shapes are generated analytically (gradient generators, no raster blur except the
/// rectangle) in the clip's DISPLAY space (oriented pixels, CI y-up), rotated about the
/// mask center, then mapped into the clip's source space with the same flip-sandwich the
/// compositor uses for geometry — so the mask lands exactly where the on-canvas controls say.
enum MaskRenderer {
    private static let white = CIColor(red: 1, green: 1, blue: 1)
    private static let black = CIColor(red: 0, green: 0, blue: 0)

    /// - Parameters:
    ///   - natSize: the clip's display (oriented) size in pixels — mask coords are normalized to it.
    ///   - displayToSourceCI: display-CI → source-CI pixel transform
    ///     (`flipY(natH) · preferredTransform⁻¹ · flipY(srcH)`; identity for canvas-space masks).
    ///   - extent: the source-space rect to crop the (infinite) mask to.
    static func image(for mask: AdjustMask, natSize: CGSize,
                      displayToSourceCI: CGAffineTransform, extent: CGRect) -> CIImage {
        let w = max(1, natSize.width)
        let h = max(1, natSize.height)
        // Display-CI center (y-up): normalized y-down center flips.
        let center = CGPoint(x: mask.centerX * w, y: h - mask.centerY * h)
        let feather = min(1, max(0, mask.feather))

        // Shape generated centered at the origin (display-CI orientation), then placed.
        let shape: CIImage
        switch mask.shape {
        case .none:
            return CIImage(color: .white).cropped(to: extent)

        case .radial:
            let rx = max(1, mask.width * w)
            let ry = max(1, mask.height * h)
            let R = max(rx, ry)
            let r0 = max(0, R * (1 - feather))
            let r1 = max(r0 + 0.5, R)
            let circle = CIImage(color: .black).applyingFilter("CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0),
                "inputRadius0": r0,
                "inputRadius1": r1,
                "inputColor0": white,
                "inputColor1": black,
            ])
            // Anisotropic scale turns the analytic circle into the ellipse (feather scales along).
            shape = circle.transformed(by: CGAffineTransform(scaleX: rx / R, y: ry / R))

        case .linear:
            // One-sided: white above the line (rotate to grade any direction).
            let halfBand = max(0.5, feather * min(w, h) * 0.5)
            shape = CIImage(color: .black).applyingFilter("CISmoothLinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: -halfBand),
                "inputPoint1": CIVector(x: 0, y: halfBand),
                "inputColor0": black,
                "inputColor1": white,
            ])

        case .mirror:
            // Symmetric band |y| < halfHeight, feathered on both edges.
            let halfHeight = max(1, mask.height * h * 0.5)
            let f = max(0.5, feather * halfHeight)
            let rising = CIImage(color: .black).applyingFilter("CISmoothLinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: -halfHeight - f),
                "inputPoint1": CIVector(x: 0, y: -halfHeight + f),
                "inputColor0": black,
                "inputColor1": white,
            ])
            let falling = CIImage(color: .black).applyingFilter("CISmoothLinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: halfHeight - f),
                "inputPoint1": CIVector(x: 0, y: halfHeight + f),
                "inputColor0": white,
                "inputColor1": black,
            ])
            shape = rising.applyingFilter("CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: falling
            ])

        case .rectangle:
            let rw = max(1, mask.width * w)
            let rh = max(1, mask.height * h)
            let rect = CIImage(color: .white)
                .cropped(to: CGRect(x: -rw / 2, y: -rh / 2, width: rw, height: rh))
                .composited(over: CIImage(color: .black))
            let blur = feather * min(rw, rh) * 0.5
            shape = blur > 0.25
                ? rect.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": blur])
                : rect
        }

        // Place: rotate about the origin (screen-clockwise = negative in y-up coords),
        // translate to the mask center, then display-CI → source-CI, then crop.
        var t = CGAffineTransform(rotationAngle: -mask.rotation * .pi / 180)
        t = t.concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        t = t.concatenating(displayToSourceCI)
        var img = shape.transformed(by: t)
        if mask.invert {
            img = img.applyingFilter("CIColorInvert")
        }
        return img.cropped(to: extent)
    }
}
