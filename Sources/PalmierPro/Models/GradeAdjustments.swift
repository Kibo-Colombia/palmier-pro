import Foundation

// The secondary-correction sub-models of `ColorGrade`: per-hue HSL bands, tone curves, and
// lift/gamma/gain color wheels. All are neutral at their defaults so a default value is the
// identity, and every decoder falls back to neutral per field — old projects load unchanged.
// The per-pixel math that renders these lives in `GradeMath` (baked into a correction cube).

// MARK: - HSL (8 fixed hue bands)

/// Per-hue-band secondary correction. Band order is fixed and indexed:
/// red, orange, yellow, green, cyan, blue, purple, magenta.
struct HSLAdjust: Codable, Sendable, Equatable {
    /// Band hue centers in degrees. Spacing is deliberately non-uniform (matches the
    /// CapCut/Lightroom band layout: warm hues are packed tighter than cool ones).
    static let bandCenters: [Double] = [0, 30, 60, 120, 180, 240, 280, 320]
    static let bandNames: [String] = ["red", "orange", "yellow", "green", "cyan", "blue", "purple", "magenta"]
    static let bandCount = 8

    var hueShift: [Double]      // −1…1 → ±30° rotation within the band
    var saturation: [Double]    // −1…1 multiplicative (−1 = fully desaturate the band)
    var luminance: [Double]     // −1…1 brightness ride on the band

    init(
        hueShift: [Double] = Array(repeating: 0, count: HSLAdjust.bandCount),
        saturation: [Double] = Array(repeating: 0, count: HSLAdjust.bandCount),
        luminance: [Double] = Array(repeating: 0, count: HSLAdjust.bandCount)
    ) {
        self.hueShift = Self.padded(hueShift)
        self.saturation = Self.padded(saturation)
        self.luminance = Self.padded(luminance)
    }

    var isIdentity: Bool {
        hueShift.allSatisfy { $0 == 0 } && saturation.allSatisfy { $0 == 0 } && luminance.allSatisfy { $0 == 0 }
    }

    private enum CodingKeys: String, CodingKey { case hueShift, saturation, luminance }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hueShift   = Self.padded((try? c.decode([Double].self, forKey: .hueShift)) ?? [])
        self.saturation = Self.padded((try? c.decode([Double].self, forKey: .saturation)) ?? [])
        self.luminance  = Self.padded((try? c.decode([Double].self, forKey: .luminance)) ?? [])
    }

    /// Pad/truncate to exactly `bandCount` entries so array indexing is always safe.
    private static func padded(_ v: [Double]) -> [Double] {
        if v.count == bandCount { return v }
        if v.count > bandCount { return Array(v.prefix(bandCount)) }
        return v + Array(repeating: 0, count: bandCount - v.count)
    }
}

extension HSLAdjust: KeyframeInterpolatable {
    static func keyframeInterpolate(_ a: HSLAdjust, _ b: HSLAdjust, t: Double) -> HSLAdjust {
        func lerp(_ x: [Double], _ y: [Double]) -> [Double] {
            zip(x, y).map { $0 + ($1 - $0) * t }
        }
        return HSLAdjust(
            hueShift: lerp(a.hueShift, b.hueShift),
            saturation: lerp(a.saturation, b.saturation),
            luminance: lerp(a.luminance, b.luminance)
        )
    }
}

// MARK: - Curves

/// One control point of a tone curve, both axes normalized 0…1.
struct CurvePoint: Codable, Sendable, Equatable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Tone curves: a combined luma (rgb) curve plus per-channel red/green/blue curves.
/// An empty point array means identity for that channel (the UI seeds (0,0),(1,1) on first touch).
/// Evaluation is monotone cubic (Fritsch–Carlson) in `GradeMath` — no overshoot between points.
struct CurveSet: Codable, Sendable, Equatable {
    var rgb: [CurvePoint]
    var red: [CurvePoint]
    var green: [CurvePoint]
    var blue: [CurvePoint]

    init(rgb: [CurvePoint] = [], red: [CurvePoint] = [], green: [CurvePoint] = [], blue: [CurvePoint] = []) {
        self.rgb = rgb
        self.red = red
        self.green = green
        self.blue = blue
    }

    var isIdentity: Bool {
        [rgb, red, green, blue].allSatisfy(Self.channelIsIdentity)
    }

    /// A channel is identity when empty or when every point sits on the diagonal.
    static func channelIsIdentity(_ points: [CurvePoint]) -> Bool {
        points.isEmpty || points.allSatisfy { abs($0.y - $0.x) < 1e-4 }
    }

