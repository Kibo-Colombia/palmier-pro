enum ClipType: String, Codable, Sendable, CaseIterable {
    case video
    case audio
    case image
    case text
    case lottie
    case adjustment

    var sfSymbolName: String {
        switch self {
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        case .text: "textformat"
        case .lottie: "sparkles"
        case .adjustment: "camera.filters"
        }
    }

    var trackLabel: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Image"
        case .text: "Text"
        case .lottie: "Lottie"
        case .adjustment: "Adjust"
        }
    }

    var trackLabelPrefix: String { String(trackLabel.prefix(1)) }

    var isVisual: Bool {
        self == .video || self == .image || self == .text || self == .lottie || self == .adjustment
    }

    /// Whether clips of this type occupy an AVComposition track. Text renders via the
    /// Core Animation tool and adjustment layers are applied by the GradeCompositor to the
    /// composited stack — neither has source media to load.
    var buildsCompositionTrack: Bool {
        self != .text && self != .adjustment
    }

    func isCompatible(with other: ClipType) -> Bool {
        self == other || (self.isVisual && other.isVisual)
    }

    init?(fileExtension ext: String) {
        switch ext {
        case "mov", "mp4", "m4v": self = .video
        case "mp3", "wav", "aac", "m4a": self = .audio
        case "png", "jpg", "jpeg", "tiff", "heic": self = .image
        case "json", "lottie": self = .lottie
        default: return nil
        }
    }
}
