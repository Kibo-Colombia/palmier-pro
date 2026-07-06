import Foundation

/// Shape of a color-grade mask. `.none` = the grade applies everywhere (no mask cost).
enum MaskShape: String, Codable, Sendable, CaseIterable {
    case none, linear, mirror, radial, rectangle

    var displayName: String {
        switch self {
        case .none: "None"
        case .linear: "Linear"
        case .mirror: "Mirror"
        case .radial: "Circle"
        case .rectangle: "Rectangle"
        }
    }

    var sfSymbolName: String {
        switch self {
        case .none: "slash.circle"
        case .linear: "square.lefthalf.filled"
        case .mirror: "rectangle.split.3x1"
        case .radial: "circle.circle"
        case .rectangle: "rectangle"
        }
    }
}

/// A spatial mask limiting WHERE a clip's color grade applies (CapCut-style Adjust mask).
/// White = graded, black = original; `invert` flips that.
///
/// Coordinates are normalized to the clip's DISPLAY space (0…1 across the visible oriented
/// media, y-down like the crop model) so the mask travels with the clip. On adjustment
/// layers they are canvas space. Rendered by `MaskRenderer` + `CIBlendWithMask` in the
/// GradeCompositor.
struct AdjustMask: Codable, Sendable, Equatable {
    var shape: MaskShape = .none
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    /// Radial: horizontal/vertical radii. Rectangle: full extents. Linear/mirror: `height`
    /// is the band height (mirror) — `width` unused.
    var width: Double = 0.5
    var height: Double = 0.5
    var rotation: Double = 0     // degrees, positive = clockwise (same convention as Transform)
    var feather: Double = 0.1    // 0…1 soft-edge fraction
    var invert: Bool = false

    init(shape: MaskShape = .none, centerX: Double = 0.5, centerY: Double = 0.5,
         width: Double = 0.5, height: Double = 0.5, rotation: Double = 0,
         feather: Double = 0.1, invert: Bool = false) {
        self.shape = shape
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
        self.rotation = rotation
        self.feather = feather
        self.invert = invert
    }

    var isIdentity: Bool { shape == .none }

    private enum CodingKeys: String, CodingKey {
        case shape, centerX, centerY, width, height, rotation, feather, invert
    }

    // Tolerant decode, like ColorGrade: unknown/missing fields fall back to defaults so
    // projects from other versions load clean.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.shape   = (try? c.decode(MaskShape.self, forKey: .shape)) ?? .none
        self.centerX = (try? c.decode(Double.self, forKey: .centerX)) ?? 0.5
        self.centerY = (try? c.decode(Double.self, forKey: .centerY)) ?? 0.5
        self.width   = (try? c.decode(Double.self, forKey: .width)) ?? 0.5
        self.height  = (try? c.decode(Double.self, forKey: .height)) ?? 0.5
        self.rotation = (try? c.decode(Double.self, forKey: .rotation)) ?? 0
        self.feather = (try? c.decode(Double.self, forKey: .feather)) ?? 0.1
        self.invert  = (try? c.decode(Bool.self, forKey: .invert)) ?? false
    }
}

extension AdjustMask: KeyframeInterpolatable {
    /// Scalars lerp; shape and invert hold (they can't cross-fade).
    static func keyframeInterpolate(_ a: AdjustMask, _ b: AdjustMask, t: Double) -> AdjustMask {
        AdjustMask(
            shape: a.shape,
            centerX: Double.keyframeInterpolate(a.centerX, b.centerX, t: t),
            centerY: Double.keyframeInterpolate(a.centerY, b.centerY, t: t),
            width: Double.keyframeInterpolate(a.width, b.width, t: t),
            height: Double.keyframeInterpolate(a.height, b.height, t: t),
            rotation: Double.keyframeInterpolate(a.rotation, b.rotation, t: t),
            feather: Double.keyframeInterpolate(a.feather, b.feather, t: t),
            invert: a.invert
        )
    }
}
