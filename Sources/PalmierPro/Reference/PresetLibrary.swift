import Foundation

/// The small, curated CapCut-style preset library (milestone C).
///
/// Deliberately tiny — the brief is explicit that quality is bounded by a *controllable* set, not an
/// AI gamble. Two doors, one catalog: with a reference, the recipe's fuzzy `vibe` fields snap to these
/// by name; without one, the user browses and picks. Everything realizes into primitives Koma already
/// ships — keyframe tracks (position/scale/opacity) and the color grade — so there is NO new engine.
///
/// LUTs/looks are intentionally absent: that pack is owned by the color-grading milestone. Color is
/// approximated here via the grade's minor knobs until the look pack lands.
enum PresetCategory: String, Codable, Sendable, CaseIterable {
    case transition, captionAnimation = "caption-animation", effect
}

enum PresetKind: String, Codable, Sendable, CaseIterable {
    // Transitions — per-clip "in" animations at a cut (Koma's transitions are per-clip, like its fades).
    case whip, zoomIn = "zoom-in", flash, dissolve
    // Caption animations — for text clips.
    case pop, fadeIn = "fade-in", slideUp = "slide-up"
    // Effects — whole-clip motion/feel.
    case shake, zoomPunch = "zoom-punch", glow

    static func parse(_ s: String) -> PresetKind? {
        let norm = s.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "_", with: "-")
        return PresetKind(rawValue: norm) ?? PresetKind.allCases.first { $0.rawValue == norm }
    }
}

struct PresetInfo: Sendable {
    let kind: PresetKind
    let category: PresetCategory
    let name: String
    let summary: String
    let target: PresetTarget
    let keywords: [String]
}

enum PresetTarget: String, Sendable {
    case visual   // video / image / lottie
    case text     // text + caption clips
}

enum PresetLibrary {
    static let catalog: [PresetInfo] = [
        PresetInfo(kind: .whip, category: .transition, name: "Whip", summary: "Fast directional slide-in at the cut — the whip-pan look.", target: .visual, keywords: ["whip", "pan", "swipe", "fast", "slide", "motion"]),
        PresetInfo(kind: .zoomIn, category: .transition, name: "Zoom In", summary: "Punch-in reveal: starts enlarged and settles to frame.", target: .visual, keywords: ["zoom", "punch", "push", "scale", "reveal", "in"]),
        PresetInfo(kind: .flash, category: .transition, name: "Flash", summary: "Bright exposure pop at the cut, then back to normal.", target: .visual, keywords: ["flash", "bright", "strobe", "white", "pop", "exposure"]),
        PresetInfo(kind: .dissolve, category: .transition, name: "Dissolve", summary: "Gentle opacity fade-in (extends Koma's fades).", target: .visual, keywords: ["dissolve", "fade", "cross", "soft", "blend"]),
        PresetInfo(kind: .pop, category: .captionAnimation, name: "Pop", summary: "Scale overshoot bounce — text snaps in with energy.", target: .text, keywords: ["pop", "bounce", "scale", "spring", "snap", "punch"]),
        PresetInfo(kind: .fadeIn, category: .captionAnimation, name: "Fade In", summary: "Text fades up from transparent.", target: .text, keywords: ["fade", "soft", "appear", "opacity"]),
        PresetInfo(kind: .slideUp, category: .captionAnimation, name: "Slide Up", summary: "Text rises from below while fading in.", target: .text, keywords: ["slide", "rise", "up", "kinetic", "move"]),
        PresetInfo(kind: .shake, category: .effect, name: "Shake", summary: "Camera-shake jitter across the clip.", target: .visual, keywords: ["shake", "jitter", "handheld", "rumble", "wobble", "energy"]),
        PresetInfo(kind: .zoomPunch, category: .effect, name: "Zoom Punch", summary: "A single scale pulse — great on a beat hit.", target: .visual, keywords: ["zoom", "punch", "pulse", "beat", "hit", "kick"]),
        PresetInfo(kind: .glow, category: .effect, name: "Glow", summary: "Soft lifted glow via the grade (approximate; true bloom is a future compositor add).", target: .visual, keywords: ["glow", "bloom", "dream", "soft", "haze", "lift"]),
    ]

    static func info(_ kind: PresetKind) -> PresetInfo { catalog.first { $0.kind == kind }! }

    /// Clip-relative frame that best shows the preset in a single still (for candidate previews).
    static func previewOffset(_ kind: PresetKind, fps: Int) -> Int {
        func f(_ s: Double) -> Int { max(0, Int((s * Double(fps)).rounded())) }
        switch kind {
        case .whip:      return f(0.09)
        case .zoomIn:    return 0
        case .flash:     return f(0.04)
        case .dissolve:  return f(0.15)
        case .pop:       return f(0.12)
        case .fadeIn:    return f(0.12)
        case .slideUp:   return f(0.14)
        case .shake:     return f(0.06)
        case .zoomPunch: return f(0.1)
        case .glow:      return f(0.2)
        }
    }

