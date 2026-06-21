import Testing
import Foundation
@testable import PalmierPro

/// Unit tests for the LUT layer: the .cube parser memory layout, synthesized looks, and the
/// ColorGrade LUT fields. Pure (no AVFoundation render) so they stay fast.
@Suite("LUT")
struct LUTTests {

    private func floats(_ cube: LUTCube) -> [Float] {
        cube.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    @Test("parser round-trips an identity 2³ cube in red-fastest RGBA order")
    func parsesIdentityCube() throws {
        // R-fastest order: r inner, g middle, b outer.
        let text = """
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
        let cube = try #require(CubeLUTParser.parse(text: text))
        #expect(cube.dimension == 2)
        let f = floats(cube)
        #expect(f.count == 2 * 2 * 2 * 4)
        // entry 1 = (r=1,g=0,b=0); entry 4 = (r=0,g=0,b=1); alpha always 1.
        #expect(f[4] == 1 && f[5] == 0 && f[6] == 0 && f[7] == 1)
        #expect(f[16] == 0 && f[17] == 0 && f[18] == 1 && f[19] == 1)
    }

    @Test("parser ignores comments/title and rejects malformed or 1D LUTs")
    func parserRejectsBadInput() {
        #expect(CubeLUTParser.parse(text: "# just a comment\nTITLE \"x\"") == nil)        // no data
        #expect(CubeLUTParser.parse(text: "LUT_3D_SIZE 2\n0 0 0\n1 0 0") == nil)          // wrong count
        #expect(CubeLUTParser.parse(text: "LUT_1D_SIZE 2\n0 0 0\n1 1 1") == nil)          // 1D unsupported
    }

    @Test("every bundled look produces a valid, in-range cube")
    func bundledLooksAreValid() throws {
        #expect(BundledLooks.ids == ["cinematic", "warm", "teal-orange", "film", "moody", "bw"])
        for id in BundledLooks.ids {
            let cube = try #require(BundledLooks.cube(for: id), "missing look \(id)")
            #expect(cube.dimension == 17)
            let f = floats(cube)
            #expect(f.count == 17 * 17 * 17 * 4)
            #expect(f.allSatisfy { $0 >= 0 && $0 <= 1 })
            // every 4th value is alpha = 1
            #expect(stride(from: 3, to: f.count, by: 4).allSatisfy { f[$0] == 1 })
        }
    }

    @Test("B&W look collapses color to equal RGB (true desaturation)")
    func bwLookDesaturates() throws {
        let look = try #require(BundledLooks.look("bw"))
        let (r, g, b) = look.transform(0.8, 0.2, 0.1)
        #expect(abs(r - g) < 0.001 && abs(g - b) < 0.001)
    }

    @Test("ColorGrade LUT fields round-trip and gate isIdentity")
    func gradeLUTCodableAndIdentity() throws {
        #expect(ColorGrade().isIdentity)                                  // neutral
        #expect(!ColorGrade(lut: "warm").isIdentity)                      // a look is never identity
        let g = ColorGrade(lut: "teal-orange", lookIntensity: 0.6, exposure: 0.3)
        let decoded = try JSONDecoder().decode(ColorGrade.self, from: JSONEncoder().encode(g))
        #expect(decoded == g)
        // older project with no lut/lookIntensity keys decodes to neutral look fields
        let legacy = try JSONDecoder().decode(ColorGrade.self, from: Data(#"{"exposure":0.5}"#.utf8))
        #expect(legacy.lut == nil && legacy.lookIntensity == 1 && legacy.exposure == 0.5)
    }
}
