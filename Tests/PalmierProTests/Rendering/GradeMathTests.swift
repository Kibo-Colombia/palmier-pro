import Testing
import Foundation
import simd
@testable import PalmierPro

/// Unit tests for the pure grade math: the correction-cube transfer (wheels → curves → HSL →
/// highlights/shadows → fade), the monotone curve sampler, skin-tone protection, and the
/// forward-compatible ColorGrade schema. Pure CPU (no Core Image render) so they stay fast.
@Suite("GradeMath")
struct GradeMathTests {

    private func approx(_ a: Float, _ b: Float, _ eps: Float = 1e-3) -> Bool { abs(a - b) <= eps }
    private func approx(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-3) -> Bool {
        approx(a.x, b.x, eps) && approx(a.y, b.y, eps) && approx(a.z, b.z, eps)
    }

    // MARK: - Transfer identity

    @Test("neutral grade transfer is the identity")
    func identityTransfer() {
        let g = ColorGrade()
        for v in [SIMD3<Float>(0, 0, 0), SIMD3(0.25, 0.5, 0.75), SIMD3(1, 1, 1), SIMD3(0.8, 0.1, 0.4)] {
            #expect(approx(GradeMath.transfer(g, v), v))
        }
        #expect(!g.needsCorrectionCube)
        #expect(g.isIdentity)
    }

    @Test("correction cube of a neutral grade is the identity lattice")
    func identityCube() {
        let cube = GradeMath.correctionCube(for: ColorGrade(), dimension: 5)
        let f = cube.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let denom = Float(4)
        var k = 0
        for b in 0..<5 {
            for g in 0..<5 {
                for r in 0..<5 {
                    #expect(approx(f[k], Float(r) / denom))
                    #expect(approx(f[k + 1], Float(g) / denom))
                    #expect(approx(f[k + 2], Float(b) / denom))
                    #expect(f[k + 3] == 1)
                    k += 4
                }
            }
        }
    }

    // MARK: - Tonal (highlights / shadows / fade)

    @Test("highlights push brights and leave darks nearly untouched")
    func highlightsSelective() {
        var g = ColorGrade(); g.highlights = 1
        let bright = GradeMath.transfer(g, SIMD3(repeating: 0.8))
        let dark = GradeMath.transfer(g, SIMD3(repeating: 0.1))
        #expect(bright.x > 0.9)
        #expect(approx(dark.x, 0.1, 0.01))
    }

    @Test("shadows lift darks and leave brights nearly untouched")
    func shadowsSelective() {
        var g = ColorGrade(); g.shadows = 1
        let dark = GradeMath.transfer(g, SIMD3(repeating: 0.1))
        let bright = GradeMath.transfer(g, SIMD3(repeating: 0.9))
        #expect(dark.x > 0.2)
        #expect(approx(bright.x, 0.9, 0.01))
    }

    @Test("tonal remap is monotone in luma at full strength")
    func tonalMonotone() {
        var g = ColorGrade(); g.highlights = 1; g.shadows = -1
        var last: Float = -1
        for i in 0...20 {
            let v = Float(i) / 20
            let out = GradeMath.transfer(g, SIMD3(repeating: v)).x
            #expect(out >= last - 1e-4)
            last = out
        }
    }

    @Test("fade lifts black toward the matte floor and pins white")
    func fadeLiftsBlacks() {
        var g = ColorGrade(); g.fade = 1
        let black = GradeMath.transfer(g, SIMD3(repeating: 0))
        let white = GradeMath.transfer(g, SIMD3(repeating: 1))
        #expect(approx(black.x, 0.2, 0.01))
        #expect(approx(white.x, 1, 0.01))
    }

    // MARK: - Curves

