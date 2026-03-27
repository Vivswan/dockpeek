import AppKit

/// Manages showing the preview panel with all its callbacks (onSelect, onClose, onSnap, etc.).
/// Extracted from AppDelegate to isolate preview presentation from event handling.
final class PreviewCoordinator {

    // MARK: - Dependencies (unowned — lifetime bounded by AppDelegate)

    private unowned let appState: AppState
    private unowned let windowManager: WindowManager
    private unowned let previewPanel: PreviewPanel
    private unowned let highlightOverlay: HighlightOverlay

    /// Called when preview visibility changes.
    /// AppDelegate wires this to sync HoverPreviewController.previewIsVisible.
    var onPreviewVisibilityChanged: ((Bool) -> Void)?

    private var previewGeneration: UInt = 0

    init(
        appState: AppState,
        windowManager: WindowManager,
        previewPanel: PreviewPanel,
        highlightOverlay: HighlightOverlay
    ) {
        self.appState = appState
        self.windowManager = windowManager
        self.previewPanel = previewPanel
        self.highlightOverlay = highlightOverlay
    }

    // MARK: - Show Preview

    func showPreviewForWindows(_ windows: [WindowInfo], at point: CGPoint) {
        onPreviewVisibilityChanged?(true)
        previewGeneration &+= 1
        let generation = previewGeneration
        let thumbSize = CGFloat(appState.thumbnailSize)

        // Invalidate only this app's thumbnails so they get fresh captures
        let allIDs = windows.map { $0.id }
        windowManager.invalidateThumbnails(for: allIDs)

        // Show panel immediately with placeholders, then update with real thumbnails
        var enriched = windows

        windowManager.captureThumbnails(for: allIDs, maxSize: thumbSize) { [weak self] results in
            guard let self, previewPanel.isVisible, previewGeneration == generation else { return }
            for i in enriched.indices {
                if let img = results[enriched[i].id] {
                    enriched[i].thumbnail = img
                }
            }
            previewPanel.updateThumbnails(enriched)
        }

        previewPanel.showPreview(
            windows: enriched,
            thumbnailSize: thumbSize,
            showTitles: appState.showWindowTitles,
            showSnapButtons: appState.showSnapButtons,
            showCloseButton: appState.showCloseButton,
            near: point,
            onSelect: { [weak self] win in
                self?.highlightOverlay.hide()
                self?.previewPanel.dismissPanel(animated: false)
                self?.onPreviewVisibilityChanged?(false)
                self?.windowManager.activateWindow(windowID: win.id, pid: win.ownerPID)
            },
            onClose: { [weak self] win in
                self?.highlightOverlay.hide()
                self?.windowManager.closeWindow(windowID: win.id, pid: win.ownerPID)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard let self else { return }
                    let remaining = self.windowManager.windowsForApp(
                        pid: win.ownerPID,
                        includeMinimized: self.appState.showMinimizedWindows,
                        includeOtherSpaces: self.appState.showOtherSpaceWindows
                    )
                    if remaining.count < 2 {
                        self.previewPanel.dismissPanel()
                    } else {
                        self.showPreviewForWindows(remaining, at: point)
                    }
                }
            },
            onSnap: { [weak self] win, position in
                self?.highlightOverlay.hide()
                self?.previewPanel.dismissPanel(animated: false)
                self?.windowManager.snapWindow(windowID: win.id, pid: win.ownerPID, position: position)
            },
            onDismiss: { [weak self] in
                self?.highlightOverlay.hide()
                self?.previewPanel.dismissPanel()
            },
            onHoverWindow: { [weak self] (win: WindowInfo?) in
                guard let self, appState.livePreviewOnHover else { return }
                if let win {
                    // Skip highlight overlay for minimized or other-Space windows
                    // (their screen position is stale or invisible)
                    guard !win.isMinimized, !win.isOnOtherSpace else {
                        highlightOverlay.hide()
                        return
                    }
                    highlightOverlay.show(for: win)
                    let hoveredID = win.id
                    windowManager.captureOverlayImage(for: win.id, bounds: win.bounds) { [weak self] image in
                        guard let self, let image else { return }
                        guard highlightOverlay.currentID == hoveredID else { return }
                        highlightOverlay.updateImage(image)
                    }
                } else {
                    highlightOverlay.hide()
                }
            }
        )
    }
}
