import Foundation
import simd

/// Pure per-pixel math for the cube-baked portion of a `ColorGrade` — the secondary
/// corrections that have no native CIFilter: color wheels, tone curves, per-hue HSL,
/// highlights/shadows, fade. `correctionCube(for:)` samples `transfer` onto an n³ lattice
/// packed for `CIColorCubeWithColorSpace` (same layout as `BundledLooks.cube`).
///
/// Everything here operates in gamma-encoded sRGB (the space LUTs are authored in and the
/// space the compositor tells CIColorCube to sample in). Pure functions only — used by the
/// render path (via GradeCubeCache), preset swatches, and unit tests.
enum GradeMath {
    static let defaultCubeDimension = 33

    // MARK: - Per-grade precomputed tables

    /// Precomputed evaluation state for one grade — build once, evaluate per lattice point.
    /// Keeps the 33³ (~36k point) bake at table-lookup cost instead of re-deriving splines.
    struct Evaluator {
        let grade: ColorGrade
        let applyWheels: Bool
        let applyCurves: Bool
        let applyHSL: Bool
        let applyTonal: Bool   // highlights / shadows / fade

        // 256-entry sampled curve tables (nil = identity channel).
        let curveRGB: [Float]?
        let curveR: [Float]?
        let curveG: [Float]?
        let curveB: [Float]?

        init(_ g: ColorGrade) {
            self.grade = g
            self.applyWheels = !g.wheels.isIdentity
            self.applyCurves = !g.curves.isIdentity
            self.applyHSL = !g.hsl.isIdentity
            self.applyTonal = g.highlights != 0 || g.shadows != 0 || g.fade != 0
            self.curveRGB = Self.curveTable(g.curves.rgb)
            self.curveR   = Self.curveTable(g.curves.red)
            self.curveG   = Self.curveTable(g.curves.green)
            self.curveB   = Self.curveTable(g.curves.blue)
        }

        private static func curveTable(_ points: [CurvePoint]) -> [Float]? {
            guard !CurveSet.channelIsIdentity(points) else { return nil }
            return GradeMath.sampleCurve(points, count: 256)
        }

        /// One pixel through wheels → curves → HSL → highlights/shadows → fade. Output clamped 0…1.
        func transfer(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
            var c = clamp(rgb, min: SIMD3<Float>(repeating: 0), max: SIMD3<Float>(repeating: 1))

            if applyWheels { c = GradeMath.applyWheels(grade.wheels, c) }

            if applyCurves {
                // Per-channel curves first, combined luma (rgb) curve last — Resolve/CapCut order.
                if let t = curveR { c.x = GradeMath.lookup(t, c.x) }
                if let t = curveG { c.y = GradeMath.lookup(t, c.y) }
                if let t = curveB { c.z = GradeMath.lookup(t, c.z) }
                if let t = curveRGB {
                    c = SIMD3(GradeMath.lookup(t, c.x), GradeMath.lookup(t, c.y), GradeMath.lookup(t, c.z))
                }
            }

            if applyHSL { c = GradeMath.applyHSL(grade.hsl, c) }

            if applyTonal {
                c = GradeMath.applyTonal(
                    c,
                    highlights: Float(grade.highlights),
                    shadows: Float(grade.shadows),
                    fade: Float(grade.fade)
                )
            }

            return clamp(c, min: SIMD3<Float>(repeating: 0), max: SIMD3<Float>(repeating: 1))
        }
    }

    /// Convenience single-pixel transfer (tests, swatches). For bulk work build an `Evaluator`.
    static func transfer(_ grade: ColorGrade, _ rgb: SIMD3<Float>) -> SIMD3<Float> {
        Evaluator(grade).transfer(rgb)
    }

    // MARK: - Cube bake

