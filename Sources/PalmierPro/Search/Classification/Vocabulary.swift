import CryptoKit
import Foundation

/// The classification language (M2). Namespaced facets + terse tokens; each label is a
/// `(token, [prompts])`. Prompts are SigLIP text queries (ensemble allowed — mean-pooled).
/// A scene "is" a label if it scores above a generic "null" anchor by a margin. Versioned by
/// a content fingerprint (folded with the model id) so any prompt/model change re-classifies.

enum FacetMode: String, Codable, Equatable, Sendable {
    case exclusive   // assign at most one label (the top scorer) — e.g. primary use
    case multi       // assign every label above the null anchor, capped
}

struct LabelDef: Codable, Equatable, Sendable {
    let token: String          // "facet:value"
    let prompts: [String]
    var margin: Double?         // overrides the facet default
    var facet: String { String(token.prefix { $0 != ":" }) }
    /// The display value after the facet prefix ("set:night" → "night").
    var value: String { String(token.drop { $0 != ":" }.dropFirst()) }
}

struct FacetDef: Codable, Equatable, Sendable {
    let id: String             // "set"
    let mode: FacetMode
    var defaultMargin: Double   // how far a label must beat the null anchor
    var maxLabels: Int          // cap for multi facets
}

struct Vocabulary: Codable, Equatable, Sendable {
    var facets: [FacetDef]
    var labels: [LabelDef]
    var nullPrompts: [String]   // generic "any frame" anchor; calibrates the threshold

    func facet(_ id: String) -> FacetDef? { facets.first { $0.id == id } }

    /// Stable hash of the vocabulary content folded with the embedding model identity, so
    /// editing a prompt OR swapping the model invalidates caches and sidecars alike.
    func fingerprint(model: String, modelVersion: Int) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hasher = SHA256()
        hasher.update(data: (try? encoder.encode(self)) ?? Data())
        hasher.update(data: Data("\(model)|\(modelVersion)".utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// The effective vocabulary. Seed for now; a user/Kibo override file lands in M2b.
    static func current() -> Vocabulary { seed }
}

extension Vocabulary {
    /// Seed vocabulary. Facets are mostly multi-label because the doc's `set`/`shot` groups mix
    /// orthogonal dimensions (indoor vs. night, framing vs. camera motion); only `use` is a
    /// single primary pick. Margins are small (SigLIP cosines compress) and meant to be tuned.
    static let seed = Vocabulary(
        facets: [
            FacetDef(id: "subj", mode: .multi, defaultMargin: 0.015, maxLabels: 3),
            FacetDef(id: "act",  mode: .multi, defaultMargin: 0.020, maxLabels: 2),
            FacetDef(id: "set",  mode: .multi, defaultMargin: 0.015, maxLabels: 3),
            FacetDef(id: "shot", mode: .multi, defaultMargin: 0.020, maxLabels: 2),
            FacetDef(id: "mood", mode: .multi, defaultMargin: 0.025, maxLabels: 1),
            FacetDef(id: "use",  mode: .exclusive, defaultMargin: 0.020, maxLabels: 1),
        ],
        labels: [
            // subject
            LabelDef(token: "subj:person",    prompts: ["a person", "people in the frame"]),
            LabelDef(token: "subj:hands",     prompts: ["close-up of human hands", "hands working on something"]),
            LabelDef(token: "subj:product",   prompts: ["a product shot", "an object on display"]),
            LabelDef(token: "subj:screen",    prompts: ["a computer or phone screen", "a screen showing content"]),
            LabelDef(token: "subj:food",      prompts: ["food", "a plate of food", "a meal"]),
            LabelDef(token: "subj:landscape", prompts: ["a landscape", "scenery", "a natural vista"]),
            LabelDef(token: "subj:animal",    prompts: ["an animal", "a pet"]),
            // action
            LabelDef(token: "act:walking",    prompts: ["a person walking"]),
            LabelDef(token: "act:talking",    prompts: ["a person talking to the camera", "people in conversation"]),
            LabelDef(token: "act:cooking",    prompts: ["cooking food", "preparing a meal"]),
            LabelDef(token: "act:typing",     prompts: ["typing on a keyboard", "working at a laptop"]),
            LabelDef(token: "act:driving",    prompts: ["driving a vehicle", "a view from a moving car"]),
            LabelDef(token: "act:gesturing",  prompts: ["a person gesturing with their hands"]),
            // setting
            LabelDef(token: "set:indoor",     prompts: ["an indoor scene", "inside a building"]),
            LabelDef(token: "set:outdoor",    prompts: ["an outdoor scene", "outside in the open"]),
            LabelDef(token: "set:night",      prompts: ["a scene at night", "a dark nighttime scene"]),
            LabelDef(token: "set:day",        prompts: ["a scene in bright daylight"]),
            LabelDef(token: "set:studio",     prompts: ["a studio setting", "a photo or film studio"]),
            LabelDef(token: "set:kitchen",    prompts: ["a kitchen"]),
            LabelDef(token: "set:street",     prompts: ["a city street", "an urban street scene"]),
            // framing
            LabelDef(token: "shot:wide",      prompts: ["a wide establishing shot", "a wide angle view"]),
            LabelDef(token: "shot:closeup",   prompts: ["a close-up shot", "a tight closeup"]),
            LabelDef(token: "shot:aerial",    prompts: ["an aerial drone shot from above", "a bird's eye view"]),
            LabelDef(token: "shot:pov",       prompts: ["a first-person point of view shot"]),
            // mood
            LabelDef(token: "mood:calm",      prompts: ["a calm, peaceful, serene scene"]),
            LabelDef(token: "mood:energetic", prompts: ["an energetic, dynamic, fast-paced scene"]),
            LabelDef(token: "mood:warm",      prompts: ["a warm, cozy, intimate scene"]),
            // usability
            LabelDef(token: "use:talking-head", prompts: ["a person speaking directly to the camera, talking head"]),
            LabelDef(token: "use:broll",        prompts: ["b-roll footage of a scene with no speaker"]),
            LabelDef(token: "use:establishing", prompts: ["an establishing shot setting a location"]),
        ],
        nullPrompts: ["a video frame", "a random photograph", "a generic image"]
    )
}
