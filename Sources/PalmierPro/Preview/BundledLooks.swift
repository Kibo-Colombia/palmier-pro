import Foundation

/// The curated one-tap "looks" pack, synthesized in code as 3D LUTs (no bundled files, no
/// redistribution licensing). Each look is a pure `(r,g,b) -> (r,g,b)` transfer function over
/// the unit cube; `cube(for:)` samples it onto a `dimension³` grid and packs it for CIColorCube.
/// User-imported `.cube` files (see LUTStore) join the same id namespace.
enum BundledLooks {
    struct Look: Sendable {
        let id: String
        let name: String
        let detail: String
        let transform: @Sendable (Float, Float, Float) -> (Float, Float, Float)
    }

    /// Display order is the pack order shown in the inspector strip.
    static let all: [Look] = [
        Look(id: "cinematic", name: "Cinematic", detail: "Gentle contrast, cool shadows, slight desaturation") { r, g, b in
            var (r, g, b) = (scurve(r, 0.32), scurve(g, 0.32), scurve(b, 0.32))
            let y = luma(r, g, b)
            (r, g, b) = desaturate(r, g, b, toward: y, amount: 0.14)
            let sh = (1 - y) * (1 - y)
            return (r - 0.035 * sh, g + 0.005 * sh, b + 0.05 * sh)
        },
        Look(id: "warm", name: "Warm", detail: "Warm midtones, orange highlights") { r, g, b in
            let y = luma(r, g, b)
            let hi = y * y
            return (r + 0.05 + 0.06 * hi, g + 0.015 * hi, b - 0.05 - 0.04 * hi)
        },
        Look(id: "teal-orange", name: "Teal · Orange", detail: "Teal shadows, orange highlights — the blockbuster split-tone") { r, g, b in
            let y = luma(r, g, b)
            let sh = 1 - y, hi = y
            var nr = r - 0.07 * sh + 0.11 * hi
            var ng = g + 0.05 * sh + 0.03 * hi
            var nb = b + 0.11 * sh - 0.09 * hi
            let ny = luma(nr, ng, nb)            // light saturation boost for punch
            (nr, ng, nb) = desaturate(nr, ng, nb, toward: ny, amount: -0.12)
            return (nr, ng, nb)
        },
        Look(id: "film", name: "Film", detail: "Filmic toe + shoulder, lifted blacks, soft desaturation") { r, g, b in
            var (r, g, b) = (filmic(r), filmic(g), filmic(b))
            let y = luma(r, g, b)
            (r, g, b) = desaturate(r, g, b, toward: y, amount: 0.1)
            return (r + 0.012, g + 0.006, b - 0.004)  // faint warm bias
        },
        Look(id: "moody", name: "Moody", detail: "Crushed blacks, pulled highlights, green-tinted shadows") { r, g, b in
            let crush: (Float) -> Float = { max(0, ($0 - 0.06) / 0.94) }
            var (r, g, b) = (crush(r), crush(g), crush(b))
            let y = luma(r, g, b)
            let hi = y * y
            (r, g, b) = (r * (1 - 0.1 * hi), g * (1 - 0.08 * hi), b * (1 - 0.1 * hi))
            let sh = (1 - y) * (1 - y)
            (r, g, b) = desaturate(r, g, b, toward: y, amount: 0.18)
            return (r, g + 0.04 * sh, b + 0.01 * sh)
        },
        Look(id: "bw", name: "B&W", detail: "Rec. 709 luma, mild contrast") { r, g, b in
            let y = scurve(luma(r, g, b), 0.25)
            return (y, y, y)
        },
    ]

    static func look(_ id: String) -> Look? { all.first { $0.id == id } }
    static var ids: [String] { all.map(\.id) }

    /// Sample a look onto a `dimension³` cube in CIColorCube order (blue outer → red inner, red fastest).
    static func cube(for id: String, dimension n: Int = 17) -> LUTCube? {
        guard let look = look(id) else { return nil }
        var values = [Float](repeating: 0, count: n * n * n * 4)
        let denom = Float(n - 1)
        var k = 0
        for bi in 0..<n {
            let b = Float(bi) / denom
            for gi in 0..<n {
                let g = Float(gi) / denom
                for ri in 0..<n {
                    let (or, og, ob) = look.transform(Float(ri) / denom, g, b)
                    values[k] = clamp01(or); values[k + 1] = clamp01(og)
                    values[k + 2] = clamp01(ob); values[k + 3] = 1
                    k += 4
                }
            }
        }
        return LUTCube(dimension: n, data: values.withUnsafeBytes { Data($0) })
    }
}

// MARK: - Look math (pure, Rec.709)

private func luma(_ r: Float, _ g: Float, _ b: Float) -> Float { 0.2126 * r + 0.7152 * g + 0.0722 * b }
private func clamp01(_ x: Float) -> Float { min(1, max(0, x)) }

/// Adjustable S-curve contrast: blends linear toward a smoothstep by `amount` (0 = none, 1 = full).
private func scurve(_ x: Float, _ amount: Float) -> Float {
    let c = clamp01(x)
    let s = c * c * (3 - 2 * c)
    return c + (s - c) * amount
}

/// Filmic-ish curve: lifts the toe (blacks) and rolls off the shoulder (highlights).
private func filmic(_ x: Float) -> Float {
    let c = clamp01(x)
    return 0.035 + 0.93 * (c * (1 + 0.18 * (1 - c)))  // gentle toe lift + soft shoulder
}

/// Mix toward a luma value. Negative `amount` increases saturation (mixes away from luma).
private func desaturate(_ r: Float, _ g: Float, _ b: Float, toward y: Float, amount: Float) -> (Float, Float, Float) {
    (r + (y - r) * amount, g + (y - g) * amount, b + (y - b) * amount)
}