    /// Sample the grade's correction transfer onto an n³ RGBA float cube in CIColorCube
    /// memory order (blue outer → green → red fastest), alpha 1.
    static func correctionCube(for grade: ColorGrade, dimension n: Int = defaultCubeDimension) -> LUTCube {
        let ev = Evaluator(grade)
        var values = [Float](repeating: 0, count: n * n * n * 4)
        let denom = Float(n - 1)
        var k = 0
        for bi in 0..<n {
            let b = Float(bi) / denom
            for gi in 0..<n {
                let g = Float(gi) / denom
                for ri in 0..<n {
                    let out = ev.transfer(SIMD3(Float(ri) / denom, g, b))
                    values[k] = out.x; values[k + 1] = out.y; values[k + 2] = out.z; values[k + 3] = 1
                    k += 4
                }
            }
        }
        return LUTCube(dimension: n, data: values.withUnsafeBytes { Data($0) })
    }

    // MARK: - Skin-tone protection (LUT preprocessing)

    /// Derive a skin-protected copy of a look cube: for each lattice input color `c`,
    /// `out = mix(lut(c), c, protect · wSkin(c))` — skin-hued inputs keep their original color,
    /// everything else takes the full look. Free at render time (plain cube swap).
    static func skinProtected(_ base: LUTCube, protect: Double) -> LUTCube {
        let p = Float(min(1, max(0, protect)))
        guard p > 0 else { return base }
        let n = base.dimension
        var values = [Float](repeating: 0, count: n * n * n * 4)
        base.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.bindMemory(to: Float.self)
            let denom = Float(n - 1)
            var k = 0
            for bi in 0..<n {
                let b = Float(bi) / denom
                for gi in 0..<n {
                    let g = Float(gi) / denom
                    for ri in 0..<n {
                        let r = Float(ri) / denom
                        let w = p * skinWeight(SIMD3(r, g, b))
                        values[k]     = src[k]     + (r - src[k])     * w
                        values[k + 1] = src[k + 1] + (g - src[k + 1]) * w
                        values[k + 2] = src[k + 2] + (b - src[k + 2]) * w
                        values[k + 3] = 1
                        k += 4
                    }
                }
            }
        }
        return LUTCube(dimension: n, data: values.withUnsafeBytes { Data($0) })
    }

    /// Skin likelihood of a gamma-sRGB color: a raised-cosine hue window around 15°–45°
    /// (peak 25–35°), gated by moderate saturation and enough level to matter.
    static func skinWeight(_ rgb: SIMD3<Float>) -> Float {
        let hsv = rgbToHSV(rgb)
        let h = hsv.x, s = hsv.y, v = hsv.z

        let wHue: Float
        if h >= 15 && h <= 45 {
            wHue = h <= 25 ? cosRamp((h - 15) / 10)
                 : h >= 35 ? cosRamp((45 - h) / 10)
                 : 1
        } else {
            wHue = 0
        }
        let wSat = smoothstep01((s - 0.10) / 0.15) * (1 - smoothstep01((s - 0.70) / 0.20))
        let wVal = smoothstep01((v - 0.15) / 0.15)
        return wHue * wSat * wVal
    }

    // MARK: - Swatches

    /// Push three grays (and the LUT if any) through the grade — cheap preset swatch colors
    /// with zero Core Image involvement.
    static func swatchColors(for grade: ColorGrade, lut: LUTCube? = nil) -> [(Float, Float, Float)] {
        let ev = Evaluator(grade)
        return [Float(0.25), 0.5, 0.8].map { v in
            var c = SIMD3<Float>(repeating: v)
            if let lut {
                let looked = sampleCube(lut, at: c)
                let li = Float(min(1, max(0, grade.lookIntensity)))
                c = c + (looked - c) * li
            }
            let out = ev.transfer(c)
            return (out.x, out.y, out.z)
        }
    }

    // MARK: - Wheels (lift / gamma / gain / offset)

    /// Conventional LGG: `out = pow(clamp01(gain · (in + lift·(1−in))), 1/gamma) + offset`,
    /// per channel, with each wheel's luma slider added to its RGB components.
    static func applyWheels(_ w: ColorWheels, _ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let lift  = SIMD3<Float>(Float(w.lift.r + w.lift.luma), Float(w.lift.g + w.lift.luma), Float(w.lift.b + w.lift.luma)) * 0.5
        let gain  = SIMD3<Float>(repeating: 1) + SIMD3<Float>(Float(w.gain.r + w.gain.luma), Float(w.gain.g + w.gain.luma), Float(w.gain.b + w.gain.luma))
        let gAdj  = SIMD3<Float>(Float(w.gamma.r + w.gamma.luma), Float(w.gamma.g + w.gamma.luma), Float(w.gamma.b + w.gamma.luma))
        let offs  = SIMD3<Float>(Float(w.offset.r + w.offset.luma), Float(w.offset.g + w.offset.luma), Float(w.offset.b + w.offset.luma)) * 0.5

        var out = rgb
        for i in 0..<3 {
            let lifted = out[i] + lift[i] * (1 - out[i])
            let gained = max(0, min(1, gain[i] * lifted))
            // +gamma brightens mids: exponent = 1 / (1 + adj), clamped to a sane range.
            let exponent = 1 / min(4, max(0.25, 1 + gAdj[i]))
            out[i] = pow(gained, exponent) + offs[i]
        }
        return out
    }

    // MARK: - Curves (monotone cubic, Fritsch–Carlson)

    /// Sample a control-point curve into a `count`-entry table over x ∈ 0…1.
    /// Monotone cubic Hermite interpolation (Fritsch–Carlson tangents) — passes through every
    /// point with no overshoot, so a point near 0 or 1 can't ring the curve out of range.
    /// Outside the first/last point the curve extends flat.
    static func sampleCurve(_ points: [CurvePoint], count: Int = 256) -> [Float] {
        let sorted = points.sorted { $0.x < $1.x }
        guard sorted.count >= 2 else {
            // 0 points: identity ramp; 1 point: constant at its y.
            if let only = sorted.first {
                return [Float](repeating: Float(min(1, max(0, only.y))), count: count)
            }
            return (0..<count).map { Float($0) / Float(count - 1) }
        }

        let xs = sorted.map { min(1, max(0, $0.x)) }
        let ys = sorted.map { min(1, max(0, $0.y)) }
        let nSeg = xs.count - 1

        // Secants and Fritsch–Carlson tangents.
        var d = [Double](repeating: 0, count: nSeg)
        for i in 0..<nSeg {
            let dx = max(1e-6, xs[i + 1] - xs[i])
            d[i] = (ys[i + 1] - ys[i]) / dx
        }
        var m = [Double](repeating: 0, count: xs.count)
        m[0] = d[0]
        m[nSeg] = d[nSeg - 1]
        for i in 1..<nSeg {
            m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2
        }
        // Clamp tangents to preserve monotonicity (the Fritsch–Carlson circle criterion).
        for i in 0..<nSeg {
            if d[i] == 0 {
                m[i] = 0; m[i + 1] = 0
            } else {
                let a = m[i] / d[i], b = m[i + 1] / d[i]
                let s = a * a + b * b
                if s > 9 {
                    let tau = 3 / s.squareRoot()
                    m[i] = tau * a * d[i]
                    m[i + 1] = tau * b * d[i]
                }
            }
        }

        var table = [Float](repeating: 0, count: count)
        var seg = 0
        for k in 0..<count {
            let x = Double(k) / Double(count - 1)
            if x <= xs[0] { table[k] = Float(ys[0]); continue }
            if x >= xs[nSeg] { table[k] = Float(ys[nSeg]); continue }
            while seg < nSeg - 1 && x > xs[seg + 1] { seg += 1 }
            let h = max(1e-6, xs[seg + 1] - xs[seg])
            let t = (x - xs[seg]) / h
            let t2 = t * t, t3 = t2 * t
            let h00 = 2 * t3 - 3 * t2 + 1
            let h10 = t3 - 2 * t2 + t
            let h01 = -2 * t3 + 3 * t2
            let h11 = t3 - t2
            let y = h00 * ys[seg] + h10 * h * m[seg] + h01 * ys[seg + 1] + h11 * h * m[seg + 1]
            table[k] = Float(min(1, max(0, y)))
        }
        return table
    }

    /// Linear-interpolated table lookup, x clamped to 0…1.
    static func lookup(_ table: [Float], _ x: Float) -> Float {
        let cx = min(1, max(0, x)) * Float(table.count - 1)
        let i = Int(cx)
        if i >= table.count - 1 { return table[table.count - 1] }
        let f = cx - Float(i)
        return table[i] + (table[i + 1] - table[i]) * f
    }

    // MARK: - HSL bands

    /// Per-hue-band adjust in HSV space. Band weights are a cos² partition of unity over the
    /// non-uniform band centers, gated by saturation and level so neutrals stay put.
    static func applyHSL(_ hsl: HSLAdjust, _ rgb: SIMD3<Float>) -> SIMD3<Float> {
        var hsv = rgbToHSV(rgb)
        let gate = smoothstep01((hsv.y - 0.04) / 0.11) * smoothstep01((hsv.z - 0.02) / 0.08)
        guard gate > 0 else { return rgb }

        var hueDelta: Float = 0
        var satDelta: Float = 0
        var lumDelta: Float = 0
        var totalW: Float = 0
        var weights = [Float](repeating: 0, count: HSLAdjust.bandCount)

        for i in 0..<HSLAdjust.bandCount {
            let center = Float(HSLAdjust.bandCenters[i])
            let dist = wrap180(hsv.x - center)
            let width = bandHalfWidth(i)
            guard abs(dist) < width else { continue }
            let w = cosSq(dist / width)
            weights[i] = w
            totalW += w
        }
        guard totalW > 0 else { return rgb }

        for i in 0..<HSLAdjust.bandCount where weights[i] > 0 {
            let w = weights[i] / totalW * gate   // normalized: overlapping bands never double-apply
            hueDelta += w * Float(hsl.hueShift[i]) * 30
            satDelta += w * Float(hsl.saturation[i])
            lumDelta += w * Float(hsl.luminance[i])
        }

        hsv.x = wrapHue(hsv.x + hueDelta)
        hsv.y = min(1, max(0, hsv.y * (1 + satDelta)))
        hsv.z = min(1, max(0, hsv.z * (1 + 0.6 * lumDelta)))
        return hsvToRGB(hsv)
    }

    /// Half-width of band `i`: the angular distance to the nearer neighboring band center,
    /// so adjacent cos² lobes cross at the midpoint and the partition covers every hue.
    static func bandHalfWidth(_ i: Int) -> Float {
        let centers = HSLAdjust.bandCenters
        let n = centers.count
        let c = centers[i]
        let prev = centers[(i + n - 1) % n]
        let next = centers[(i + 1) % n]
        let dPrev = abs(Double(wrap180(Float(c - prev))))
        let dNext = abs(Double(wrap180(Float(next - c))))
        return Float(min(dPrev, dNext))
    }

    // MARK: - Tonal (highlights / shadows / fade)

    /// Hue-preserving tonal re-map: shift Rec.709 luma with shadow/highlight weights, then
    /// ratio-scale RGB; finally lift blacks by `fade` (whites pinned) with a slight desat ride.
    static func applyTonal(_ rgb: SIMD3<Float>, highlights: Float, shadows: Float, fade: Float) -> SIMD3<Float> {
        var c = rgb
        if highlights != 0 || shadows != 0 {
            let y = luma(c)
            let yNew = min(1, max(0, y + 0.35 * shadows * (1 - y) * (1 - y) + 0.35 * highlights * y * y))
            let ratio = yNew / max(y, 1e-4)
            c = SIMD3(min(1, max(0, c.x * ratio)), min(1, max(0, c.y * ratio)), min(1, max(0, c.z * ratio)))
        }
        if fade > 0 {
            let lift = 0.20 * fade
            c = SIMD3<Float>(repeating: lift) + (1 - lift) * c
            let y = luma(c)
            c = c + (SIMD3<Float>(repeating: y) - c) * (0.15 * fade)
        }
        return c
    }

    // MARK: - Color-space + scalar helpers (all pure)

    static func luma(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    /// RGB (0…1) → HSV with hue in degrees 0…360.
    static func rgbToHSV(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let maxC = max(c.x, max(c.y, c.z))
        let minC = min(c.x, min(c.y, c.z))
        let delta = maxC - minC
        var h: Float = 0
        if delta > 1e-6 {
            if maxC == c.x { h = 60 * ((c.y - c.z) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxC == c.y { h = 60 * ((c.z - c.x) / delta + 2) }
            else { h = 60 * ((c.x - c.y) / delta + 4) }
            if h < 0 { h += 360 }
        }
        let s = maxC <= 1e-6 ? 0 : delta / maxC
        return SIMD3(h, s, maxC)
    }

    static func hsvToRGB(_ hsv: SIMD3<Float>) -> SIMD3<Float> {
        let h = hsv.x, s = hsv.y, v = hsv.z
        let c = v * s
        let hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r, g, b): (Float, Float, Float)
        switch hp {
        case ..<1: (r, g, b) = (c, x, 0)
        case ..<2: (r, g, b) = (x, c, 0)
        case ..<3: (r, g, b) = (0, c, x)
        case ..<4: (r, g, b) = (0, x, c)
        case ..<5: (r, g, b) = (x, 0, c)
        default:   (r, g, b) = (c, 0, x)
        }
        return SIMD3(r + m, g + m, b + m)
    }

    /// Trilinear sample of a LUTCube at a 0…1 RGB coordinate (CPU-side; swatches only).
    static func sampleCube(_ cube: LUTCube, at c: SIMD3<Float>) -> SIMD3<Float> {
        let n = cube.dimension
        return cube.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> SIMD3<Float> in
            let f = raw.bindMemory(to: Float.self)
            func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
                let o = (b * n * n + g * n + r) * 4
                return SIMD3(f[o], f[o + 1], f[o + 2])
            }
            let pos = clamp(c, min: SIMD3<Float>(repeating: 0), max: SIMD3<Float>(repeating: 1)) * Float(n - 1)
            let i0 = SIMD3<Int>(Int(pos.x), Int(pos.y), Int(pos.z))
            let i1 = SIMD3<Int>(min(n - 1, i0.x + 1), min(n - 1, i0.y + 1), min(n - 1, i0.z + 1))
            let fr = pos - SIMD3<Float>(Float(i0.x), Float(i0.y), Float(i0.z))
            // Trilinear blend over the 8 surrounding lattice points.
            let c00 = at(i0.x, i0.y, i0.z) * (1 - fr.x) + at(i1.x, i0.y, i0.z) * fr.x
            let c10 = at(i0.x, i1.y, i0.z) * (1 - fr.x) + at(i1.x, i1.y, i0.z) * fr.x
            let c01 = at(i0.x, i0.y, i1.z) * (1 - fr.x) + at(i1.x, i0.y, i1.z) * fr.x
            let c11 = at(i0.x, i1.y, i1.z) * (1 - fr.x) + at(i1.x, i1.y, i1.z) * fr.x
            let c0 = c00 * (1 - fr.y) + c10 * fr.y
            let c1 = c01 * (1 - fr.y) + c11 * fr.y
            return c0 * (1 - fr.z) + c1 * fr.z
        }
    }

    static func wrap180(_ deg: Float) -> Float {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    static func wrapHue(_ deg: Float) -> Float {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }

    static func smoothstep01(_ x: Float) -> Float {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    /// cos² falloff over t ∈ −1…1 (1 at center, 0 at the edges).
    static func cosSq(_ t: Float) -> Float {
        let c = cos(Float.pi / 2 * min(1, max(-1, t)))
        return c * c
    }

    /// Raised-cosine ramp 0→1 over t ∈ 0…1.
    static func cosRamp(_ t: Float) -> Float {
        let c = min(1, max(0, t))
        return 0.5 - 0.5 * cos(Float.pi * c)
    }
}
