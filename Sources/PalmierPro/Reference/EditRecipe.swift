import Foundation

/// The structured, confidence-tagged "edit recipe" derived from a reference video.
///
/// Two halves, per the reference-driven-editing design:
///   • Deterministic fields (format · pacing · beat · captions · color) come from on-device CV/DSP
///     in `ReferenceAnalyzer` — frame-accurate, high confidence, auto-applied.
///   • The `vibe` half (transition style · caption animation · look · effects) is filled by the
///     agent looking at the storyboard frames — fuzzy, low confidence, surfaced as candidate picks.
///
/// Every section carries a `confidence` 0…1 so the apply step can split "auto-apply" (high) from
/// "ask the user / pick the closest preset" (low).
struct EditRecipe: Codable, Sendable, Equatable {
    var referenceMediaRef: String
    var format: FormatRecipe
    var pacing: PacingRecipe
    var beat: BeatRecipe
    var captions: CaptionRecipe
    var color: ColorMoodRecipe
    /// Agent-filled after looking at the storyboard. Nil until the vibe pass runs.
    var vibe: VibeRecipe?
}

/// Aspect / length / fps — measured exactly, so confidence is ~1.0.
struct FormatRecipe: Codable, Sendable, Equatable {
    var width: Int
    var height: Int
    var aspectRatio: String          // e.g. "9:16"
    var durationSeconds: Double
    var fps: Double
    var confidence: Double
}

/// Cut rhythm — the soul of short-form. Shot boundaries are frame-accurate from feature-print diffs.
struct PacingRecipe: Codable, Sendable, Equatable {
    var cutCount: Int
    var cutsPerSecond: Double
    var averageShotSeconds: Double
    var shotBoundariesSeconds: [Double]
    var confidence: Double
}

/// Tempo grid for cut-to-beat alignment. bpm nil when no confident periodicity was found.
struct BeatRecipe: Codable, Sendable, Equatable {
    var bpm: Double?
    var beatTimesSeconds: [Double]
    var confidence: Double
    var note: String?
}

/// On-screen caption presence + cadence (not the words — those are licensing-bound / re-authored).
struct CaptionRecipe: Codable, Sendable, Equatable {
    var present: Bool
    var coverage: Double             // fraction of sampled frames showing text, 0…1
    var position: String?            // "bottom" | "center" | "top"
    var changesPerSecond: Double?
    var confidence: Double
}

/// Aggregate color feel, used to pick the closest LUT/look (matched by ΔE downstream — see design).
struct ColorMoodRecipe: Codable, Sendable, Equatable {
    var averageRGB: [Double]         // [r,g,b] 0…1
    var brightness: Double           // 0…1
    var saturation: Double           // 0…1
    var warmth: Double               // -1 cool … +1 warm
    var moodHint: String
    var confidence: Double
}

/// The fuzzy half the agent infers from the storyboard. Each value is a *guess* the apply step
/// snaps to the nearest preset and confirms with the user — never silently applied.
struct VibeRecipe: Codable, Sendable, Equatable {
    var transitionStyle: String?     // e.g. "whip" | "zoom" | "flash" | "cut"
    var captionAnimation: String?    // e.g. "pop" | "typewriter"
    var colorLook: String?           // LUT/look name — deferred to color grading's look pack
    var effects: [String]?           // e.g. ["shake","zoom-punch"]
    var summary: String?             // one-line description of the overall style
}
