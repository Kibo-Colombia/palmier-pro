import Foundation

// MARK: set_grade — per-clip primary color correction (grade by conversation)

/// One HSL band's partial adjustment (all −1…1). Omitted components keep their value.
fileprivate struct HSLBandInput: Decodable {
    let hue: Double?
    let saturation: Double?
    let luminance: Double?
}

/// Partial per-band HSL: only the bands present are touched; `reset` clears all bands first.
fileprivate struct HSLInput: Decodable {
    let red: HSLBandInput?
    let orange: HSLBandInput?
    let yellow: HSLBandInput?
    let green: HSLBandInput?
    let cyan: HSLBandInput?
    let blue: HSLBandInput?
    let purple: HSLBandInput?
    let magenta: HSLBandInput?
    let reset: Bool?

    var bands: [(index: Int, input: HSLBandInput)] {
        [red, orange, yellow, green, cyan, blue, purple, magenta]
            .enumerated()
            .compactMap { i, b in b.map { (i, $0) } }
    }

    var hasAnyField: Bool { !bands.isEmpty || reset == true }
}

/// Partial tone curves: only channels present are replaced. Each channel is a list of
/// [x, y] pairs in 0…1; an empty list resets that channel to identity.
fileprivate struct CurvesInput: Decodable {
    let rgb: [[Double]]?
    let red: [[Double]]?
    let green: [[Double]]?
    let blue: [[Double]]?

    var hasAnyField: Bool { rgb != nil || red != nil || green != nil || blue != nil }

    /// Validate and convert one channel's raw pairs into sorted CurvePoints.
    static func parseChannel(_ raw: [[Double]], name: String) throws -> [CurvePoint] {
        guard raw.count <= 16 else { throw ToolError("set_grade.curves.\(name): at most 16 points") }
        if !raw.isEmpty && raw.count < 2 { throw ToolError("set_grade.curves.\(name): need at least 2 points (or [] to reset)") }
        let pts = try raw.map { pair -> CurvePoint in
            guard pair.count == 2 else { throw ToolError("set_grade.curves.\(name): each point must be [x, y]") }
            return CurvePoint(x: min(1, max(0, pair[0])), y: min(1, max(0, pair[1])))
        }
        return pts.sorted { $0.x < $1.x }
    }
}

/// One wheel's partial adjustment (r/g/b/luma each −1…1); omitted components keep their value.
fileprivate struct WheelInput: Decodable {
    let r: Double?
    let g: Double?
    let b: Double?
    let luma: Double?
}

/// Partial color wheels: only the wheels present are touched.
fileprivate struct WheelsInput: Decodable {
    let lift: WheelInput?
    let gamma: WheelInput?
    let gain: WheelInput?
    let offset: WheelInput?
    let reset: Bool?

    var hasAnyField: Bool { lift != nil || gamma != nil || gain != nil || offset != nil || reset == true }
}

fileprivate struct SetGradeInput: DecodableToolArgs {
    let clipIds: [String]
    let exposure: Double?
    let brightness: Double?
    let contrast: Double?
    let saturation: Double?
    let temperature: Double?
    let tint: Double?
    let hue: Double?
    let highlights: Double?
    let shadows: Double?
    let fade: Double?
    let sharpen: Double?
    let clarity: Double?
    let vignette: Double?
    let lookIntensity: Double?
    let protectSkinTone: Bool?
    let intensity: Double?
    let hsl: HSLInput?
    let curves: CurvesInput?
    let wheels: WheelsInput?
    let reset: Bool?

    static let allowedKeys: Set<String> = [
        "clipIds", "exposure", "brightness", "contrast", "saturation",
        "temperature", "tint", "hue", "highlights", "shadows", "fade",
        "sharpen", "clarity", "vignette", "lookIntensity", "protectSkinTone",
        "intensity", "hsl", "curves", "wheels", "reset",
    ]

    var hasAnyField: Bool {
        exposure != nil || brightness != nil || contrast != nil || saturation != nil
            || temperature != nil || tint != nil || hue != nil || highlights != nil
            || shadows != nil || fade != nil || sharpen != nil || clarity != nil
            || vignette != nil || lookIntensity != nil || protectSkinTone != nil
            || intensity != nil || hsl?.hasAnyField == true || curves?.hasAnyField == true
            || wheels?.hasAnyField == true || reset == true
    }
}