    private enum CodingKeys: String, CodingKey { case rgb, red, green, blue }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.rgb   = (try? c.decode([CurvePoint].self, forKey: .rgb)) ?? []
        self.red   = (try? c.decode([CurvePoint].self, forKey: .red)) ?? []
        self.green = (try? c.decode([CurvePoint].self, forKey: .green)) ?? []
        self.blue  = (try? c.decode([CurvePoint].self, forKey: .blue)) ?? []
    }
}

extension CurveSet: KeyframeInterpolatable {
    /// Point-count-matched channels lerp point-wise; mismatched channels hold `a`
    /// (there is no meaningful correspondence to interpolate between different point sets).
    static func keyframeInterpolate(_ a: CurveSet, _ b: CurveSet, t: Double) -> CurveSet {
        func lerp(_ x: [CurvePoint], _ y: [CurvePoint]) -> [CurvePoint] {
            guard x.count == y.count else { return x }
            return zip(x, y).map { CurvePoint(x: $0.x + ($1.x - $0.x) * t, y: $0.y + ($1.y - $0.y) * t) }
        }
        return CurveSet(
            rgb: lerp(a.rgb, b.rgb),
            red: lerp(a.red, b.red),
            green: lerp(a.green, b.green),
            blue: lerp(a.blue, b.blue)
        )
    }
}

// MARK: - Color wheels (lift / gamma / gain / offset)

/// One wheel's adjustment: an RGB direction from the 2D wheel plus a luminance slider.
/// All components neutral at 0, range −1…1.
struct WheelAdjust: Codable, Sendable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var luma: Double

    init(r: Double = 0, g: Double = 0, b: Double = 0, luma: Double = 0) {
        self.r = r; self.g = g; self.b = b; self.luma = luma
    }

    var isIdentity: Bool { r == 0 && g == 0 && b == 0 && luma == 0 }

    private enum CodingKeys: String, CodingKey { case r, g, b, luma }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.r    = (try? c.decode(Double.self, forKey: .r)) ?? 0
        self.g    = (try? c.decode(Double.self, forKey: .g)) ?? 0
        self.b    = (try? c.decode(Double.self, forKey: .b)) ?? 0
        self.luma = (try? c.decode(Double.self, forKey: .luma)) ?? 0
    }

    static func lerp(_ a: WheelAdjust, _ b: WheelAdjust, t: Double) -> WheelAdjust {
        WheelAdjust(
            r: a.r + (b.r - a.r) * t,
            g: a.g + (b.g - a.g) * t,
            b: a.b + (b.b - a.b) * t,
            luma: a.luma + (b.luma - a.luma) * t
        )
    }
}

/// The classic lift/gamma/gain trio plus a plain offset, per the conventional LGG formula
/// (see `GradeMath.transfer`): lift moves shadows, gamma bends midtones, gain scales highlights,
/// offset shifts everything.
struct ColorWheels: Codable, Sendable, Equatable {
    var lift: WheelAdjust
    var gamma: WheelAdjust
    var gain: WheelAdjust
    var offset: WheelAdjust

    init(lift: WheelAdjust = WheelAdjust(), gamma: WheelAdjust = WheelAdjust(),
         gain: WheelAdjust = WheelAdjust(), offset: WheelAdjust = WheelAdjust()) {
        self.lift = lift; self.gamma = gamma; self.gain = gain; self.offset = offset
    }

    var isIdentity: Bool { lift.isIdentity && gamma.isIdentity && gain.isIdentity && offset.isIdentity }

    private enum CodingKeys: String, CodingKey { case lift, gamma, gain, offset }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.lift   = (try? c.decode(WheelAdjust.self, forKey: .lift)) ?? WheelAdjust()
        self.gamma  = (try? c.decode(WheelAdjust.self, forKey: .gamma)) ?? WheelAdjust()
        self.gain   = (try? c.decode(WheelAdjust.self, forKey: .gain)) ?? WheelAdjust()
        self.offset = (try? c.decode(WheelAdjust.self, forKey: .offset)) ?? WheelAdjust()
    }
}

extension ColorWheels: KeyframeInterpolatable {
    static func keyframeInterpolate(_ a: ColorWheels, _ b: ColorWheels, t: Double) -> ColorWheels {
        ColorWheels(
            lift: WheelAdjust.lerp(a.lift, b.lift, t: t),
            gamma: WheelAdjust.lerp(a.gamma, b.gamma, t: t),
            gain: WheelAdjust.lerp(a.gain, b.gain, t: t),
            offset: WheelAdjust.lerp(a.offset, b.offset, t: t)
        )
    }
}
