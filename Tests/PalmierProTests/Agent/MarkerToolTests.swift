import Foundation
import Testing
@testable import PalmierPro

@Suite("Timeline markers")
@MainActor
struct MarkerToolTests {

    @Test func legacyTimelineWithoutMarkersDecodesAndEncodesUnchanged() throws {
        let json = #"{"fps":30,"width":1920,"height":1080,"settingsConfigured":true,"tracks":[]}"#
        let timeline = try JSONDecoder().decode(Timeline.self, from: Data(json.utf8))
        #expect(timeline.markers.isEmpty)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(timeline)) as? [String: Any]
        #expect(encoded?["markers"] == nil)
    }

    @Test func markersRoundTripThroughProjectJSON() throws {
        var timeline = Timeline()
        timeline.markers = [TimelineMarker(name: "HOOK 1 · Three pulls", color: .red, startFrame: 12460, durationFrames: 824, note: "cold open")]
        let decoded = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(timeline))
        #expect(decoded.markers == timeline.markers)
    }

    @Test func unknownColorFallsBackToBlue() throws {
        let json = #"{"name":"A","color":"chartreuse","startFrame":10}"#
        let marker = try JSONDecoder().decode(TimelineMarker.self, from: Data(json.utf8))
        #expect(marker.color == .blue)
        #expect(marker.durationFrames == 0)
    }

    @Test func resolveMatchesIdNameAndWordBoundaryPrefix() throws {
        let markers = [
            TimelineMarker(id: "h1", name: "HOOK 1 · Three pulls", startFrame: 0),
            TimelineMarker(id: "h10", name: "HOOK 10 · Later", startFrame: 100),
            TimelineMarker(id: "h2", name: "HOOK 2 · The tiny clock", startFrame: 50),
        ]
        #expect(try markers.resolve("h10").id == "h10")
        #expect(try markers.resolve("hook 2").id == "h2")
        #expect(try markers.resolve("HOOK 1").id == "h1")
        #expect(throws: ToolError.self) { try markers.resolve("HOOK") }
        #expect(throws: ToolError.self) { try markers.resolve("HOOK 3") }
    }

    @Test func addListUpdateRemoveRoundTrip() async throws {
        let h = ToolHarness(timeline: Timeline())
        let added = try await h.runOK("add_markers", args: ["markers": [
            ["id": "hook-2", "name": "HOOK 2 · The tiny clock", "startFrame": 13284, "endFrame": 13861, "color": "green"],
            ["name": "HOOK 1 · Three pulls", "startFrame": 12460, "durationFrames": 824],
        ]]) as? [String: Any]
        #expect((added?["added"] as? [Any])?.count == 2)
        #expect(h.editor.timeline.markers.map(\.startFrame) == [12460, 13284])

        let listed = try await h.runOK("list_markers") as? [String: Any]
        let first = (listed?["markers"] as? [[String: Any]])?.first
        #expect(first?["endFrame"] as? Int == 13284)
        #expect(first?["startSeconds"] as? Double == 415.333)

        _ = try await h.runOK("update_marker", args: ["marker": "HOOK 2", "name": "HOOK 2 · Clock", "color": "yellow"])
        #expect(h.editor.timeline.markers[1].name == "HOOK 2 · Clock")
        #expect(h.editor.timeline.markers[1].color == .yellow)
        #expect(h.editor.timeline.markers[1].durationFrames == 577)

        let timeline = try await h.runOK("get_timeline") as? [String: Any]
        #expect((timeline?["markers"] as? [Any])?.count == 2)

        _ = try await h.runOK("remove_markers", args: ["markers": ["hook-2"]])
        #expect(h.editor.timeline.markers.map(\.id) != ["hook-2"])
        #expect(h.editor.timeline.markers.count == 1)
    }

    @Test func addMarkersRejectsDuplicateIdsAndBadColors() async {
        let h = ToolHarness(timeline: Timeline())
        let dup = await h.runRaw("add_markers", args: ["markers": [
            ["id": "x", "name": "A", "startFrame": 0], ["id": "x", "name": "B", "startFrame": 10],
        ]])
        #expect(dup.isError)
        #expect(h.editor.timeline.markers.isEmpty)
        let color = await h.runRaw("add_markers", args: ["markers": [["name": "A", "startFrame": 0, "color": "chartreuse"]]])
        #expect(color.isError)
        let unknown = await h.runRaw("add_markers", args: ["markers": [["name": "A", "startFrame": 0, "start": 1]]])
        #expect(unknown.isError)
    }

    @Test func playRangeURLParsesSecondsMarkerAndPlusAsSpace() throws {
        let url = try #require(URL(string: "koma://play?project=%2FUsers%2Fme%2FVideo%201.palmier&start=442.8&end=462.03"))
        let request = KomaURLHandler.playRequest(from: url)
        #expect(request.project == "/Users/me/Video 1.palmier")
        #expect(request.start == 442.8)
        #expect(request.end == 462.03)
        let byMarker = KomaURLHandler.playRequest(from: try #require(URL(string: "koma://play?marker=HOOK+2")))
        #expect(byMarker.marker == "HOOK 2")
        #expect(byMarker.project == nil)
    }

    @Test func boundedPlaybackStopsAtEndFrame() {
        let editor = EditorViewModel()
        editor.playbackStopFrame = 100
        #expect(editor.stopPlaybackIfPastRange(frame: 99) == false)
        #expect(editor.stopPlaybackIfPastRange(frame: 100) == true)
        #expect(editor.playbackStopFrame == nil)
        #expect(editor.isPlaying == false)
    }
}
