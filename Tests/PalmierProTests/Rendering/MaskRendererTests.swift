import Testing
import Foundation
import CoreImage
@testable import PalmierPro

/// Renders MaskRenderer output to bitmaps and probes pixels: white where the grade should
/// apply, black where the original shows. Also covers the AdjustMask model contract.
@Suite("MaskRenderer")
struct MaskRendererTests {

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Luminance (0…1) of the mask at a normalized display point (y down, like the model).
    private func probe(_ mask: AdjustMask, at nx: Double, _ ny: Double,
                       natSize: CGSize = CGSize(width: 200, height: 100)) -> Double {
        let extent = CGRect(origin: .zero, size: natSize)
        let img = MaskRenderer.image(for: mask, natSize: natSize,
                                     displayToSourceCI: .identity, extent: extent)
        // displayToSourceCI = identity ⇒ output is in display-CI coords (y up): flip the probe y.
        let px = Int(nx * natSize.width)
        let py = Int((1 - ny) * natSize.height)
        var pixel = [UInt8](repeating: 0, count: 4)
        Self.ciContext.render(img, toBitmap: &pixel, rowBytes: 4,
                              bounds: CGRect(x: px, y: py, width: 1, height: 1),
                              format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return Double(pixel[0]) / 255
    }

    @Test("radial: white at center, black outside the ellipse")
    func radial() {
        var m = AdjustMask(shape: .radial, centerX: 0.5, centerY: 0.5, width: 0.2, height: 0.3, feather: 0)
        #expect(probe(m, at: 0.5, 0.5) > 0.95)
        #expect(probe(m, at: 0.95, 0.5) < 0.05)   // outside x radius (0.2·200 = 40px)
        #expect(probe(m, at: 0.5, 0.05) < 0.05)   // outside y radius

        m.invert = true
        #expect(probe(m, at: 0.5, 0.5) < 0.05)
        #expect(probe(m, at: 0.95, 0.5) > 0.95)
    }

    @Test("radial feather produces a soft monotone edge")
    func radialFeather() {
        let m = AdjustMask(shape: .radial, centerX: 0.5, centerY: 0.5, width: 0.3, height: 0.3, feather: 0.6)
        let center = probe(m, at: 0.5, 0.5)
        let mid = probe(m, at: 0.5 + 0.25, 0.5)   // near the outer radius, inside the feather ramp
        let outside = probe(m, at: 0.95, 0.5)
        #expect(center > 0.95)
        #expect(mid > 0.02 && mid < 0.98)
        #expect(outside < 0.05)
        #expect(center >= mid && mid >= outside)
    }

    @Test("linear: grades above the line, respects rotation")
    func linear() {
        let m = AdjustMask(shape: .linear, centerX: 0.5, centerY: 0.5, feather: 0.05)
        #expect(probe(m, at: 0.5, 0.2) > 0.95)   // above the center line (screen top)
        #expect(probe(m, at: 0.5, 0.8) < 0.05)   // below

        var rotated = m
        rotated.rotation = 180
        #expect(probe(rotated, at: 0.5, 0.2) < 0.05)
        #expect(probe(rotated, at: 0.5, 0.8) > 0.95)
    }

    @Test("mirror: band around the line, black on both sides")
    func mirror() {
        let m = AdjustMask(shape: .mirror, centerX: 0.5, centerY: 0.5, height: 0.4, feather: 0.05)
        #expect(probe(m, at: 0.5, 0.5) > 0.95)   // inside the band (half-height 0.2·100 = 20px)
        #expect(probe(m, at: 0.5, 0.1) < 0.05)   // above the band
        #expect(probe(m, at: 0.5, 0.9) < 0.05)   // below the band
    }

    @Test("rectangle: white inside, black outside, offset center honored")
    func rectangle() {
        let m = AdjustMask(shape: .rectangle, centerX: 0.25, centerY: 0.5, width: 0.3, height: 0.6, feather: 0)
        #expect(probe(m, at: 0.25, 0.5) > 0.95)
        #expect(probe(m, at: 0.75, 0.5) < 0.05)
        #expect(probe(m, at: 0.25, 0.05) < 0.05)
    }

    @Test("shape none is all white (grade everywhere)")
    func noneShape() {
        let m = AdjustMask()
        #expect(probe(m, at: 0.1, 0.1) > 0.95)
        #expect(probe(m, at: 0.9, 0.9) > 0.95)
    }

    @Test("mask model round-trips and old JSON decodes with defaults")
    func maskCodable() throws {
        let m = AdjustMask(shape: .mirror, centerX: 0.3, centerY: 0.7, width: 0.9,
                           height: 0.2, rotation: 45, feather: 0.5, invert: true)
        let back = try JSONDecoder().decode(AdjustMask.self, from: JSONEncoder().encode(m))
        #expect(back == m)

        let old = try JSONDecoder().decode(AdjustMask.self, from: Data("{}".utf8))
        #expect(old == AdjustMask())
        #expect(old.isIdentity)
    }

    @Test("mask interpolation lerps scalars, holds shape and invert")
    func maskInterpolation() {
        let a = AdjustMask(shape: .radial, centerX: 0, feather: 0)
        let b = AdjustMask(shape: .rectangle, centerX: 1, feather: 0.8, invert: true)
        let mid = AdjustMask.keyframeInterpolate(a, b, t: 0.5)
        #expect(mid.shape == .radial)          // held
        #expect(mid.invert == false)           // held
        #expect(mid.centerX == 0.5)
        #expect(abs(mid.feather - 0.4) < 1e-9)
    }

    @Test("clip maskAt samples the track over the static base")
    func clipMaskSampling() {
        var clip = Fixtures.clip(id: "m1", start: 0, duration: 60)
        clip.mask = AdjustMask(shape: .radial, centerX: 0)
        clip.maskTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: AdjustMask(shape: .radial, centerX: 0), interpolationOut: .linear),
            Keyframe(frame: 20, value: AdjustMask(shape: .radial, centerX: 1), interpolationOut: .linear),
        ])
        #expect(clip.maskAt(frame: 10).centerX == 0.5)
        #expect(clip.maskAt(frame: 0).centerX == 0)
    }
}
