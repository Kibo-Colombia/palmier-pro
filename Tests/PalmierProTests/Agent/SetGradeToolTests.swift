import Foundation
import Testing
@testable import PalmierPro

/// Coverage for the extended set_grade surface: the CapCut-parity scalars, clamping,
/// and the structured hsl parameter. (The legacy 7 channels are covered by older suites.)
@Suite("set_grade — extended channels")
@MainActor
struct SetGradeToolTests {

    private func harness() -> (ToolHarness, String) {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))
        return (h, "c1")
    }

    private func grade(_ h: ToolHarness, _ id: String) -> ColorGrade {
        h.editor.clipFor(id: id)!.grade
    }

    @Test func newScalarsApplyAndClamp() async throws {
        let (h, id) = harness()
        let result = await h.runRaw("set_grade", args: [
            "clipIds": [id],
            "hue": 200.0,          // clamps to 180
            "highlights": -0.5,
            "shadows": 0.25,
            "fade": 0.3,
            "sharpen": 5.0,        // clamps to 1
            "clarity": 0.4,
            "vignette": 0.6,
            "lookIntensity": 0.7,
            "protectSkinTone": true,
        ])
        #expect(!result.isError, Comment(rawValue: ToolHarness.textOf(result)))
        let g = grade(h, id)
        #expect(g.hue == 180)
        #expect(g.highlights == -0.5)
        #expect(g.shadows == 0.25)
        #expect(g.fade == 0.3)
        #expect(g.sharpen == 1)
        #expect(g.clarity == 0.4)
        #expect(g.vignette == 0.6)
        #expect(g.lookIntensity == 0.7)
        #expect(g.protectSkinTone == 1)
        #expect(!g.isIdentity)
        #expect(g.needsCorrectionCube)   // highlights/shadows/fade route through the cube
    }

    @Test func hslBandsPartialMerge() async throws {
        let (h, id) = harness()
        var r = await h.runRaw("set_grade", args: [
            "clipIds": [id],
            "hsl": ["orange": ["saturation": -0.3], "blue": ["hue": 0.5, "luminance": -0.2]],
        ])
        #expect(!r.isError, Comment(rawValue: ToolHarness.textOf(r)))
        var g = grade(h, id)
        #expect(g.hsl.saturation[1] == -0.3)   // orange = band 1
        #expect(g.hsl.hueShift[5] == 0.5)      // blue = band 5
        #expect(g.hsl.luminance[5] == -0.2)
        #expect(g.hsl.hueShift[0] == 0)        // untouched bands stay neutral

        // Second call touches a different band — earlier bands persist (partial merge).
        r = await h.runRaw("set_grade", args: [
            "clipIds": [id],
            "hsl": ["red": ["hue": 2.0]],      // clamps to 1
        ])
        #expect(!r.isError)
        g = grade(h, id)
        #expect(g.hsl.hueShift[0] == 1)
        #expect(g.hsl.saturation[1] == -0.3)   // still there

        // reset inside hsl clears all bands, then applies the rest of the call.
        r = await h.runRaw("set_grade", args: [
            "clipIds": [id],
            "hsl": ["reset": true, "green": ["luminance": 0.4]],
        ])
        #expect(!r.isError)
        g = grade(h, id)
        #expect(g.hsl.hueShift[0] == 0)
        #expect(g.hsl.saturation[1] == 0)
        #expect(g.hsl.luminance[3] == 0.4)     // green = band 3
    }

    @Test func curvesApplySortAndReset() async throws {
        let (h, id) = harness()
        var r = await h.runRaw("set_grade", args: [
            "clipIds": [id],
            // Deliberately unsorted; also touches red.
            "curves": ["rgb": [[0.75, 0.8], [0.0, 0.0], [0.25, 0.2], [1.0, 1.0]],
                       "red": [[0.0, 0.1], [1.0, 0.9]]],
        ])
        #expect(!r.isError, Comment(rawValue: ToolHarness.textOf(r)))
        var g = grade(h, id)
        #expect(g.curves.rgb.count == 4)
        #expect(g.curves.rgb.map(\.x) == g.curves.rgb.map(\.x).sorted())   // sorted by x
        #expect(g.curves.red.first?.y == 0.1)
        #expect(!g.curves.isIdentity)
        #expect(g.needsCorrectionCube)

        // Empty array resets one channel; the other channel persists.
        r = await h.runRaw("set_grade", args: ["clipIds": [id], "curves": ["rgb": [Any]()]])
        #expect(!r.isError)
        g = grade(h, id)
        #expect(g.curves.rgb.isEmpty)
        #expect(g.curves.red.count == 2)
    }

    @Test func malformedCurvesRejectedBeforeMutation() async {
        let (h, id) = harness()
        // Single point is invalid — and the valid fade in the same call must NOT apply.
        let r = await h.runRaw("set_grade", args: [
            "clipIds": [id], "fade": 0.9,
            "curves": ["rgb": [[0.5, 0.5]]],
        ])
        #expect(r.isError)
        #expect(grade(h, id).fade == 0)

        let r2 = await h.runRaw("set_grade", args: [
            "clipIds": [id],
            "curves": ["cyan": [[0.0, 0.0], [1.0, 1.0]]],   // not a curve channel
        ])
        #expect(r2.isError)
    }

    @Test func wheelsPartialMergeAndClamp() async throws {
        let (h, id) = harness()
        var r = await h.runRaw("set_grade", args: [
            "clipIds": [id],
            "wheels": ["lift": ["b": 0.15, "luma": -2.0],     // luma clamps to −1
                       "gain": ["r": 0.12]],
        ])
        #expect(!r.isError, Comment(rawValue: ToolHarness.textOf(r)))
        var g = grade(h, id)
        #expect(g.wheels.lift.b == 0.15)
        #expect(g.wheels.lift.luma == -1)
        #expect(g.wheels.gain.r == 0.12)
        #expect(g.wheels.gamma.isIdentity)     // untouched wheel
        #expect(g.needsCorrectionCube)

        // Partial merge: touching gamma keeps lift/gain; reset clears all first.
        r = await h.runRaw("set_grade", args: [
            "clipIds": [id], "wheels": ["gamma": ["luma": 0.3]],
        ])
        #expect(!r.isError)
        g = grade(h, id)
        #expect(g.wheels.lift.b == 0.15 && g.wheels.gamma.luma == 0.3)

        r = await h.runRaw("set_grade", args: [
            "clipIds": [id], "wheels": ["reset": true, "offset": ["g": 0.1]],
        ])
        #expect(!r.isError)
        g = grade(h, id)
        #expect(g.wheels.lift.isIdentity && g.wheels.gamma.isIdentity)
        #expect(g.wheels.offset.g == 0.1)

        let bad = await h.runRaw("set_grade", args: [
            "clipIds": [id], "wheels": ["shadow": ["r": 1]],   // not a wheel name
        ])
        #expect(bad.isError)
    }

    @Test func resetClearsExtendedChannels() async throws {
        let (h, id) = harness()
        _ = await h.runRaw("set_grade", args: [
            "clipIds": [id], "fade": 0.5, "vignette": 0.8,
            "hsl": ["cyan": ["saturation": 0.9]],
        ])
        let r = await h.runRaw("set_grade", args: ["clipIds": [id], "reset": true])
        #expect(!r.isError)
        let g = grade(h, id)
        #expect(g == ColorGrade())
    }

    @Test func unknownHSLBandRejected() async {
        let (h, id) = harness()
        let r = await h.runRaw("set_grade", args: [
            "clipIds": [id],
            "hsl": ["chartreuse": ["saturation": 1]],
        ])
        #expect(r.isError)
    }

    @Test func gradeKeyframesMergeOverStaticGrade() async throws {
        let (h, id) = harness()
        // Static grade carries a lut-less warm base the keyframes should inherit.
        _ = await h.runRaw("set_grade", args: ["clipIds": [id], "temperature": 30.0])

        let r = await h.runRaw("set_keyframes", args: [
            "clipId": id,
            "property": "grade",
            "keyframes": [
                [0, [String: Any]()],
                [12, ["exposure": 1.5, "wheels": ["gain": ["r": 0.2]]], "linear"],
                [24, [String: Any]()],
            ],
        ])
        #expect(!r.isError, Comment(rawValue: ToolHarness.textOf(r)))

        let clip = h.editor.clipFor(id: id)!
        let track = try #require(clip.gradeTrack)
        #expect(track.keyframes.count == 3)
        #expect(track.keyframes.map(\.frame) == [0, 12, 24])
        // Every keyframe keeps the static temperature; the middle one adds exposure + gain.
        #expect(track.keyframes.allSatisfy { $0.value.temperature == 30 })
        #expect(track.keyframes[1].value.exposure == 1.5)
        #expect(track.keyframes[1].value.wheels.gain.r == 0.2)
        #expect(track.keyframes[1].interpolationOut == .linear)
        #expect(track.keyframes[0].value.exposure == 0)

        // Sampling mid-way (frame 6, between identity and exposure 1.5, smooth default).
        let sampled = clip.gradeAt(frame: clip.startFrame + 6)
        #expect(sampled.exposure > 0 && sampled.exposure < 1.5)

        // Clearing works.
        let clear = await h.runRaw("set_keyframes", args: [
            "clipId": id, "property": "grade", "keyframes": [Any](),
        ])
        #expect(!clear.isError)
        #expect(h.editor.clipFor(id: id)?.gradeTrack == nil)
    }

    @Test func gradeKeyframesRejectBadRows() async {
        let (h, id) = harness()
        // Positional numbers instead of an object.
        let r = await h.runRaw("set_keyframes", args: [
            "clipId": id, "property": "grade",
            "keyframes": [[0, 1.5]],
        ])
        #expect(r.isError)
        // Unknown channel inside the object.
        let r2 = await h.runRaw("set_keyframes", args: [
            "clipId": id, "property": "grade",
            "keyframes": [[0, ["exposre": 1]]],
        ])
        #expect(r2.isError)
    }

    @Test func audioClipRejected() async {
        let clip = Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 60)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])]))
        let r = await h.runRaw("set_grade", args: ["clipIds": ["a1"], "fade": 0.5])
        #expect(r.isError)
    }
}
