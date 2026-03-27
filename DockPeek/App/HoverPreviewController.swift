import AppKit
import Combine

/// Manages all hover-preview polling, dock-area detection, and hover timer logic.
/// Extracted from AppDelegate to isolate the adaptive-polling state machine.
final class HoverPreviewController {

    // MARK: - Dependencies

    // Lifetime guarantee: these objects are owned by AppDelegate and live for the
    // entire application lifetime. AppDelegate creates HoverPreviewController in
    // applicationDidFinishLaunching and never deallocates it before termination.
    // Using unowned avoids retain cycles and the overhead of weak reference nil-checks
    // on every poll cycle (~15 Hz when active).

    private unowned let appState: AppState
    private unowned let dockInspector: DockAXInspector
    private unowned let windowManager: WindowManager
    private unowned let previewPanel: PreviewPanel
    private unowned let highlightOverlay: HighlightOverlay

    /// Called when hover determines a preview should be shown.
    /// AppDelegate wires this to PreviewCoordinator.showPreviewForWindows.
    var showPreview: ((_ windows: [WindowInfo], _ point: CGPoint) -> Void)?

    // MARK: - Hover State

    private var hoverPollTimer: DispatchSourceTimer?
    private var currentPollInterval: TimeInterval = idlePollInterval
    private static let idlePollInterval: TimeInterval = 0.25 // 4 Hz
    private static let activePollInterval: TimeInterval = 0.066 // ~15 Hz

    private(set) var cachedDockRect: CGRect = .zero
    var previewIsVisible = false {
        didSet { windowManager.isPreviewVisible = previewIsVisible }
    }

    private var hoverTimer: DispatchWorkItem?
    private var hoverDismissTimer: DispatchWorkItem?
    var lastHoveredBundleID: String?
    private var hoverSettingObserver: AnyCancellable?

    // AX hit-test cache: avoid redundant AX calls for same position within 100ms
    private var cachedAXHitResult: (point: CGPoint, result: DockApp?, timestamp: Date)?
    private let axHitCacheTTL: TimeInterval = 0.1

    // Mouse position tracking: skip processing when mouse hasn't moved
    private var lastPollMouseLocation: CGPoint?
    private var lastPollInDock = false

    // Cached Dock settings
    private var isDockAutoHide = false
    private var dockOrientation = "bottom"

    // MARK: - Init

    init(
        appState: AppState,
        dockInspector: DockAXInspector,
        windowManager: WindowManager,
        previewPanel: PreviewPanel,
        highlightOverlay: HighlightOverlay
    ) {
        self.appState = appState
        self.dockInspector = dockInspector
        self.windowManager = windowManager
        self.previewPanel = previewPanel
        self.highlightOverlay = highlightOverlay
    }

    // MARK: - Public API

