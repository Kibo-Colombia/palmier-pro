import AppKit
import Testing
@testable import PalmierPro

@Suite("Transactional timeline edits")
@MainActor
struct TransactionalEditTests {
    private func harness() -> ToolHarness {
        ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(id: "picture", clips: [
                Fixtures.clip(id: "first", mediaType: .image, start: 0, duration: 60),
                Fixtures.clip(id: "second", mediaType: .image, start: 60, duration: 60),
            ]),
            Fixtures.audioTrack(id: "sound", clips: [
                Fixtures.clip(id: "foley", mediaType: .audio, start: 10, duration: 12),
            ]),
        ]))
    }

    private func request(_ h: ToolHarness, operationId: String = "test-edit", operations: [[String: Any]], dryRun: Bool = false, collisionPolicy: String = "reject") -> [String: Any] {
        ["expectedRevision": h.editor.editRevision, "operationId": operationId, "operations": operations, "dryRun": dryRun, "collisionPolicy": collisionPolicy]
    }

    private func receipt(_ result: ToolResult) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(ToolHarness.textOf(result).utf8)) as? [String: Any])
    }

    @Test func swappingTwoClipsPublishesOnceAndUndoRestoresEverything() throws {
        let h = harness()
        let undo = UndoManager()
        undo.groupsByEvent = false
        h.editor.undoManager = undo
        let before = h.editor.timeline
        let renderRevision = h.editor.timelineRenderRevision
        h.editor.notifyTimelineChangedDebounced()
        let result = try h.executor.applyEdit(h.editor, request(h, operations: [
            ["type": "move_clip", "clipId": "first", "startFrame": 60],
            ["type": "move_clip", "clipId": "second", "startFrame": 0],
            ["type": "set_track", "trackId": "sound", "muted": true],
        ]))
        #expect(result.isError == false)
        #expect(h.editor.timelineRenderRevision == renderRevision + 1)
        #expect(h.editor.pendingRebuildTask == nil)
        #expect(h.editor.clipFor(id: "first")?.startFrame == 60)
        #expect(h.editor.timeline.tracks[1].muted)
        #expect(undo.canUndo)
        undo.undo()
        #expect(h.editor.timeline == before)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(h.editor.clipFor(id: "first")?.startFrame == 60)
        #expect(h.editor.timeline.tracks[1].muted)
    }

    @Test func invalidFinalOperationLeavesNoPartialEditOrReceipt() throws {
        let h = harness()
        let before = h.editor.timeline
        let revision = h.editor.editRevision
        #expect(throws: ToolError.self) {
            try h.executor.applyEdit(h.editor, request(h, operations: [
                ["type": "set_clip", "clipId": "first", "opacity": 0.25],
                ["type": "set_track", "trackId": "missing", "muted": true],
            ]))
        }
        #expect(h.editor.timeline == before)
        #expect(h.editor.editRevision == revision)
        #expect(h.editor.editReceipts.isEmpty)
    }

    @Test func dryRunReportsExactRevisionWithoutMutating() throws {
        let h = harness()
        let before = h.editor.timeline
        let args = request(h, operations: [["type": "set_clip", "clipId": "first", "opacity": 0.5]], dryRun: true)
        let preview = try receipt(h.executor.applyEdit(h.editor, args))
        #expect(preview["dryRun"] as? Bool == true)
        #expect((preview["clipChanges"] as? [Any])?.count == 1)
        #expect(h.editor.timeline == before)
        #expect(h.editor.editReceipts.isEmpty)
        var apply = args
        apply["dryRun"] = false
        let actual = try receipt(h.executor.applyEdit(h.editor, apply))
        #expect(actual["revision"] as? String == preview["revision"] as? String)
        #expect(h.editor.editRevision == actual["revision"] as? String)
    }

    @Test func staleRevisionAfterHumanEditIsRejected() throws {
        let h = harness()
        let args = request(h, operations: [["type": "set_track", "trackId": "sound", "muted": true]])
        h.editor.timeline.tracks[0].clips[0].opacity = 0.8
        let afterHuman = h.editor.timeline
        #expect(throws: ToolError.self) { try h.executor.applyEdit(h.editor, args) }
        #expect(h.editor.timeline == afterHuman)
    }

    @Test func retryReturnsOriginalReceiptWithoutReapplyingAfterLaterEdit() throws {
        let h = harness()
        let args = request(h, operations: [["type": "set_clip", "clipId": "first", "opacity": 0.3]])
        let originalReceipt = try h.executor.applyEdit(h.editor, args)
        h.editor.timeline.tracks[0].clips[0].opacity = 0.9
        let afterHuman = h.editor.timeline
        let replay = try h.executor.applyEdit(h.editor, args)
        #expect(ToolHarness.textOf(replay) == ToolHarness.textOf(originalReceipt))
        #expect(h.editor.timeline == afterHuman)
    }

    @Test func operationIdCannotBeReusedForDifferentPayload() throws {
        let h = harness()
        _ = try h.executor.applyEdit(h.editor, request(h, operations: [["type": "set_clip", "clipId": "first", "opacity": 0.3]]))
        let before = h.editor.timeline
        #expect(throws: ToolError.self) {
            try h.executor.applyEdit(h.editor, request(h, operations: [["type": "set_clip", "clipId": "first", "opacity": 0.7]]))
        }
        #expect(h.editor.timeline == before)
    }

    @Test func projectGuardRejectsDifferentProject() throws {
        let h = harness()
        var args = request(h, operations: [["type": "set_track", "trackId": "sound", "muted": true]])
        args["projectId"] = UUID().uuidString
        let before = h.editor.timeline
        #expect(throws: ToolError.self) { try h.executor.applyEdit(h.editor, args) }
        #expect(h.editor.timeline == before)
    }

    @Test func stableTrackIdTargetsFlagsAfterStorageOrderChanges() throws {
        let h = harness()
        h.editor.timeline.tracks.insert(Fixtures.videoTrack(id: "new"), at: 0)
        _ = try h.executor.setTrackProperties(h.editor, ["expectedRevision": h.editor.editRevision, "operationId": "mute", "trackId": "sound", "muted": true, "hidden": true])
        #expect(h.editor.timeline.tracks.first { $0.id == "sound" }?.muted == true)
        #expect(h.editor.timeline.tracks.first { $0.id == "picture" }?.muted == false)
    }

    @Test func newPictureAndAudioCollisionsAreRejectedAtomically() throws {
        let h = harness()
        let before = h.editor.timeline
        #expect(throws: ToolError.self) {
            try h.executor.applyEdit(h.editor, request(h, operations: [["type": "move_clip", "clipId": "second", "startFrame": 30]]))
        }
        h.editor.timeline.tracks[1].clips.append(Fixtures.clip(id: "foley2", mediaType: .audio, start: 40, duration: 10))
        let beforeAudio = h.editor.timeline
        #expect(throws: ToolError.self) {
            try h.executor.applyEdit(h.editor, request(h, operations: [["type": "move_clip", "clipId": "foley2", "startFrame": 15]]))
        }
        #expect(before.tracks[0] == h.editor.timeline.tracks[0])
        #expect(beforeAudio == h.editor.timeline)
    }

    @Test func deliberateOverwriteTrimsVictimAndDryRunMatchesApply() throws {
        let h = harness()
        h.editor.timeline.tracks[0].clips = [
            Fixtures.clip(id: "victim", mediaType: .image, start: 0, duration: 200),
            Fixtures.clip(id: "incoming", mediaType: .image, start: 250, duration: 30),
        ]
        let args = request(h, operations: [["type": "move_clip", "clipId": "incoming", "startFrame": 60]], dryRun: true, collisionPolicy: "overwrite")
        let preview = try receipt(h.executor.applyEdit(h.editor, args))
        var apply = args
        apply["dryRun"] = false
        let result = try receipt(h.executor.applyEdit(h.editor, apply))
        #expect(preview["revision"] as? String == result["revision"] as? String)
        #expect(h.editor.timeline.tracks[0].clips.count == 3)
        #expect(h.editor.clipFor(id: "victim")?.durationFrames == 60)
        #expect(h.editor.timeline.tracks[0].clips.first { $0.startFrame == 90 }?.durationFrames == 110)
    }

    @Test func linkedTimingRequiresEveryPartnerExplicitly() throws {
        let h = harness()
        h.editor.timeline.tracks[0].clips[0].linkGroupId = "group"
        h.editor.timeline.tracks[1].clips[0].linkGroupId = "group"
        #expect(throws: ToolError.self) {
            try h.executor.applyEdit(h.editor, request(h, operations: [["type": "move_clip", "clipId": "first", "startFrame": 120]]))
        }
    }

    @Test func unknownNestedPropertiesAreRejectedBeforeMutation() throws {
        let h = harness()
        let before = h.editor.timeline
        #expect(throws: ToolError.self) {
            try h.executor.applyEdit(h.editor, request(h, operations: [["type": "set_clip", "clipId": "first", "volumee": 0.2]]))
        }
        #expect(h.editor.timeline == before)
    }

    @Test func beatResizeExtendsPictureAndTextKeepsSoundAndRipplesFollowers() throws {
        let h = harness()
        h.editor.timeline.tracks.insert(Fixtures.videoTrack(id: "words", clips: [Fixtures.clip(id: "caption", mediaType: .text, start: 0, duration: 60)]), at: 1)
        h.editor.timeline.tracks[2].clips.append(Fixtures.clip(id: "endSound", mediaType: .audio, start: 50, duration: 10))
        h.editor.timeline.tracks[2].clips.append(Fixtures.clip(id: "nextSound", mediaType: .audio, start: 80, duration: 12))
        _ = try h.executor.applyEdit(h.editor, request(h, operations: [[
            "type": "resize_beat", "startFrame": 0, "endFrame": 60, "durationFrames": 90,
            "clips": [
                ["clipId": "first", "role": "hold"], ["clipId": "caption", "role": "hold"],
                ["clipId": "foley", "role": "sound_start"], ["clipId": "endSound", "role": "sound_end"],
            ], "rippleTrackIds": ["picture", "words", "sound"],
        ]]))
        #expect(h.editor.clipFor(id: "first")?.durationFrames == 90)
        #expect(h.editor.clipFor(id: "caption")?.durationFrames == 90)
        #expect(h.editor.clipFor(id: "foley")?.durationFrames == 12)
        #expect(h.editor.clipFor(id: "foley")?.startFrame == 10)
        #expect(h.editor.clipFor(id: "endSound")?.startFrame == 80)
        #expect(h.editor.clipFor(id: "endSound")?.durationFrames == 10)
        #expect(h.editor.clipFor(id: "second")?.startFrame == 90)
        #expect(h.editor.clipFor(id: "nextSound")?.startFrame == 110)
    }

    @Test func beatResizeCanExtendSpanningCaptionWithoutStretchingFoley() throws {
        let h = harness()
        h.editor.timeline.tracks.insert(Fixtures.videoTrack(id: "words", clips: [Fixtures.clip(id: "persistent", mediaType: .text, start: 0, duration: 120)]), at: 1)
        _ = try h.executor.applyEdit(h.editor, request(h, operations: [[
            "type": "resize_beat", "startFrame": 0, "endFrame": 60, "durationFrames": 90,
            "clips": [["clipId": "first", "role": "hold"], ["clipId": "persistent", "role": "span"], ["clipId": "foley", "role": "sound_start"]],
            "rippleTrackIds": ["picture", "words", "sound"],
        ]]))
        #expect(h.editor.clipFor(id: "persistent")?.durationFrames == 150)
        #expect(h.editor.clipFor(id: "foley")?.durationFrames == 12)
    }

    @Test func shorterBeatRejectsSoundThatCannotFitAndAmbiguousMember() throws {
        let h = harness()
        let before = h.editor.timeline
        #expect(throws: ToolError.self) {
            try h.executor.applyEdit(h.editor, request(h, operations: [[
                "type": "resize_beat", "startFrame": 0, "endFrame": 60, "durationFrames": 15,
                "clips": [["clipId": "first", "role": "hold"], ["clipId": "foley", "role": "sound_start"]], "rippleTrackIds": ["picture", "sound"],
            ]]))
        }
        #expect(throws: ToolError.self) {
            try h.executor.applyEdit(h.editor, request(h, operations: [[
                "type": "resize_beat", "startFrame": 0, "endFrame": 60, "durationFrames": 90,
                "clips": [["clipId": "first", "role": "hold"]], "rippleTrackIds": ["picture", "sound"],
            ]]))
        }
        #expect(h.editor.timeline == before)
    }

    @Test func spanEndingAtBeatBoundaryExtendsAudioWhenSourceHasHeadroom() throws {
        let h = harness()
        h.editor.timeline.tracks[1].clips = [Fixtures.clip(id: "bed", mediaType: .audio, start: 0, duration: 60)]
        h.addAsset(id: "media-1", type: .audio, duration: 4)
        _ = try h.executor.applyEdit(h.editor, request(h, operations: [[
            "type": "resize_beat", "startFrame": 0, "endFrame": 60, "durationFrames": 90,
            "clips": [["clipId": "first", "role": "hold"], ["clipId": "bed", "role": "span"]],
            "rippleTrackIds": ["picture", "sound"],
        ]]))
        #expect(h.editor.clipFor(id: "bed")?.startFrame == 0)
        #expect(h.editor.clipFor(id: "bed")?.durationFrames == 90)
        #expect(h.editor.clipFor(id: "second")?.startFrame == 90)
    }

    @Test func boundarySpanRejectsAudioSourceOverrunWithoutMutation() throws {
        let h = harness()
        h.editor.timeline.tracks[1].clips = [Fixtures.clip(id: "bed", mediaType: .audio, start: 0, duration: 60)]
        h.addAsset(id: "media-1", type: .audio, duration: 2)
        let before = h.editor.timeline
        #expect(throws: ToolError.self) {
            try h.executor.applyEdit(h.editor, request(h, operations: [[
                "type": "resize_beat", "startFrame": 0, "endFrame": 60, "durationFrames": 90,
                "clips": [["clipId": "first", "role": "hold"], ["clipId": "bed", "role": "span"]],
                "rippleTrackIds": ["picture", "sound"],
            ]]))
        }
        #expect(h.editor.timeline == before)
        #expect(h.editor.editReceipts.isEmpty)
    }

    @Test func sourceBoundsRefuseAudioExtensionPastAvailableMaterial() throws {
        let h = harness()
        h.addAsset(id: "media-1", type: .audio, duration: 1)
        let before = h.editor.timeline
        #expect(throws: ToolError.self) {
            try h.executor.applyEdit(h.editor, request(h, operations: [["type": "resize_clip", "clipId": "foley", "durationFrames": 90]]))
        }
        #expect(h.editor.timeline == before)
    }
}

