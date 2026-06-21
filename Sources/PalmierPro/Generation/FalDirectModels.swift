import Foundation

/// Single source of truth for whether AI generation is allowed, and by which route.
///
/// Two independent routes can power generation:
///  - **Palmier (Convex)** — the user is signed in and has credits. Palmier bills.
///  - **fal BYOK** — the user supplied their own fal.ai key in Settings. fal bills them
///    directly, so Palmier credits are irrelevant.
///
/// Keeping this in one place means the MCP/agent gates, the timeline `canGenerate`
/// flag, and the backend branch all agree.
@MainActor
enum GenerationGate {
    /// True when a fal key is present AND we're not signed into Palmier's Convex.
    /// In that case the backend routes generation directly to fal.ai.
    static var falDirectActive: Bool {
        FalKeychain.hasKey && AccountService.shared.convex == nil
    }

    /// True when any generation route is available (Palmier signed-in + credits, or fal BYOK).
    static var canGenerate: Bool {
        (AccountService.shared.isSignedIn && AccountService.shared.hasCredits) || FalKeychain.hasKey
    }
}

// MARK: - Static fal.ai models (available without a Palmier account)

/// fal.ai models that work via BYOK, independent of the Convex catalog.
///
/// The Convex `models:list` subscription is empty when signed out, so these static
/// entries are merged into `ModelCatalog` whenever a fal key is present. Each maps a
/// Palmier `CatalogEntry`/caps to a real fal endpoint; the request-body translation
/// lives in `FalDirectBackend`.
enum FalDirectModels {
    /// fal model id (also the queue endpoint path). CassetteAI text-to-music:
    /// instrumental music from a text prompt, duration 10–180s, returns `audio_file.url`.
    static let cassetteMusicId = "cassetteai/music-generator"

    /// Audio models exposed in BYOK mode.
    static let audio: [AudioModelConfig] = [
        AudioModelConfig(
            entry: CatalogEntry(
                id: cassetteMusicId,
                kind: .audio,
                displayName: "CassetteAI Music (fal)",
                allowedEndpoints: [cassetteMusicId],
                responseShape: .audio,
                uiCapabilities: .audio(cassetteMusicCaps),
                audioPricing: .perSecond(rate: 0)
            ),
            caps: cassetteMusicCaps
        )
    ]

    private static let cassetteMusicCaps = AudioCaps(
        category: "music",
        voices: nil,
        defaultVoice: nil,
        supportsLyrics: false,
        supportsInstrumental: true,
        supportsStyleInstructions: false,
        durations: nil,
        minPromptLength: 1,
        inputs: ["text"],
        promptLabel: "Describe the music",
        minSeconds: 10,
        maxSeconds: 180
    )

    /// Look up a fal-direct model config by id (audio only for now).
    static func model(id: String) -> AudioModelConfig? {
        audio.first { $0.id == id }
    }
}

// MARK: - CatalogEntry static constructor

extension CatalogEntry {
    /// Memberwise initializer for synthesizing static (non-Convex) catalog entries.
    /// The default `init(from:)` only decodes; BYOK models are built in code.
    init(
        id: String,
        kind: Kind,
        displayName: String,
        allowedEndpoints: [String],
        responseShape: ResponseShape,
        uiCapabilities: UICapabilities,
        creditsPerSecond: [String: Double]? = nil,
        audioDiscountRate: [String: Double]? = nil,
        creditsPerImage: [String: Double]? = nil,
        qualities: [String]? = nil,
        audioPricing: AudioPricing? = nil,
        creditsPerSecondUpscale: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.allowedEndpoints = allowedEndpoints
        self.responseShape = responseShape
        self.uiCapabilities = uiCapabilities
        self.creditsPerSecond = creditsPerSecond
        self.audioDiscountRate = audioDiscountRate
        self.creditsPerImage = creditsPerImage
        self.qualities = qualities
        self.audioPricing = audioPricing
        self.creditsPerSecondUpscale = creditsPerSecondUpscale
    }
}