    /// Realize a preset into the clip's existing keyframe tracks / grade. Mutates in place; call inside
    /// `commitClipProperty`. Frames are clip-relative offsets (track storage convention).
    static func apply(_ kind: PresetKind, to clip: inout Clip, fps: Int) {
        let dur = max(1, clip.durationFrames)
        let cx = clip.transform.centerX, cy = clip.transform.centerY
        let w = clip.transform.width, h = clip.transform.height
        func tl(_ ww: Double, _ hh: Double) -> AnimPair { AnimPair(a: cx - ww / 2, b: cy - hh / 2) }
        func frames(_ sec: Double) -> Int { max(2, min(dur, Int((sec * Double(fps)).rounded()))) }

        switch kind {
        case .whip:
            let n = frames(0.18)
            clip.positionTrack = KeyframeTrack(keyframes: [
                Keyframe(frame: 0, value: AnimPair(a: cx - w / 2 + 0.6, b: cy - h / 2)),
                Keyframe(frame: n, value: tl(w, h)),
            ])
        case .zoomIn:
            let n = frames(0.22), s = 1.3
            clip.scaleTrack = KeyframeTrack(keyframes: [
                Keyframe(frame: 0, value: AnimPair(a: w * s, b: h * s)),
                Keyframe(frame: n, value: AnimPair(a: w, b: h)),
            ])
            clip.positionTrack = KeyframeTrack(keyframes: [
                Keyframe(frame: 0, value: tl(w * s, h * s)),
                Keyframe(frame: n, value: tl(w, h)),
            ])
        case .flash:
            let n = frames(0.12)
            var hot = clip.grade
            hot.exposure = 2.0
            clip.gradeTrack = KeyframeTrack(keyframes: [
                Keyframe(frame: 0, value: hot),
                Keyframe(frame: n, value: clip.grade),
            ])
        case .dissolve:
            let n = frames(0.3)
            clip.opacityTrack = KeyframeTrack(keyframes: [
                Keyframe(frame: 0, value: 0.0),
                Keyframe(frame: n, value: clip.opacity),
            ])
        case .pop:
            let n1 = frames(0.12), n2 = frames(0.22)
            clip.scaleTrack = KeyframeTrack(keyframes: [
                Keyframe(frame: 0, value: AnimPair(a: w * 0.2, b: h * 0.2)),
                Keyframe(frame: n1, value: AnimPair(a: w * 1.12, b: h * 1.12)),
                Keyframe(frame: n2, value: AnimPair(a: w, b: h)),
            ])
            clip.positionTrack = KeyframeTrack(keyframes: [
                Keyframe(frame: 0, value: tl(w * 0.2, h * 0.2)),
                Keyframe(frame: n1, value: tl(w * 1.12, h * 1.12)),
                Keyframe(frame: n2, value: tl(w, h)),
            ])
            clip.opacityTrack = KeyframeTrack(keyframes: [
                Keyframe(frame: 0, value: 0.0),
                Keyframe(frame: n1, value: clip.opacity),
            ])
        case .fadeIn:
            let n = frames(0.25)
            clip.opacityTrack = KeyframeTrack(keyframes: [
                Keyframe(frame: 0, value: 0.0),
                Keyframe(frame: n, value: clip.opacity),
            ])
        case .slideUp:
            let n = frames(0.28), drop = 0.12
            clip.positionTrack = KeyframeTrack(keyframes: [
                Keyframe(frame: 0, value: AnimPair(a: cx - w / 2, b: cy - h / 2 + drop)),
                Keyframe(frame: n, value: tl(w, h)),
            ])
            clip.opacityTrack = KeyframeTrack(keyframes: [
                Keyframe(frame: 0, value: 0.0),
                Keyframe(frame: n, value: clip.opacity),
            ])
        case .shake:
            let amp = 0.012
            let step = max(2, frames(0.06))
            let pattern: [(Double, Double)] = [(0, 0), (amp, -amp), (-amp, amp * 0.6), (amp * 0.7, amp), (-amp, -amp * 0.5), (0, 0)]
            var kfs: [Keyframe<AnimPair>] = []
            var f = 0, i = 0
            while f <= dur {
                let o = pattern[i % pattern.count]
                kfs.append(Keyframe(frame: min(f, dur), value: AnimPair(a: cx - w / 2 + o.0, b: cy - h / 2 + o.1), interpolationOut: .linear))
                f += step; i += 1
            }
            clip.positionTrack = KeyframeTrack(keyframes: kfs)
        case .zoomPunch:
            let n1 = frames(0.1), n2 = frames(0.3), s = 1.12
            clip.scaleTrack = KeyframeTrack(keyframes: [
                Keyframe(frame: 0, value: AnimPair(a: w, b: h)),
                Keyframe(frame: n1, value: AnimPair(a: w * s, b: h * s)),
                Keyframe(frame: n2, value: AnimPair(a: w, b: h)),
            ])
            clip.positionTrack = KeyframeTrack(keyframes: [
                Keyframe(frame: 0, value: tl(w, h)),
                Keyframe(frame: n1, value: tl(w * s, h * s)),
                Keyframe(frame: n2, value: tl(w, h)),
            ])
        case .glow:
            var g = clip.grade
            g.exposure += 0.3
            g.contrast = max(0, g.contrast - 0.05)
            g.saturation += 0.08
            clip.grade = g
        }
    }
}
