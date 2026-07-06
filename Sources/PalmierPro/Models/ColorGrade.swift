import Foundation

/// Per-clip color correction. All channels are neutral at their defaults, so a
/// default `ColorGrade` is the identity (no-op) and clips without a grade render exactly
/// as before. The render-side CIFilter chain lives in `GradeCompositor`; the secondary
/// corrections (hsl/curves/wheels/highlights/shadows/fade) are baked into a 3D correction
/// cube by `GradeMath` and applied as one `CIColorCubeWithColorSpace`.
///
/// Channel domains (clamped on the agent/tool boundary, see ToolExecutor+Grade):
///   exposure    EV stops          neutral 0     range −4…4   (CIExposureAdjust)
///   brightness  additive          neutral 0     range −1…1   (CIColorControls)
///   contrast    multiplicative    neutral 1     range  0…4   (CIColorControls)
///   saturation  multiplicative    neutral 1     range  0…4   (CIColorControls)
///   temperature warm(+)/cool(−)   neutral 0     range −100…100 (CITemperatureAndTint)
///   tint        magenta(+)/green(−) neutral 0   range −100…100 (CITemperatureAndTint)
///   hue         degrees           neutral 0     range −180…180 (CIHueAdjust)
///   highlights  tonal             neutral 0     range −1…1   (correction cube)
///   shadows     tonal             neutral 0     range −1…1   (correction cube)
///   fade        lifted blacks     neutral 0     range  0…1   (correction cube)
///   sharpen     luminance sharpen neutral 0     range  0…1   (CISharpenLuminance)
///   clarity     local contrast    neutral 0     range  0…1   (CIUnsharpMask)
///   vignette    edge darkening    neutral 0     range  0…1   (CIVignette, post-crop)
///   protectSkinTone LUT skin mask neutral 0     range  0…1   (baked into the look cube)
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
    var intensity: Double = 1       // wet/dry of the WHOLE grade (look + all channels)

    // Extended basic scalars (CapCut Adjust parity).
    var hue: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var fade: Double = 0
    var sharpen: Double = 0
    var clarity: Double = 0
    var vignette: Double = 0
    var protectSkinTone: Double = 0 // stored as 0…1 (UI shows a toggle) so it stays interpolatable

    // Secondary corrections (see GradeAdjustments.swift), rendered via the correction cube.
    var hsl: HSLAdjust = HSLAdjust()
    var curves: CurveSet = CurveSet()
    var wheels: ColorWheels = ColorWheels()

    init(
        lut: String? = nil,
        lookIntensity: Double = 1,
        exposure: Double = 0,
        brightness: Double = 0,
        contrast: Double = 1,
        saturation: Double = 1,
        temperature: Double = 0,
        tint: Double = 0,
        intensity: Double = 1,
        hue: Double = 0,
        highlights: Double = 0,
        shadows: Double = 0,
        fade: Double = 0,
        sharpen: Double = 0,
        clarity: Double = 0,
        vignette: Double = 0,
        protectSkinTone: Double = 0,
        hsl: HSLAdjust = HSLAdjust(),
        curves: CurveSet = CurveSet(),
        wheels: ColorWheels = ColorWheels()
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
        self.hue = hue
        self.highlights = highlights
        self.shadows = shadows
        self.fade = fade
        self.sharpen = sharpen
        self.clarity = clarity
        self.vignette = vignette
        self.protectSkinTone = protectSkinTone
        self.hsl = hsl
        self.curves = curves
        self.wheels = wheels
    }

    /// True when the grade changes nothing — lets the render path keep the stock
    /// (built-in compositor) fast path and skip the GradeCompositor entirely.
    /// `protectSkinTone` alone is identity: it only modulates a LUT, and there is none.
    var isIdentity: Bool {
        lut == nil && exposure == 0 && brightness == 0 && contrast == 1 && saturation == 1
            && temperature == 0 && tint == 0
            && hue == 0 && sharpen == 0 && clarity == 0 && vignette == 0
            && !needsCorrectionCube
    }

    /// True when any channel that renders through the baked correction cube is non-neutral.
    var needsCorrectionCube: Bool {
        highlights != 0 || shadows != 0 || fade != 0
            || !hsl.isIdentity || !curves.isIdentity || !wheels.isIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case lut, lookIntensity, exposure, brightness, contrast, saturation, temperature, tint, intensity
        case hue, highlights, shadows, fade, sharpen, clarity, vignette, protectSkinTone
        case hsl, curves, wheels
    }

    // Forward/back-compatible decode: any missing channel falls back to its neutral default,
    // so older projects (no grade / fewer channels) and partial writes load clean.
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
        self.hue         = (try? c.decode(Double.self, forKey: .hue)) ?? 0
        self.highlights  = (try? c.decode(Double.self, forKey: .highlights)) ?? 0
        self.shadows     = (try? c.decode(Double.self, forKey: .shadows)) ?? 0
        self.fade        = (try? c.decode(Double.self, forKey: .fade)) ?? 0
        self.sharpen     = (try? c.decode(Double.self, forKey: .sharpen)) ?? 0
        self.clarity     = (try? c.decode(Double.self, forKey: .clarity)) ?? 0
        self.vignette    = (try? c.decode(Double.self, forKey: .vignette)) ?? 0
        self.protectSkinTone = (try? c.decode(Double.self, forKey: .protectSkinTone)) ?? 0
        self.hsl    = (try? c.decode(HSLAdjust.self, forKey: .hsl)) ?? HSLAdjust()
        self.curves = (try? c.decode(CurveSet.self, forKey: .curves)) ?? CurveSet()
        self.wheels = (try? c.decode(ColorWheels.self, forKey: .wheels)) ?? ColorWheels()
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
            intensity:   Double.keyframeInterpolate(a.intensity,   b.intensity,   t: t),
            hue:         Double.keyframeInterpolate(a.hue,         b.hue,         t: t),
            highlights:  Double.keyframeInterpolate(a.highlights,  b.highlights,  t: t),
            shadows:     Double.keyframeInterpolate(a.shadows,     b.shadows,     t: t),
            fade:        Double.keyframeInterpolate(a.fade,        b.fade,        t: t),
            sharpen:     Double.keyframeInterpolate(a.sharpen,     b.sharpen,     t: t),
            clarity:     Double.keyframeInterpolate(a.clarity,     b.clarity,     t: t),
            vignette:    Double.keyframeInterpolate(a.vignette,    b.vignette,    t: t),
            protectSkinTone: Double.keyframeInterpolate(a.protectSkinTone, b.protectSkinTone, t: t),
            hsl:    HSLAdjust.keyframeInterpolate(a.hsl,    b.hsl,    t: t),
            curves: CurveSet.keyframeInterpolate(a.curves,  b.curves, t: t),
            wheels: ColorWheels.keyframeInterpolate(a.wheels, b.wheels, t: t)
        )
    }
}
