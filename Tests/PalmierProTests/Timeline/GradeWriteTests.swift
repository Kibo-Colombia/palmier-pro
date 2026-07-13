import Foundation
import Testing
@testable import PalmierPro

/// The animation-aware grade writes behind the inspector's Color tab
/// (`applyGrade` / `commitGrade`). Two invariants:
///   1. A channel edit MERGES into the clip's existing grade — it must never
///      publish a default-initialized grade with only the touched knob changed.
///   2. When a `gradeTrack` is active (agent keyframes, transition flashes), the
///      edit lands in the keyframe at the playhead — writing the shadowed static
///      grade would be a dead write that never renders.
@MainActor
private func editor(_ tracks: [Track]) -> EditorViewModel {
    let e = EditorViewModel()
    e.timeline = Fixtures.timeline(tracks: tracks)
    return e
}

@Suite("EditorViewModel — animation-aware grade writes")
@MainActor
struct GradeWriteTests {

    @Test func staticGradeEditMergesWithExistingChannels() {
        // The Bug-1 class: an agent-set grade must survive a slider touching ONE channel.
        var clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        clip.grade.temperature = 40
        clip.grade.contrast = 1.3
        clip.grade.lut = "moody"
        let e = editor([Fixtures.videoTrack(clips: [clip])])

        e.commitGrade(clipId: "c1") { $0.exposure = 0.5 }

        let g = e.timeline.tracks[0].clips[0].grade
        #expect(g.exposure == 0.5)
        #expect(g.temperature == 40)   // untouched channels survive
        #expect(g.contrast == 1.3)
        #expect(g.lut == "moody")
    }

    @Test func keyframedGradeEditLandsInKeyframeAtPlayhead() {
        // With an active gradeTrack the static grade never renders — the edit must
        // merge into the effective (sampled) grade and stamp back as a keyframe.
        var clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        var kf = ColorGrade()
        kf.temperature = 40
        clip.upsertKeyframe(in: \.gradeTrack, frame: 0, value: kf)
        clip.upsertKeyframe(in: \.gradeTrack, frame: 59, value: kf)
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        e.currentFrame = 30

        e.commitGrade(clipId: "c1") { $0.exposure = 0.5 }

        let updated = e.timeline.tracks[0].clips[0]
        // Static grade stays neutral — the write went where the render reads.
        #expect(updated.grade.exposure == 0)
        let effective = updated.gradeAt(frame: 30)
        #expect(effective.exposure == 0.5)
        #expect(effective.temperature == 40)   // merged over the sampled grade
        #expect(updated.gradeTrack?.keyframes.count == 3)   // new keyframe at the playhead
    }

    @Test func keyframedGradeEditClampsPlayheadOutsideClip() {
        // Playhead parked after the clip: the keyframe must land inside [start, end).
        var clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        clip.upsertKeyframe(in: \.gradeTrack, frame: 0, value: ColorGrade())
        let e = editor([Fixtures.videoTrack(clips: [clip])])
        e.currentFrame = 500

        e.commitGrade(clipId: "c1") { $0.exposure = 1 }

        let updated = e.timeline.tracks[0].clips[0]
        let frames = updated.keyframeFrames(for: .grade)
        #expect(frames.allSatisfy { $0 >= 0 && $0 < 60 })
        #expect(updated.gradeAt(frame: 59).exposure == 1)
    }

    @Test func applyThenCommitIsOneCoherentEdit() {
        // Live drag then release — mirrors GradeSliderRow's onChanged → onCommit flow.
        var clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        clip.grade.saturation = 1.2
        let e = editor([Fixtures.videoTrack(clips: [clip])])

        e.applyGrade(clipId: "c1") { $0.exposure = 0.2 }
        e.applyGrade(clipId: "c1") { $0.exposure = 0.4 }
        e.commitGrade(clipId: "c1") { $0.exposure = 0.4 }

        let g = e.timeline.tracks[0].clips[0].grade
        #expect(g.exposure == 0.4)
        #expect(g.saturation == 1.2)
    }
}
