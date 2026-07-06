import Foundation

/// Lock-guarded LRU cache of baked correction cubes and skin-protected look cubes, shared by
/// the instruction builder (static grades, baked once) and the compositor's render threads
/// (keyframed grades, fetched per frame). Keys quantize every channel to 1e−3 so scrubbing
/// back over the same keyframed segment re-hits instead of re-baking (~1–3 ms per miss).
///
/// Bounded: 33³ RGBA Float32 ≈ 575 KB per cube; 16 entries ≈ 9 MB worst case.
final class GradeCubeCache: @unchecked Sendable {
    static let shared = GradeCubeCache()

    private let lock = NSLock()
    private var cubes: [GradeCubeKey: LUTCube] = [:]
    private var order: [GradeCubeKey] = []          // LRU order, most recent last
    private var skinCubes: [SkinCubeKey: LUTCube] = [:]
    private var skinOrder: [SkinCubeKey] = []
    private let capacity = 16

    private init() {}

    /// The baked correction cube for a grade's cube-rendered channels (hsl/curves/wheels/tonal).
    func correctionCube(for grade: ColorGrade) -> LUTCube {
        let key = GradeCubeKey(grade)
        lock.lock()
        if let hit = cubes[key] {
            touch(key)
            lock.unlock()
            return hit
        }
        lock.unlock()

        let cube = GradeMath.correctionCube(for: grade)

        lock.lock()
        defer { lock.unlock() }
        if cubes[key] == nil {
            cubes[key] = cube
            order.append(key)
            if order.count > capacity {
                cubes.removeValue(forKey: order.removeFirst())
            }
        }
        return cube
    }

    /// A skin-protected variant of a resolved look cube, keyed by look id + protect amount.
    func skinProtectedCube(lutId: String, base: LUTCube, protect: Double) -> LUTCube {
        let p = min(1, max(0, protect))
        guard p > 0 else { return base }
        let key = SkinCubeKey(lutId: lutId, protect: Int((p * 1000).rounded()))
        lock.lock()
        if let hit = skinCubes[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let cube = GradeMath.skinProtected(base, protect: p)

        lock.lock()
        defer { lock.unlock() }
        if skinCubes[key] == nil {
            skinCubes[key] = cube
            skinOrder.append(key)
            if skinOrder.count > capacity {
                skinCubes.removeValue(forKey: skinOrder.removeFirst())
            }
        }
        return cube
    }

    private func touch(_ key: GradeCubeKey) {
        if let i = order.firstIndex(of: key) {
            order.remove(at: i)
            order.append(key)
        }
    }
}

/// Identity of a correction cube: every cube-rendered channel quantized to 1e−3.
/// Channels rendered by native CIFilters (exposure, contrast, …) are deliberately excluded —
/// they don't affect the bake.
struct GradeCubeKey: Hashable {
    private let quantized: [Int]

    init(_ g: ColorGrade) {
        var v: [Double] = [g.highlights, g.shadows, g.fade]
        v.append(contentsOf: g.hsl.hueShift)
        v.append(contentsOf: g.hsl.saturation)
        v.append(contentsOf: g.hsl.luminance)
        for w in [g.wheels.lift, g.wheels.gamma, g.wheels.gain, g.wheels.offset] {
            v.append(contentsOf: [w.r, w.g, w.b, w.luma])
        }
        for ch in [g.curves.rgb, g.curves.red, g.curves.green, g.curves.blue] {
            v.append(Double(ch.count))
            for p in ch { v.append(p.x); v.append(p.y) }
        }
        self.quantized = v.map { Int(($0 * 1000).rounded()) }
    }
}

private struct SkinCubeKey: Hashable {
    let lutId: String
    let protect: Int
}
