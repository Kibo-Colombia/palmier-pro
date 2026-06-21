import Foundation

/// Per-clip primary color correction. All channels are neutral at their defaults, so a
/// default `ColorGrade` is the identity (no-op) and clips without a grade render exactly
/// as before. The render-side CIFilter chain lives in `GradeCompositor`.
///
/// Channel domains (clamped on the agent/tool boundary, see ToolExecutor+Grade):
///   exposure    EV stops          neutral 0     range −4…4   (CIExposureAdjust)
///   brightness  additive          neutral 0     range −1…1   (CIColorControls)
///   contrast    multiplicative    neutral 1     range  0…4   (CIColorControls)
///   saturation  multiplicative    neutral 1     range  0…4   (CIColorControls)
///   temperature warm(+)/cool(−)   neutral 0     range −100…100 (CITemperatureAndTint)
///   tint        magenta(+)/green(−) neutral 0   range −100…100 (CITemperatureAndTint)
///   intensity   global wet/dry mix neutral 1    range  0…1
struct ColorGrade: Codable, Sendable, Equatable {
    // Base look (a 3D LUT). nil = no look; cube data is resolved at render time by LUTStore.
    var lut: String? = nil          // bundled look id (e.g. "teal-orange") OR imported .cube asset id
    var lookIntensity: Double = 1   // wet/dry of the LUT alone (distinct from `intensity`, below)

    var exposure: Double = 0
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var temperature: Double = 0
    var tint: Double = 0
    var intensity: Double = 1       // wet/dry of the WHOLE grade (look + minor channels)

    init(
        lut: String? = nil,
        lookIntensity: Double = 1,
        exposure: Double = 0,
        brightness: Double = 0,
        contrast: Double = 1,
        saturation: Double = 1,
        temperature: Double = 0,
        tint: Double = 0,
        intensity: Double = 1
    ) {
        self.lut = lut
        self.lookIntensity = lookIntensity
        self.exposure = exposure
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.temperature = temperature
        self.tint = tint
        self.intensity = intensity
    }

    /// True when the grade changes nothing — lets the render path keep the stock
    /// (built-in compositor) fast path and skip the GradeCompositor entirely.
    var isIdentity: Bool {
        lut == nil && exposure == 0 && brightness == 0 && contrast == 1 && saturation == 1
            && temperature == 0 && tint == 0
    }

    private enum CodingKeys: String, CodingKey {
        case lut, lookIntensity, exposure, brightness, contrast, saturation, temperature, tint, intensity
    }

    // Forward/back-compatible decode: any missing channel falls back to its neutral default,
    // so older projects (no grade) and partial writes load clean.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.lut           = (try? c.decodeIfPresent(String.self, forKey: .lut)) ?? nil
        self.lookIntensity = (try? c.decode(Double.self, forKey: .lookIntensity)) ?? 1
        self.exposure    = (try? c.decode(Double.self, forKey: .exposure)) ?? 0
        self.brightness  = (try? c.decode(Double.self, forKey: .brightness)) ?? 0
        self.contrast    = (try? c.decode(Double.self, forKey: .contrast)) ?? 1
        self.saturation  = (try? c.decode(Double.self, forKey: .saturation)) ?? 1
        self.temperature = (try? c.decode(Double.self, forKey: .temperature)) ?? 0
        self.tint        = (try? c.decode(Double.self, forKey: .tint)) ?? 0
        self.intensity   = (try? c.decode(Double.self, forKey: .intensity)) ?? 1
    }
}

extension ColorGrade: KeyframeInterpolatable {
    static func keyframeInterpolate(_ a: ColorGrade, _ b: ColorGrade, t: Double) -> ColorGrade {
        ColorGrade(
            lut:          a.lut,    // hold the look id — a LUT can't cross-fade; only its strength does
            lookIntensity: Double.keyframeInterpolate(a.lookIntensity, b.lookIntensity, t: t),
            exposure:    Double.keyframeInterpolate(a.exposure,    b.exposure,    t: t),
            brightness:  Double.keyframeInterpolate(a.brightness,  b.brightness,  t: t),
            contrast:    Double.keyframeInterpolate(a.contrast,    b.contrast,    t: t),
            saturation:  Double.keyframeInterpolate(a.saturation,  b.saturation,  t: t),
            temperature: Double.keyframeInterpolate(a.temperature, b.temperature, t: t),
            tint:        Double.keyframeInterpolate(a.tint,        b.tint,        t: t),
            intensity:   Double.keyframeInterpolate(a.intensity,   b.intensity,   t: t)
        )
    }
}