    /// Observe previewOnHover toggle — start/stop monitor dynamically.
    /// Uses KVO on the specific UserDefaults key rather than the broad
    /// didChangeNotification to avoid firing on unrelated defaults changes.
    func observeHoverSetting() {
        hoverSettingObserver = UserDefaults.standard
            .publisher(for: \.previewOnHover)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    if hoverPollTimer == nil,
                       AccessibilityManager.shared.isAccessibilityGranted {
                        startHoverMonitor()
                    }
                } else {
                    stopHoverMonitor()
                }
            }
    }

    func startHoverMonitor() {
        stopHoverMonitor()
        updateCachedDockRect()

        currentPollInterval = Self.idlePollInterval
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + currentPollInterval,
            repeating: currentPollInterval
        )
        timer.setEventHandler { [weak self] in
            self?.pollMousePosition()
        }
        timer.resume()
        hoverPollTimer = timer
        dpLog("Hover poll timer started (idle \(Self.idlePollInterval)s)")
    }

    func stopHoverMonitor() {
        hoverPollTimer?.cancel()
        hoverPollTimer = nil
        hoverTimer?.cancel()
        hoverTimer = nil
        hoverDismissTimer?.cancel()
        hoverDismissTimer = nil
        lastHoveredBundleID = nil
        lastPollMouseLocation = nil
        lastPollInDock = false
        cachedAXHitResult = nil
        previewIsVisible = false
    }

    /// Cancel pending hover/dismiss timers (e.g. on click).
    func cancelHoverTimers() {
        hoverTimer?.cancel()
        hoverTimer = nil
        hoverDismissTimer?.cancel()
        hoverDismissTimer = nil
    }

    func updateCachedDockRect() {
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        isDockAutoHide = dockDefaults?.bool(forKey: "autohide") ?? false
        dockOrientation = dockDefaults?.string(forKey: "orientation") ?? "bottom"
        cachedDockRect = DockRectDetector.detectDockRect(autoHide: isDockAutoHide, orientation: dockOrientation)
        dpLog("Cached dock rect (CG): \(cachedDockRect) autoHide=\(isDockAutoHide) orientation=\(dockOrientation)")
    }

    func isPointInDockArea(_ point: CGPoint) -> Bool {
        if cachedDockRect == .zero { updateCachedDockRect() }
        return cachedDockRect.contains(point)
    }

    func tearDown() {
        stopHoverMonitor()
        hoverSettingObserver?.cancel()
        hoverSettingObserver = nil
    }

    // MARK: - Polling

    private func pollMousePosition() {
        let cgPoint = ScreenGeometry.cocoaToCG(NSEvent.mouseLocation)

        let inDock = cachedDockRect.contains(cgPoint)
        let currentlyVisible = previewPanel.isVisible
        if previewIsVisible != currentlyVisible {
            previewIsVisible = currentlyVisible
        }
        let needsActive = inDock || previewIsVisible

        // Adapt polling interval
        let desired = needsActive ? Self.activePollInterval : Self.idlePollInterval
        if abs(currentPollInterval - desired) > 0.001 {
            currentPollInterval = desired
            hoverPollTimer?.schedule(deadline: .now() + desired, repeating: desired)
            dpLog("Poll interval → \(desired)s")
        }

        // Skip processing if mouse hasn't moved and dock-area status unchanged
        if let lastLoc = lastPollMouseLocation,
           lastLoc.x == cgPoint.x, lastLoc.y == cgPoint.y,
           lastPollInDock == inDock {
            return
        }
        lastPollMouseLocation = cgPoint
        lastPollInDock = inDock

        if needsActive {
            processHoverEvent(cgPoint: cgPoint)
        }
    }

    private func processHoverEvent(cgPoint: CGPoint) {
        guard appState.previewOnHover else { return }

        let cocoaLoc = ScreenGeometry.cgToCocoa(cgPoint)

        // If mouse is over the preview panel, cancel any pending dismiss
        if previewPanel.isVisible, previewPanel.frame.contains(cocoaLoc) {
            hoverDismissTimer?.cancel()
            hoverDismissTimer = nil
            return
        }

        let inDock = isPointInDockArea(cgPoint)
        let dockApp = inDock ? cachedAppAtPoint(cgPoint) : nil

        // Mouse is outside both dock and preview panel
        if !inDock || dockApp == nil {
            hoverTimer?.cancel()
            hoverTimer = nil
            if previewPanel.isVisible {
                // Delayed dismiss — gives time to cross the gap to the preview panel
                if hoverDismissTimer == nil {
                    let task = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        let currentLoc = NSEvent.mouseLocation
                        if previewPanel.isVisible, previewPanel.frame.contains(currentLoc) {
                            hoverDismissTimer = nil
                            return
                        }
                        lastHoveredBundleID = nil
                        hoverDismissTimer = nil
                        previewIsVisible = false
                        highlightOverlay.hide()
                        previewPanel.dismissPanel()
                    }
                    hoverDismissTimer = task
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
                }
            } else {
                lastHoveredBundleID = nil
            }
            return
        }

        // Mouse is in dock on an app — cancel any pending dismiss
        hoverDismissTimer?.cancel()
        hoverDismissTimer = nil

        guard let dockApp else { return }

        let bundleID = dockApp.bundleIdentifier ?? dockApp.name

        // Same app — keep existing timer/preview
        if bundleID == lastHoveredBundleID { return }

        // Different app — cancel old timer and dismiss current preview
        hoverTimer?.cancel()
        let wasVisible = previewPanel.isVisible
        if wasVisible {
            highlightOverlay.hide()
            previewPanel.dismissPanel(animated: false)
        }
        lastHoveredBundleID = bundleID

        guard dockApp.isRunning, let pid = dockApp.pid else {
            hoverTimer = nil
            return
        }

        if appState.isExcluded(bundleID: dockApp.bundleIdentifier) {
            hoverTimer = nil
            return
        }

        // Instant switch when already browsing, normal delay for first hover
        if wasVisible {
            handleHoverPreview(for: pid, at: cgPoint)
        } else {
            let task = DispatchWorkItem { [weak self] in
                self?.handleHoverPreview(for: pid, at: cgPoint)
            }
            hoverTimer = task
            DispatchQueue.main.asyncAfter(deadline: .now() + appState.hoverDelay, execute: task)
        }
    }

    // MARK: - Private

    private func cachedAppAtPoint(_ point: CGPoint) -> DockApp? {
        let now = Date()
        if let cached = cachedAXHitResult,
           cached.point.x == point.x, cached.point.y == point.y,
           now.timeIntervalSince(cached.timestamp) < axHitCacheTTL {
            return cached.result
        }
        let result = dockInspector.appAtPoint(point)
        cachedAXHitResult = (point: point, result: result, timestamp: now)
        return result
    }

    private func handleHoverPreview(for pid: pid_t, at point: CGPoint) {
        guard appState.previewOnHover else { return }

        let windows = windowManager.windowsForApp(
            pid: pid,
            includeMinimized: appState.showMinimizedWindows,
            includeOtherSpaces: appState.showOtherSpaceWindows
        )
        guard !windows.isEmpty else { return }

        dpLog("Hover preview: \(windows.count) window(s) for PID \(pid)")
        showPreview?(windows, point)
    }
}

// MARK: - KVO key path for previewOnHover

private extension UserDefaults {
    /// Typed key path for KVO observation of the previewOnHover setting.
    @objc dynamic var previewOnHover: Bool {
        bool(forKey: "previewOnHover")
    }
}