@Suite("Agent audio automation units")
@MainActor
struct AgentAudioUnitsTests {
    @Test func linearInputCreatesNativeDbEnvelopeAndRealSilence() throws {
        let track = try ToolExecutor.parseVolumeKeyframes([[0, 1.0], [30, 0.5], [60, 0.0]], units: "linear", durationFrames: 60)
        var clip = Fixtures.clip(id: "audio", mediaType: .audio, start: 0, duration: 60, volume: 0.4)
        clip.volumeTrack = track
        #expect(track.keyframes[0].value == 0)
        #expect(abs(track.keyframes[1].value - 20 * log10(0.5)) < 0.00001)
        #expect(track.keyframes[2].value == VolumeScale.floorDb)
        #expect(clip.rawVolumeAt(frame: 0) == 0.4)
        #expect(abs(clip.rawVolumeAt(frame: 30) - 0.2) < 0.00001)
        #expect(clip.rawVolumeAt(frame: 60) == 0)
    }

    @Test func dbInputIsExplicitAndRejectsUnknownUnitsAndInvalidRanges() throws {
        let track = try ToolExecutor.parseVolumeKeyframes([[0, -12.0], [60, -60.0]], units: "db", durationFrames: 60)
        #expect(track.keyframes.map(\.value) == [-12, -60])
        #expect(throws: ToolError.self) { try ToolExecutor.parseVolumeKeyframes([[0, 1.1]], units: "linear", durationFrames: 60) }
        #expect(throws: ToolError.self) { try ToolExecutor.parseVolumeKeyframes([[0, -61.0]], units: "db", durationFrames: 60) }
        #expect(throws: ToolError.self) { try ToolExecutor.parseVolumeKeyframes([[61, 1.0]], units: "linear", durationFrames: 60) }
        #expect(throws: ToolError.self) { try ToolExecutor.parseVolumeKeyframes([[0, 1.0]], units: "unknown", durationFrames: 60) }
    }

