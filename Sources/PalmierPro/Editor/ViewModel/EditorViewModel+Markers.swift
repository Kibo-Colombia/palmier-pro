import AppKit

/// Timeline markers and bounded playback (play a marker or a range, then stop).
extension EditorViewModel {

    var timelineMarkerLaneHeight: CGFloat {
        timeline.markers.isEmpty ? 0 : Layout.markerLaneHeight
    }

    var timelineRulerHeight: CGFloat { Layout.rulerHeight + timelineMarkerLaneHeight }

    /// Markers don't touch the composition, so this swaps only `markers` and skips the rebuild.
    func replaceMarkers(_ markers: [TimelineMarker], actionName: String) {
        let before = timeline.markers
        guard before != markers else { return }
        timeline.markers = markers
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.replaceMarkers(before, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    // MARK: - Bounded playback

    /// Seeks to `startFrame` and plays, pausing at `endFrame` (exclusive) when given.
    func playRange(startFrame: Int, endFrame: Int?) {
        if activePreviewTab != .timeline {
            selectPreviewTab(id: PreviewTab.timeline.id)
        }
        seekToFrame(startFrame)
        playbackStopFrame = endFrame.map { min($0, timeline.totalFrames) }
        play()
    }

    /// Called from the playback clock; returns true when it paused at the stop frame.
    func stopPlaybackIfPastRange(frame: Int) -> Bool {
        guard let stop = playbackStopFrame, frame >= stop else { return false }
        playbackStopFrame = nil
        pause()
        seekToFrame(max(0, stop - 1))
        return true
    }
}
