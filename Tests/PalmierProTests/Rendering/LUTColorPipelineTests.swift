import Testing
import AVFoundation
import CoreImage
import CoreVideo
@testable import PalmierPro

/// Regression guard for the LUT color pipeline's core invariant: an imported (`videoSource`)
/// cube is a pure *code value → code value* map — what Resolve/FCP do when they apply a .cube.
///
/// The 2026-07 defect: sampling imported LUTs in sRGB while BT.709 buffers decode through the
/// ~1.961-gamma "HDTV" profile inserted a transfer-function sandwich (709⁻¹ → sRGB) around the
/// cube, lifting mids by ≈ +9/255 vs DaVinci Resolve's render of identical footage + LUT
/// (measured in spikes/ColorPipelineSpike.swift). Sampling in the frame's own color space makes
/// CI's encode the exact inverse of its decode, so the cube sees the file's real code values.
@Suite("LUTColorPipeline")
struct LUTColorPipelineTests {

    /// dimension³ cube of v → 0.08 + 0.84·v per channel (lift + gain). Affine maps do NOT
    /// commute with gamma curves (power-law maps nearly do), so any transfer sandwich around
    /// the lookup shows up as a several-/255 shift across the ramp — and the map is exactly
    /// representable by trilinear interpolation, so the expected values are exact.
    private func liftGainCube(dimension n: Int, sampling: LUTCube.Sampling) -> LUTCube {
        var values = [Float](repeating: 0, count: n * n * n * 4)
        let denom = Float(n - 1)
        var k = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let r = Float(ri) / denom, g = Float(gi) / denom, b = Float(bi) / denom
                    values[k] = 0.08 + 0.84 * r
                    values[k + 1] = 0.08 + 0.84 * g
                    values[k + 2] = 0.08 + 0.84 * b
                    values[k + 3] = 1
                    k += 4
                }
            }
        }
        return LUTCube(dimension: n, data: values.withUnsafeBytes { Data($0) }, sampling: sampling)
    }

    /// A BT.709-tagged BGRA buffer holding one gray ramp row — the same shape AVFoundation
    /// hands the GradeCompositor for decoded Rec.709 video.
    private func make709RampBuffer(width: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, 1, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
        let buf = try #require(pb)
        CVPixelBufferLockBaseAddress(buf, [])
        let base = try #require(CVPixelBufferGetBaseAddress(buf)).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
            let v = UInt8(min(255, x * 256 / width))
            let o = x * 4
            base[o] = v; base[o + 1] = v; base[o + 2] = v; base[o + 3] = 255
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buf, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return buf
    }

    /// Grade a 709 ramp with `cube` through the real applyGrade and return the worst
    /// per-channel deviation (in /255) from a pure CPU code-value cube lookup.
    private func worstCodeValueDeviation(cube: LUTCube) throws -> Int {
        let width = 256
        let buf = try make709RampBuffer(width: width)
        let img = CIImage(cvPixelBuffer: buf)
        let srcSpace = try #require(img.colorSpace)

        let graded = GradeCompositor.applyGrade(
            ColorGrade(lut: "test-liftgain"), cube: cube,
            sourceColorSpace: srcSpace, to: img)

        // Read back in the buffer's own space — the compositor's plain render(to:) writes the
        // 709-tagged destination the same way (verified empirically in the spike).
        let context = CIContext(options: [.cacheIntermediates: false])
        var out = [UInt8](repeating: 0, count: width * 4)
        context.render(graded, toBitmap: &out, rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: 1),
                       format: .BGRA8, colorSpace: srcSpace)

        var worst = 0
        for x in 0..<width {
            let v = Float(min(255, x * 256 / width)) / 255
            let expected = GradeMath.sampleCube(cube, at: SIMD3(v, v, v))
            for (c, e) in [(out[x * 4 + 2], expected.x), (out[x * 4 + 1], expected.y), (out[x * 4], expected.z)] {
                worst = max(worst, abs(Int(c) - Int((e * 255).rounded())))
            }
        }
        return worst
    }

    @Test("videoSource cube on a 709 buffer is a pure code-value map (matches CPU lookup)")
    func importedCubeIsCodeValuePassthrough() throws {
        // ±2/255 covers CI's cube interpolation + 8-bit rounding.
        let worst = try worstCodeValueDeviation(cube: liftGainCube(dimension: 17, sampling: .videoSource))
        #expect(worst <= 2, "worst code-value deviation \(worst)/255 — transfer sandwich is back?")

        // Self-check that the test can fail: the same data sampled in sRGB (the pre-fix
        // behavior for imported LUTs) must NOT be a code-value map on 709 footage.
        let sandwiched = try worstCodeValueDeviation(cube: liftGainCube(dimension: 17, sampling: .gammaSRGB))
        #expect(sandwiched > 2, "sRGB sampling unexpectedly matched code values (\(sandwiched)/255)")
    }

    @Test("cubeSpace picks the source space for videoSource and falls back to the 709 profile")
    func cubeSpaceSelection() throws {
        let videoCube = liftGainCube(dimension: 2, sampling: .videoSource)
        let srgbCube = liftGainCube(dimension: 2, sampling: .gammaSRGB)
        let some = CGColorSpace(name: CGColorSpace.displayP3)!
        #expect(GradeCompositor.cubeSpace(for: videoCube, sourceColorSpace: some) === some)
        #expect(GradeCompositor.cubeSpace(for: videoCube, sourceColorSpace: nil) === GradeCompositor.videoColorSpace)
        // Synthesized (bundled/correction) cubes keep their authored sRGB sampling regardless
        // of the frame's space — the fix must not change how bundled looks render.
        #expect(GradeCompositor.cubeSpace(for: srgbCube, sourceColorSpace: some) === GradeCompositor.lutColorSpace)
        // The fallback must be CoreVideo's BT.709 profile, not sRGB.
        #expect(GradeCompositor.videoColorSpace !== GradeCompositor.lutColorSpace)
    }
}
