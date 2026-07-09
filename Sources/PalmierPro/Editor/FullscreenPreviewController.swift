import AppKit

/// Fullscreen preview mode — the preview panel takes over the entire screen so
/// detail can be judged at full size.
///
/// Deliberately reuses what already exists instead of building a second player
/// pipeline: the panel is maximized through `EditorViewModel.maximizedPanel`
/// (the same machinery as the backtick shortcut), its chrome is stripped via
/// `EditorViewModel.isPreviewFullscreen`, and the window enters native macOS
/// fullscreen on whichever screen it currently occupies. The `AVPlayerLayer`,
/// `VideoEngine`, playhead and play state are untouched, so playback continues
/// seamlessly and exiting restores the workbench exactly as it was.
@MainActor
final class FullscreenPreviewController {
    private let editor: EditorViewModel
    private weak var window: NSWindow?

    /// Panel that was maximized before entering; restored on exit.
    private var savedMaximizedPanel: EditorViewModel.FocusedPanel?
    /// True when this controller toggled native fullscreen itself (vs. the
    /// window already being in native fullscreen when the mode was entered).
    private var didEnterNativeFullscreen = false
    /// Native fullscreen transitions can't be interrupted — toggles during one
    /// are ignored. Kept in sync by the NSWindowDelegate callbacks below.
    private var isTransitioning = false

    var isActive: Bool { editor.isPreviewFullscreen }

    init(editor: EditorViewModel, window: NSWindow?) {
        self.editor = editor
        self.window = window
    }

    func toggle() {
        if isActive { exit() } else { enter() }
    }

    func enter() {
        guard !isActive, !isTransitioning, let window else { return }
        savedMaximizedPanel = editor.maximizedPanel
        editor.maximizedPanel = .preview
        editor.isPreviewFullscreen = true
        if window.styleMask.contains(.fullScreen) {
            // Already in native fullscreen (e.g. via ⌘F) — maximizing is enough.
            didEnterNativeFullscreen = false
        } else {
            didEnterNativeFullscreen = true
            window.toggleFullScreen(nil)
        }
    }

    func exit() {
        guard isActive, !isTransitioning else { return }
        let restoreNative = didEnterNativeFullscreen
        restoreWorkbench()
        if restoreNative, let window, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    /// Clears the mode flags and restores the pre-fullscreen panel layout.
    private func restoreWorkbench() {
        editor.isPreviewFullscreen = false
        editor.maximizedPanel = savedMaximizedPanel
        savedMaximizedPanel = nil
        didEnterNativeFullscreen = false
    }

    // MARK: - Native fullscreen transitions (forwarded by EditorWindowController)

    func nativeFullscreenTransitionBegan() {
        isTransitioning = true
    }

    func nativeFullscreenTransitionEnded() {
        isTransitioning = false
    }

    /// The window is leaving native fullscreen. When the exit was initiated
    /// outside this controller (green button, Mission Control, ⌘F) while the
    /// mode is active, restore the workbench so the two never drift apart.
    /// `exit()` clears `isPreviewFullscreen` before toggling, so a
    /// controller-initiated exit lands in here as a no-op.
    func nativeFullscreenWillExit() {
        isTransitioning = true
        if editor.isPreviewFullscreen {
            restoreWorkbench()
        }
    }
}

// MARK: - Window delegate bridge

/// `EditorWindowController` is the editor window's delegate solely to track
/// native fullscreen transitions for the fullscreen preview mode.
extension EditorWindowController: NSWindowDelegate {
    func windowWillEnterFullScreen(_ notification: Notification) {
        fullscreenPreview.nativeFullscreenTransitionBegan()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        fullscreenPreview.nativeFullscreenTransitionEnded()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        fullscreenPreview.nativeFullscreenWillExit()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        fullscreenPreview.nativeFullscreenTransitionEnded()
    }
}
