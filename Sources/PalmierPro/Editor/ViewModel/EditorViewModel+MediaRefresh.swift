import Foundation

/// Keeps the library in step with media files rewritten, restored or removed on disk while the project is open.
extension EditorViewModel {
    static let mediaWatchInterval: Duration = .seconds(2)

    func startWatchingMediaFiles() {
        mediaWatchTask?.cancel()
        mediaWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.mediaWatchInterval)
                guard !Task.isCancelled, let self else { return }
                self.reloadChangedMedia()
            }
        }
    }

    func stopWatchingMediaFiles() {
        mediaWatchTask?.cancel()
        mediaWatchTask = nil
    }

    /// Re-reads every asset whose file changed since it was last read, or every asset when `force`,
    /// then rebuilds the preview from the in-memory timeline so unsaved edits stay.
    @discardableResult
    func reloadChangedMedia(force: Bool = false) -> Int {
        var changed: [MediaAsset] = []
        var vanished = false
        for asset in mediaAssets where !asset.isGenerating && asset.type != .text && asset.type != .adjustment {
            let stamp = MediaFileStamp(url: asset.url)
            guard force || stamp != asset.fileStamp else { continue }
            guard let stamp else {
                if asset.fileStamp != nil {
                    asset.fileStamp = nil
                    mediaVisualCache.invalidate(asset.id)
                    vanished = true
                }
                continue
            }
            // Claimed now so the next tick doesn't queue the same file while it reloads.
            asset.fileStamp = stamp
            mediaVisualCache.invalidate(asset.id)
            changed.append(asset)
        }
        guard force || vanished || !changed.isEmpty else { return 0 }
        if !changed.isEmpty {
            Log.project.info("media refresh: re-reading \(changed.count) file(s) force=\(force)")
        }
        Task {
            for asset in changed {
                await finalizeImportedAsset(asset)
            }
            // Missing-media badges only redraw on a render revision.
            if vanished { timelineRenderRevision &+= 1 }
            notifyTimelineChanged()
        }
        return changed.count
    }

    func refreshMediaFromDisk() {
        reloadChangedMedia(force: true)
    }

    var missingMediaAssetIds: Set<String> {
        Set(mediaAssets.filter { !$0.isGenerating && mediaResolver.isMissing(for: $0.id) }.map(\.id))
    }

    /// Deletes library entries whose file is gone; clips using them go with them, in one undoable action.
    @discardableResult
    func removeMissingMedia() -> Int {
        let ids = missingMediaAssetIds
        deleteMediaAssets(ids: ids)
        if !ids.isEmpty { undoManager?.setActionName("Remove Missing Media") }
        return ids.count
    }
}