extension ToolExecutor {
    /// Channel clamp domains (mirrors the CIFilter-sane ranges in GradeCompositor).
    nonisolated private static func clampGrade(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    func setGrade(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        // JSONDecoder silently drops unknown keys — reject misspelled band/channel names explicitly.
        if let rawHSL = args["hsl"] as? [String: Any] {
            try validateUnknownKeys(rawHSL, allowed: Set(HSLAdjust.bandNames + ["reset"]), path: "set_grade.hsl")
            for (band, value) in rawHSL where band != "reset" {
                if let components = value as? [String: Any] {
                    try validateUnknownKeys(components, allowed: ["hue", "saturation", "luminance"], path: "set_grade.hsl.\(band)")
                }
            }
        }
        if let rawCurves = args["curves"] as? [String: Any] {
            try validateUnknownKeys(rawCurves, allowed: ["rgb", "red", "green", "blue"], path: "set_grade.curves")
        }
        if let rawWheels = args["wheels"] as? [String: Any] {
            try validateUnknownKeys(rawWheels, allowed: ["lift", "gamma", "gain", "offset", "reset"], path: "set_grade.wheels")
            for (wheel, value) in rawWheels where wheel != "reset" {
                if let components = value as? [String: Any] {
                    try validateUnknownKeys(components, allowed: ["r", "g", "b", "luma"], path: "set_grade.wheels.\(wheel)")
                }
            }
        }
        let input: SetGradeInput = try decodeToolArgs(args, path: "set_grade")
        guard !input.clipIds.isEmpty else { throw ToolError("Missing or empty 'clipIds' array") }
        guard input.hasAnyField else {
            throw ToolError("set_grade needs at least one channel (exposure/brightness/contrast/saturation/temperature/tint/hue/highlights/shadows/fade/sharpen/clarity/vignette/lookIntensity/protectSkinTone/intensity) or reset:true")
        }

        // Resolve every clip up front; grade is a visual property — reject audio clips.
        for id in input.clipIds {
            guard let loc = editor.findClip(id: id) else { throw ToolError("Clip not found: \(id)") }
            let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            if clip.mediaType == .audio {
                throw ToolError("Cannot grade an audio clip: \(id)")
            }
        }

        // Parse curve channels up front so malformed input fails before any clip mutates.
        let parsedCurves: (rgb: [CurvePoint]?, red: [CurvePoint]?, green: [CurvePoint]?, blue: [CurvePoint]?) = (
            try input.curves?.rgb.map   { try CurvesInput.parseChannel($0, name: "rgb") },
            try input.curves?.red.map   { try CurvesInput.parseChannel($0, name: "red") },
            try input.curves?.green.map { try CurvesInput.parseChannel($0, name: "green") },
            try input.curves?.blue.map  { try CurvesInput.parseChannel($0, name: "blue") }
        )

        let actionName = input.clipIds.count == 1 ? "Color Grade (Agent)" : "Color Grade \(input.clipIds.count) Clips (Agent)"
        let summaries: [String] = withUndoGroup(editor, actionName: actionName) {
            var out: [String] = []
            for id in input.clipIds {
                var changed: [String] = []
                editor.commitClipProperty(clipId: id) { clip in
                    var g = clip.grade
                    if input.reset == true { g = ColorGrade() }
                    if let v = input.exposure    { g.exposure    = Self.clampGrade(v, -4...4);   changed.append("exposure \(fmt(g.exposure))") }
                    if let v = input.brightness  { g.brightness  = Self.clampGrade(v, -1...1);   changed.append("brightness \(fmt(g.brightness))") }
                    if let v = input.contrast    { g.contrast    = Self.clampGrade(v, 0...4);    changed.append("contrast \(fmt(g.contrast))") }
                    if let v = input.saturation  { g.saturation  = Self.clampGrade(v, 0...4);    changed.append("saturation \(fmt(g.saturation))") }
                    if let v = input.temperature { g.temperature = Self.clampGrade(v, -100...100); changed.append("temperature \(fmt(g.temperature))") }
                    if let v = input.tint        { g.tint        = Self.clampGrade(v, -100...100); changed.append("tint \(fmt(g.tint))") }
                    if let v = input.hue         { g.hue         = Self.clampGrade(v, -180...180); changed.append("hue \(fmt(g.hue))") }
                    if let v = input.highlights  { g.highlights  = Self.clampGrade(v, -1...1);   changed.append("highlights \(fmt(g.highlights))") }
                    if let v = input.shadows     { g.shadows     = Self.clampGrade(v, -1...1);   changed.append("shadows \(fmt(g.shadows))") }
                    if let v = input.fade        { g.fade        = Self.clampGrade(v, 0...1);    changed.append("fade \(fmt(g.fade))") }
                    if let v = input.sharpen     { g.sharpen     = Self.clampGrade(v, 0...1);    changed.append("sharpen \(fmt(g.sharpen))") }
                    if let v = input.clarity     { g.clarity     = Self.clampGrade(v, 0...1);    changed.append("clarity \(fmt(g.clarity))") }
                    if let v = input.vignette    { g.vignette    = Self.clampGrade(v, 0...1);    changed.append("vignette \(fmt(g.vignette))") }
                    if let v = input.lookIntensity { g.lookIntensity = Self.clampGrade(v, 0...1); changed.append("lookIntensity \(fmt(g.lookIntensity))") }
                    if let v = input.protectSkinTone { g.protectSkinTone = v ? 1 : 0; changed.append("protectSkinTone \(v ? "on" : "off")") }
                    if let v = input.intensity   { g.intensity   = Self.clampGrade(v, 0...1);    changed.append("intensity \(fmt(g.intensity))") }
                    if let c = parsedCurves.rgb   { g.curves.rgb   = c; changed.append("curves.rgb \(c.count)pts") }
                    if let c = parsedCurves.red   { g.curves.red   = c; changed.append("curves.red \(c.count)pts") }
                    if let c = parsedCurves.green { g.curves.green = c; changed.append("curves.green \(c.count)pts") }
                    if let c = parsedCurves.blue  { g.curves.blue  = c; changed.append("curves.blue \(c.count)pts") }
                    if let w = input.wheels {
                        if w.reset == true { g.wheels = ColorWheels(); changed.append("wheels reset") }
                        func merge(_ wheel: WheelInput?, into target: inout WheelAdjust, name: String) {
                            guard let wheel else { return }
                            if let v = wheel.r    { target.r    = Self.clampGrade(v, -1...1) }
                            if let v = wheel.g    { target.g    = Self.clampGrade(v, -1...1) }
                            if let v = wheel.b    { target.b    = Self.clampGrade(v, -1...1) }
                            if let v = wheel.luma { target.luma = Self.clampGrade(v, -1...1) }
                            changed.append("wheels.\(name)")
                        }
                        merge(w.lift, into: &g.wheels.lift, name: "lift")
                        merge(w.gamma, into: &g.wheels.gamma, name: "gamma")
                        merge(w.gain, into: &g.wheels.gain, name: "gain")
                        merge(w.offset, into: &g.wheels.offset, name: "offset")
                    }
                    if let h = input.hsl {
                        if h.reset == true { g.hsl = HSLAdjust(); changed.append("hsl reset") }
                        for (i, band) in h.bands {
                            let name = HSLAdjust.bandNames[i]
                            if let v = band.hue        { g.hsl.hueShift[i]   = Self.clampGrade(v, -1...1); changed.append("\(name).hue \(fmt(g.hsl.hueShift[i]))") }
                            if let v = band.saturation { g.hsl.saturation[i] = Self.clampGrade(v, -1...1); changed.append("\(name).sat \(fmt(g.hsl.saturation[i]))") }
                            if let v = band.luminance  { g.hsl.luminance[i]  = Self.clampGrade(v, -1...1); changed.append("\(name).lum \(fmt(g.hsl.luminance[i]))") }
                        }
                    }
                    clip.grade = g
                }
                if input.reset == true && changed.isEmpty {
                    out.append("\(id): reset to neutral")
                } else {
                    out.append("\(id): \(changed.joined(separator: ", "))")
                }
            }
            return out
        }

        let n = input.clipIds.count
        return .ok("Graded \(n) clip\(n == 1 ? "" : "s"): \(summaries.joined(separator: "; "))")
    }
}

/// Compact number formatting for the per-clip echo (drops trailing zeros).
private func fmt(_ v: Double) -> String {
    if v == v.rounded() { return String(Int(v)) }
    return String(format: "%.2f", v)
}