    @Test("curve passes through its control points and extends flat outside")
    func curveInterpolates() {
        let pts = [CurvePoint(x: 0.2, y: 0.1), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 0.8, y: 0.9)]
        let table = GradeMath.sampleCurve(pts, count: 512)
        #expect(approx(GradeMath.lookup(table, 0.2), 0.1, 0.01))
        #expect(approx(GradeMath.lookup(table, 0.5), 0.6, 0.01))
        #expect(approx(GradeMath.lookup(table, 0.8), 0.9, 0.01))
        // Flat extension outside the endpoints.
        #expect(approx(GradeMath.lookup(table, 0.0), 0.1, 0.01))
        #expect(approx(GradeMath.lookup(table, 1.0), 0.9, 0.01))
    }

    @Test("monotone spline never overshoots out of range near clipping points")
    func curveNoOvershoot() {
        // Catmull-Rom would ring below 0 / above 1 here; Fritsch–Carlson must not.
        let pts = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.1, y: 0.02),
                   CurvePoint(x: 0.2, y: 0.95), CurvePoint(x: 1, y: 1)]
        let table = GradeMath.sampleCurve(pts, count: 1024)
        for v in table {
            #expect(v >= 0 && v <= 1)
        }
        // Monotone between the given increasing points.
        var last: Float = -1
        for v in table {
            #expect(v >= last - 1e-4)
            last = v
        }
    }

    @Test("empty and diagonal point sets are identity channels")
    func curveIdentity() {
        #expect(CurveSet().isIdentity)
        #expect(CurveSet.channelIsIdentity([CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]))
        #expect(!CurveSet.channelIsIdentity([CurvePoint(x: 0, y: 0.2), CurvePoint(x: 1, y: 1)]))
        let identityTable = GradeMath.sampleCurve([], count: 256)
        #expect(approx(GradeMath.lookup(identityTable, 0.37), 0.37, 0.005))
    }

    // MARK: - Wheels

    @Test("neutral wheels are the identity")
    func wheelsIdentity() {
        #expect(ColorWheels().isIdentity)
        let out = GradeMath.applyWheels(ColorWheels(), SIMD3(0.3, 0.5, 0.7))
        #expect(approx(out, SIMD3(0.3, 0.5, 0.7)))
    }

    @Test("lift raises black, pins white; gain scales white")
    func wheelsLiftGain() {
        var w = ColorWheels()
        w.lift = WheelAdjust(luma: 0.5)
        let black = GradeMath.applyWheels(w, SIMD3(repeating: 0))
        let white = GradeMath.applyWheels(w, SIMD3(repeating: 1))
        #expect(approx(black, SIMD3(repeating: 0.25), 0.01))   // 0.5 · 0.5 effective lift
        #expect(approx(white, SIMD3(repeating: 1), 0.01))

        var w2 = ColorWheels()
        w2.gain = WheelAdjust(luma: -0.5)
        let dimmed = GradeMath.applyWheels(w2, SIMD3(repeating: 1))
        #expect(approx(dimmed, SIMD3(repeating: 0.5), 0.01))
    }

    @Test("positive gamma brightens midtones, endpoints stay pinned")
    func wheelsGamma() {
        var w = ColorWheels()
        w.gamma = WheelAdjust(luma: 0.5)
        let mid = GradeMath.applyWheels(w, SIMD3(repeating: 0.5))
        #expect(mid.x > 0.5)
        #expect(approx(GradeMath.applyWheels(w, SIMD3(repeating: 0)), SIMD3(repeating: 0), 0.01))
        #expect(approx(GradeMath.applyWheels(w, SIMD3(repeating: 1)), SIMD3(repeating: 1), 0.01))
    }

    @Test("offset shifts everything uniformly")
    func wheelsOffset() {
        var w = ColorWheels()
        w.offset = WheelAdjust(r: 0.2)
        let out = GradeMath.applyWheels(w, SIMD3(repeating: 0.5))
        #expect(approx(out.x, 0.6, 0.01))   // +0.2 · 0.5 scale
        #expect(approx(out.y, 0.5, 0.01))
    }

    // MARK: - HSL bands

    @Test("neutral grays are untouched by any HSL band")
    func hslNeutralStability() {
        var hsl = HSLAdjust()
        hsl.saturation = Array(repeating: -1, count: 8)
        hsl.luminance = Array(repeating: 1, count: 8)
        for v in [Float(0), 0.3, 0.6, 1] {
            let out = GradeMath.applyHSL(hsl, SIMD3(repeating: v))
            #expect(approx(out, SIMD3(repeating: v)))
        }
    }

    @Test("a band only moves its own hues — pure red ignores the blue band")
    func hslBandSelectivity() {
        var blueOnly = HSLAdjust()
        blueOnly.saturation[5] = -1   // index 5 = blue (240°)
        let red = GradeMath.applyHSL(blueOnly, SIMD3(1, 0.1, 0.1))
        #expect(approx(red, SIMD3(1, 0.1, 0.1)))

        let blue = GradeMath.applyHSL(blueOnly, SIMD3(0.1, 0.1, 1))
        let sat = GradeMath.rgbToHSV(blue).y
        #expect(sat < 0.2)   // fully desaturated by its own band
    }

    @Test("band weights partition saturated hues (full effect between overlapping bands)")
    func hslPartitionOfUnity() {
        var all = HSLAdjust()
        all.saturation = Array(repeating: -1, count: 8)
        // Any strongly saturated hue should be fully desaturated when every band pulls −1,
        // proving the normalized weights sum to 1 everywhere on the wheel.
        for hue in stride(from: Float(0), to: 360, by: 15) {
            let rgb = GradeMath.hsvToRGB(SIMD3(hue, 0.9, 0.8))
            let out = GradeMath.applyHSL(all, rgb)
            #expect(GradeMath.rgbToHSV(out).y < 0.05, "hue \(hue) not fully desaturated")
        }
    }

    @Test("hue shift rotates within the band by up to ±30°")
    func hslHueShift() {
        var redShift = HSLAdjust()
        redShift.hueShift[0] = 1   // red band → +30°
        let out = GradeMath.applyHSL(redShift, SIMD3(1, 0, 0))
        let hue = GradeMath.rgbToHSV(out).x
        #expect(hue > 20 && hue < 40)   // red (0°) pushed toward orange
    }

    // MARK: - Skin protection

    @Test("skin-hued input survives a B&W look with protect on; blue is fully graded")
    func skinProtection() {
        let bw = BundledLooks.cube(for: "bw", dimension: 17)!
        let protected = GradeMath.skinProtected(bw, protect: 1)

        let skin = SIMD3<Float>(0.85, 0.62, 0.48)   // warm skin tone (~25° hue, moderate sat)
        let skinOut = GradeMath.sampleCube(protected, at: skin)
        let skinBW = GradeMath.sampleCube(bw, at: skin)
        // Protected output stays near the input, far from the desaturated B&W result.
        let distIn = simd_length(skinOut - skin)
        let distBW = simd_length(skinOut - skinBW)
        #expect(distIn < distBW)

        let blue = SIMD3<Float>(0.2, 0.3, 0.9)
        let blueOut = GradeMath.sampleCube(protected, at: blue)
        let blueBW = GradeMath.sampleCube(bw, at: blue)
        #expect(simd_length(blueOut - blueBW) < 0.02)   // non-skin: full look
    }

    @Test("protect 0 returns the base cube unchanged")
    func skinProtectZeroIsPassthrough() {
        let bw = BundledLooks.cube(for: "bw", dimension: 17)!
        #expect(GradeMath.skinProtected(bw, protect: 0) == bw)
    }

    // MARK: - Cube cache

    @Test("cache returns identical cubes for equal grades and distinct for different ones")
    func cubeCacheKeys() {
        var g1 = ColorGrade(); g1.highlights = 0.5
        var g2 = ColorGrade(); g2.highlights = 0.5
        var g3 = ColorGrade(); g3.highlights = -0.5
        let c1 = GradeCubeCache.shared.correctionCube(for: g1)
        let c2 = GradeCubeCache.shared.correctionCube(for: g2)
        let c3 = GradeCubeCache.shared.correctionCube(for: g3)
        #expect(c1 == c2)
        #expect(c1 != c3)
        #expect(GradeCubeKey(g1) == GradeCubeKey(g2))
        #expect(GradeCubeKey(g1) != GradeCubeKey(g3))
    }

    // MARK: - Schema compatibility

    @Test("old-project grade JSON decodes with neutral new fields")
    func decodeOldGradeJSON() throws {
        let old = #"{"lut":"warm","lookIntensity":0.8,"exposure":0.5,"contrast":1.2}"#
        let g = try JSONDecoder().decode(ColorGrade.self, from: Data(old.utf8))
        #expect(g.lut == "warm")
        #expect(g.exposure == 0.5)
        #expect(g.hue == 0 && g.highlights == 0 && g.shadows == 0 && g.fade == 0)
        #expect(g.sharpen == 0 && g.clarity == 0 && g.vignette == 0 && g.protectSkinTone == 0)
        #expect(g.hsl.isIdentity && g.curves.isIdentity && g.wheels.isIdentity)
        #expect(!g.isIdentity)   // it has a lut + exposure
    }

    @Test("maxed-out grade round-trips through Codable")
    func roundTripFullGrade() throws {
        var g = ColorGrade(lut: "teal-orange", exposure: 1.5)
        g.hue = 45; g.highlights = -0.4; g.shadows = 0.3; g.fade = 0.25
        g.sharpen = 0.6; g.clarity = 0.4; g.vignette = 0.7; g.protectSkinTone = 1
        g.hsl.hueShift[2] = 0.5; g.hsl.saturation[4] = -0.6; g.hsl.luminance[7] = 0.8
        g.curves.rgb = [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 0.9)]
        g.curves.red = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 1)]
        g.wheels.lift = WheelAdjust(r: 0.2, g: -0.1, b: 0, luma: 0.05)
        g.wheels.gain = WheelAdjust(r: -0.3, luma: 0.1)
        let data = try JSONEncoder().encode(g)
        let back = try JSONDecoder().decode(ColorGrade.self, from: data)
        #expect(back == g)
    }

    @Test("HSL arrays pad/truncate to 8 bands on decode")
    func hslArrayPadding() throws {
        let short = #"{"hueShift":[0.5],"saturation":[],"luminance":[0,0,0,0,0,0,0,0,0,0]}"#
        let h = try JSONDecoder().decode(HSLAdjust.self, from: Data(short.utf8))
        #expect(h.hueShift.count == 8 && h.hueShift[0] == 0.5)
        #expect(h.saturation.count == 8)
        #expect(h.luminance.count == 8)
    }

    // MARK: - Interpolation

    @Test("grade interpolation lerps scalars and sub-structs; curves hold on count mismatch")
    func gradeInterpolation() {
        var a = ColorGrade(); a.highlights = 0; a.fade = 0
        a.curves.rgb = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
        a.wheels.lift = WheelAdjust(luma: 0)
        var b = ColorGrade(); b.highlights = 1; b.fade = 0.5
        b.curves.rgb = [CurvePoint(x: 0, y: 0.2), CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 1, y: 1)]
        b.wheels.lift = WheelAdjust(luma: 1)

        let mid = ColorGrade.keyframeInterpolate(a, b, t: 0.5)
        #expect(approx(Float(mid.highlights), 0.5))
        #expect(approx(Float(mid.fade), 0.25))
        #expect(approx(Float(mid.wheels.lift.luma), 0.5))
        #expect(mid.curves.rgb == a.curves.rgb)   // count mismatch → hold a

        var b2 = ColorGrade()
        b2.curves.rgb = [CurvePoint(x: 0, y: 0.4), CurvePoint(x: 1, y: 1)]
        let mid2 = ColorGrade.keyframeInterpolate(a, b2, t: 0.5)
        #expect(approx(Float(mid2.curves.rgb[0].y), 0.2))   // matched counts → lerp
    }

    // MARK: - Swatches

    @Test("swatch colors are pure-function and reflect the grade")
    func swatches() {
        var g = ColorGrade()
        g.wheels.gain = WheelAdjust(luma: -0.8)
        let neutral = GradeMath.swatchColors(for: ColorGrade())
        let dark = GradeMath.swatchColors(for: g)
        #expect(neutral.count == 3 && dark.count == 3)
        #expect(dark[2].0 < neutral[2].0)   // gained-down grade darkens the bright swatch
    }
}
