import Foundation

// MARK: set_grade — per-clip color correction (grade by conversation)
//
// The channel-parsing core is `GradeChannels`, shared by set_grade (merged over each clip's
// static grade) and set_keyframes' grade rows (merged over the clip's static grade per row).

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
    static func parseChannel(_ raw: [[Double]], name: String, path: String) throws -> [CurvePoint] {
        guard raw.count <= 16 else { throw ToolError("\(path).curves.\(name): at most 16 points") }
        if !raw.isEmpty && raw.count < 2 { throw ToolError("\(path).curves.\(name): need at least 2 points (or [] to reset)") }
        let pts = try raw.map { pair -> CurvePoint in
            guard pair.count == 2 else { throw ToolError("\(path).curves.\(name): each point must be [x, y]") }
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

/// Every grade channel of a set_grade-style JSON object (everything except clipIds).
fileprivate struct GradeChannelsInput: Decodable {
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

    var hasAnyField: Bool {
        exposure != nil || brightness != nil || contrast != nil || saturation != nil
            || temperature != nil || tint != nil || hue != nil || highlights != nil
            || shadows != nil || fade != nil || sharpen != nil || clarity != nil
            || vignette != nil || lookIntensity != nil || protectSkinTone != nil
            || intensity != nil || hsl?.hasAnyField == true || curves?.hasAnyField == true
            || wheels?.hasAnyField == true || reset == true
    }
}

/// A fully validated partial grade — parse once, merge over any base grade.
struct GradeChannels {
    static let allowedKeys: Set<String> = [
        "exposure", "brightness", "contrast", "saturation",
        "temperature", "tint", "hue", "highlights", "shadows", "fade",
        "sharpen", "clarity", "vignette", "lookIntensity", "protectSkinTone",
        "intensity", "hsl", "curves", "wheels", "reset",
    ]

    private let input: GradeChannelsInput
    private let curves: (rgb: [CurvePoint]?, red: [CurvePoint]?, green: [CurvePoint]?, blue: [CurvePoint]?)

    var hasAnyField: Bool { input.hasAnyField }

    /// Validate keys (JSONDecoder silently drops unknown ones — reject misspellings explicitly)
    /// and pre-parse curves so malformed input fails before anything mutates.
    static func parse(_ raw: [String: Any], path: String) throws -> GradeChannels {
        try validateUnknownKeys(raw, allowed: allowedKeys, path: path)
        if let rawHSL = raw["hsl"] as? [String: Any] {
            try validateUnknownKeys(rawHSL, allowed: Set(HSLAdjust.bandNames + ["reset"]), path: "\(path).hsl")
            for (band, value) in rawHSL where band != "reset" {
                if let components = value as? [String: Any] {
                    try validateUnknownKeys(components, allowed: ["hue", "saturation", "luminance"], path: "\(path).hsl.\(band)")
                }
            }
        }
        if let rawCurves = raw["curves"] as? [String: Any] {
            try validateUnknownKeys(rawCurves, allowed: ["rgb", "red", "green", "blue"], path: "\(path).curves")
        }
        if let rawWheels = raw["wheels"] as? [String: Any] {
            try validateUnknownKeys(rawWheels, allowed: ["lift", "gamma", "gain", "offset", "reset"], path: "\(path).wheels")
            for (wheel, value) in rawWheels where wheel != "reset" {
                if let components = value as? [String: Any] {
                    try validateUnknownKeys(components, allowed: ["r", "g", "b", "luma"], path: "\(path).wheels.\(wheel)")
                }
            }
        }

        let data: Data
        do { data = try JSONSerialization.data(withJSONObject: raw) }
        catch { throw ToolError("\(path): could not re-serialize args (\(error.localizedDescription))") }
        let input: GradeChannelsInput
        do { input = try JSONDecoder().decode(GradeChannelsInput.self, from: data) }
        catch { throw ToolError("\(path): \(error.localizedDescription)") }

        let parsedCurves = (
            try input.curves?.rgb.map   { try CurvesInput.parseChannel($0, name: "rgb", path: path) },
            try input.curves?.red.map   { try CurvesInput.parseChannel($0, name: "red", path: path) },
            try input.curves?.green.map { try CurvesInput.parseChannel($0, name: "green", path: path) },
            try input.curves?.blue.map  { try CurvesInput.parseChannel($0, name: "blue", path: path) }
        )
        return GradeChannels(input: input, curves: parsedCurves)
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    /// Apply the partial channels over `base`. Returns the merged grade and a compact
    /// description of every channel that was set (for the tool echo).
    func merged(over base: ColorGrade) -> (grade: ColorGrade, changed: [String]) {
        var g = base
        var changed: [String] = []
        if input.reset == true { g = ColorGrade(); changed.append("reset") }
        if let v = input.exposure    { g.exposure    = Self.clamp(v, -4...4);   changed.append("exposure \(fmt(g.exposure))") }
        if let v = input.brightness  { g.brightness  = Self.clamp(v, -1...1);   changed.append("brightness \(fmt(g.brightness))") }
        if let v = input.contrast    { g.contrast    = Self.clamp(v, 0...4);    changed.append("contrast \(fmt(g.contrast))") }
        if let v = input.saturation  { g.saturation  = Self.clamp(v, 0...4);    changed.append("saturation \(fmt(g.saturation))") }
        if let v = input.temperature { g.temperature = Self.clamp(v, -100...100); changed.append("temperature \(fmt(g.temperature))") }
        if let v = input.tint        { g.tint        = Self.clamp(v, -100...100); changed.append("tint \(fmt(g.tint))") }
        if let v = input.hue         { g.hue         = Self.clamp(v, -180...180); changed.append("hue \(fmt(g.hue))") }
        if let v = input.highlights  { g.highlights  = Self.clamp(v, -1...1);   changed.append("highlights \(fmt(g.highlights))") }
        if let v = input.shadows     { g.shadows     = Self.clamp(v, -1...1);   changed.append("shadows \(fmt(g.shadows))") }
        if let v = input.fade        { g.fade        = Self.clamp(v, 0...1);    changed.append("fade \(fmt(g.fade))") }
        if let v = input.sharpen     { g.sharpen     = Self.clamp(v, 0...1);    changed.append("sharpen \(fmt(g.sharpen))") }
        if let v = input.clarity     { g.clarity     = Self.clamp(v, 0...1);    changed.append("clarity \(fmt(g.clarity))") }
        if let v = input.vignette    { g.vignette    = Self.clamp(v, 0...1);    changed.append("vignette \(fmt(g.vignette))") }
        if let v = input.lookIntensity { g.lookIntensity = Self.clamp(v, 0...1); changed.append("lookIntensity \(fmt(g.lookIntensity))") }
        if let v = input.protectSkinTone { g.protectSkinTone = v ? 1 : 0; changed.append("protectSkinTone \(v ? "on" : "off")") }
        if let v = input.intensity   { g.intensity   = Self.clamp(v, 0...1);    changed.append("intensity \(fmt(g.intensity))") }
        if let c = curves.rgb   { g.curves.rgb   = c; changed.append("curves.rgb \(c.count)pts") }
        if let c = curves.red   { g.curves.red   = c; changed.append("curves.red \(c.count)pts") }
        if let c = curves.green { g.curves.green = c; changed.append("curves.green \(c.count)pts") }
        if let c = curves.blue  { g.curves.blue  = c; changed.append("curves.blue \(c.count)pts") }
        if let w = input.wheels {
            if w.reset == true { g.wheels = ColorWheels(); changed.append("wheels reset") }
            func merge(_ wheel: WheelInput?, into target: inout WheelAdjust, name: String) {
                guard let wheel else { return }
                if let v = wheel.r    { target.r    = Self.clamp(v, -1...1) }
                if let v = wheel.g    { target.g    = Self.clamp(v, -1...1) }
                if let v = wheel.b    { target.b    = Self.clamp(v, -1...1) }
                if let v = wheel.luma { target.luma = Self.clamp(v, -1...1) }
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
                if let v = band.hue        { g.hsl.hueShift[i]   = Self.clamp(v, -1...1); changed.append("\(name).hue \(fmt(g.hsl.hueShift[i]))") }
                if let v = band.saturation { g.hsl.saturation[i] = Self.clamp(v, -1...1); changed.append("\(name).sat \(fmt(g.hsl.saturation[i]))") }
                if let v = band.luminance  { g.hsl.luminance[i]  = Self.clamp(v, -1...1); changed.append("\(name).lum \(fmt(g.hsl.luminance[i]))") }
            }
        }
        return (g, changed)
    }
}

extension ToolExecutor {
    func setGrade(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        guard let clipIds = args["clipIds"] as? [String], !clipIds.isEmpty else {
            throw ToolError("Missing or empty 'clipIds' array")
        }
        var channelArgs = args
        channelArgs.removeValue(forKey: "clipIds")
        let channels = try GradeChannels.parse(channelArgs, path: "set_grade")
        guard channels.hasAnyField else {
            throw ToolError("set_grade needs at least one channel (exposure/brightness/contrast/saturation/temperature/tint/hue/highlights/shadows/fade/sharpen/clarity/vignette/lookIntensity/protectSkinTone/intensity/hsl/curves/wheels) or reset:true")
        }

        // Resolve every clip up front; grade is a visual property — reject audio clips.
        for id in clipIds {
            guard let loc = editor.findClip(id: id) else { throw ToolError("Clip not found: \(id)") }
            let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            if clip.mediaType == .audio {
                throw ToolError("Cannot grade an audio clip: \(id)")
            }
        }

        let actionName = clipIds.count == 1 ? "Color Grade (Agent)" : "Color Grade \(clipIds.count) Clips (Agent)"
        let summaries: [String] = withUndoGroup(editor, actionName: actionName) {
            var out: [String] = []
            for id in clipIds {
                var summary = ""
                editor.commitClipProperty(clipId: id) { clip in
                    let (grade, changed) = channels.merged(over: clip.grade)
                    clip.grade = grade
                    summary = changed.joined(separator: ", ")
                }
                out.append("\(id): \(summary.isEmpty ? "no change" : summary)")
            }
            return out
        }

        let n = clipIds.count
        return .ok("Graded \(n) clip\(n == 1 ? "" : "s"): \(summaries.joined(separator: "; "))")
    }
}

/// Compact number formatting for the per-clip echo (drops trailing zeros).
private func fmt(_ v: Double) -> String {
    if v == v.rounded() { return String(Int(v)) }
    return String(format: "%.2f", v)
}