    @Test func scalarGainPreservesAutomationUnlessExplicitlyCleared() throws {
        var clip = Fixtures.clip(id: "audio", mediaType: .audio, start: 0, duration: 60)
        clip.volumeTrack = KeyframeTrack(keyframes: [Keyframe(frame: 0, value: -6.0), Keyframe(frame: 60, value: -60.0)])
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.audioTrack(id: "sound", clips: [clip])]))
        _ = try h.executor.setClipProperties(h.editor, ["clipIds": ["audio"], "volume": 0.5])
        #expect(h.editor.clipFor(id: "audio")?.volumeTrack == clip.volumeTrack)
        #expect(h.editor.clipFor(id: "audio")?.volume == 0.5)
        _ = try h.executor.setClipProperties(h.editor, ["clipIds": ["audio"], "clearVolumeAutomation": true])
        #expect(h.editor.clipFor(id: "audio")?.volumeTrack == nil)
        #expect(h.editor.clipFor(id: "audio")?.volume == 0.5)
    }

    @Test func invalidScalarGainLeavesAudioUnchanged() throws {
        let clip = Fixtures.clip(id: "audio", mediaType: .audio, start: 0, duration: 60)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])]))
        let before = h.editor.timeline
        #expect(throws: ToolError.self) { try h.executor.setClipProperties(h.editor, ["clipIds": ["audio"], "volume": -0.5]) }
        #expect(h.editor.timeline == before)
    }
}
