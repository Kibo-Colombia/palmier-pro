import CoreImage
import Foundation

/// A 3D color LUT in the exact memory layout `CIColorCubeWithColorSpace` wants:
/// `dimension³` RGBA `Float32` entries, **red varying fastest** then green then blue —
/// `offset(r,g,b) = (b*n*n + g*n + r) * 4`, alpha = 1. Resolved cube data is carried on the
/// render model (see GradeCompositor) so the compositor never touches disk.
struct LUTCube: Sendable, Equatable {
    let dimension: Int
    let data: Data
}

/// Minimal Adobe/IRIDAS `.cube` text parser (no dependency). 3D LUTs only.
/// Fails closed (returns nil) on anything malformed — the render path then degrades to no-look.
enum CubeLUTParser {
    static func parse(contentsOf url: URL) -> LUTCube? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text: text)
    }

    static func parse(text: String) -> LUTCube? {
        var dimension = 0
        var values: [Float] = []
        values.reserveCapacity(4 * 4913)  // 17³ default guess

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let upper = line.uppercased()
            if upper.hasPrefix("TITLE") || upper.hasPrefix("DOMAIN_MIN") || upper.hasPrefix("DOMAIN_MAX") {
                continue  // metadata; we assume the standard 0…1 input domain
            }
            if upper.hasPrefix("LUT_3D_SIZE") {
                dimension = Int(line.split(separator: " ").last ?? "") ?? 0
                continue
            }
            if upper.hasPrefix("LUT_1D_SIZE") { return nil }  // 1D unsupported in v1

            // A data line: three floats. The .cube spec lists triplets red-fastest — the same
            // order CIColorCube wants — so each line maps straight to the next RGBA slot.
            let parts = line.split(separator: " ").compactMap { Float($0) }
            guard parts.count == 3 else { continue }
            values.append(contentsOf: [parts[0], parts[1], parts[2], 1])
        }

        guard dimension > 1, values.count == dimension * dimension * dimension * 4 else { return nil }
        return LUTCube(dimension: dimension, data: values.withUnsafeBytes { Data($0) })
    }
}
