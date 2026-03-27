import AppKit
import ApplicationServices

/// Handles cursor-warp and AXObserver logic to force new windows onto the primary screen.
/// Extracted from AppDelegate to isolate AX observer management.
final class PrimaryScreenEnforcer {

    // MARK: - Dependencies

    private unowned let appState: AppState

    // MARK: - State

    private var axObservers: [pid_t: AXObserver] = [:]
    private var cursorRestoreTask: DispatchWorkItem?

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Cursor Warp

    /// Warp cursor to primary screen center so macOS places the new window there.
    /// Called BEFORE the click reaches the Dock — the window is created natively on primary.
    /// Cursor is restored after the app window appears.
    func warpCursorToPrimaryBriefly() {
        guard let primary = NSScreen.screens.first else { return }
        let pH = primary.frame.height

        let savedCocoa = NSEvent.mouseLocation
        let savedCG = CGPoint(x: savedCocoa.x, y: pH - savedCocoa.y)
        let primaryCenter = CGPoint(x: primary.frame.midX, y: pH / 2)

        let primaryCG = CGRect(x: primary.frame.minX, y: pH - primary.frame.maxY,
                               width: primary.frame.width, height: primary.frame.height)
        if primaryCG.contains(savedCG) { return }

        dpLog("Warping cursor to primary center for window placement")

        CGWarpMouseCursorPosition(primaryCenter)

        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                   mouseCursorPosition: primaryCenter, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
        }

        cursorRestoreTask?.cancel()
        let task = DispatchWorkItem {
            CGWarpMouseCursorPosition(savedCG)
            if let restoreEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                          mouseCursorPosition: savedCG, mouseButton: .left) {
                restoreEvent.post(tap: .cghidEventTap)
            }
        }
        cursorRestoreTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: task)
    }

    // MARK: - New Window Observer

    func setupNewWindowObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil
        )
    }

    @objc private func appDidLaunch(_ note: Notification) {
        guard appState.forceNewWindowsToPrimary else { return }
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }

        dpLog("appDidLaunch: \(app.localizedName ?? "?") pid=\(pid)")

        // Backup: AXObserver for apps launched via Spotlight/Launchpad (not through Dock click).
        let callback: AXObserverCallback = { _, element, _, _ in
            var axWin: AXUIElement = element
            var posRef: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) != .success {
                var focusedRef: AnyObject?
                AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focusedRef)
                guard let focused = focusedRef, let axFocused = asAXUIElement(focused) else { return }
                axWin = axFocused
            }
            moveAXWindowToPrimaryIfNeeded(axWin)
        }

        removeAXObserver(pid: pid)

        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success,
              let observer else { return }

        let axApp = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(observer, axApp, kAXWindowCreatedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObservers[pid] = observer

        // Observe app termination to clean up immediately.
        class TokenBox { var token: NSObjectProtocol? }
        let tokenBox = TokenBox()
        tokenBox.token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self, weak tokenBox] note in
            guard let terminated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  terminated.processIdentifier == pid else { return }
            self?.removeAXObserver(pid: pid)
            if let token = tokenBox?.token {
                NSWorkspace.shared.notificationCenter.removeObserver(token)
                tokenBox?.token = nil
            }
        }

        // Exponential backoff polling: 5 checks covering ~2s window
        let axAppRef = axApp
        let backoffDelays: [Double] = [0.1, 0.3, 0.7, 1.2, 2.0]
        for delay in backoffDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard self?.appState.forceNewWindowsToPrimary == true else { return }
                self?.moveAppWindowToPrimaryIfNeeded(axApp: axAppRef)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak tokenBox] in
            self?.removeAXObserver(pid: pid)
            if let token = tokenBox?.token {
                NSWorkspace.shared.notificationCenter.removeObserver(token)
                tokenBox?.token = nil
            }
        }
    }

    // MARK: - Private

    private func moveAppWindowToPrimaryIfNeeded(axApp: AXUIElement) {
        var focusedRef: AnyObject?
        AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedRef)
        guard let focusedVal = focusedRef, let win = asAXUIElement(focusedVal) else { return }
        moveAXWindowToPrimaryIfNeeded(win)
    }

    func removeAXObserver(pid: pid_t) {
        guard let observer = axObservers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    func tearDown() {
        NSWorkspace.shared.notificationCenter.removeObserver(
            self, name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        for pid in axObservers.keys {
            removeAXObserver(pid: pid)
        }
        cursorRestoreTask?.cancel()
    }
}

// MARK: - Primary Screen Move Helper

/// Move an AX window to the center of the primary screen if it's not already there.
/// Free function so it can be called from the AXObserverCallback (C function pointer)
/// and from PrimaryScreenEnforcer instance methods.
private func moveAXWindowToPrimaryIfNeeded(_ axWindow: AXUIElement) {
    guard let primary = NSScreen.screens.first else { return }
    let pH = primary.frame.height
    let vis = primary.visibleFrame
    let primaryCG = CGRect(x: primary.frame.minX, y: pH - primary.frame.maxY,
                           width: primary.frame.width, height: primary.frame.height)

    var posRef: AnyObject?
    AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef)
    var pos = CGPoint.zero
    if let p = posRef, let axP = asAXValue(p) { AXValueGetValue(axP, .cgPoint, &pos) }
    guard !primaryCG.contains(pos) else { return }

    var sizeRef: AnyObject?
    AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
    var sz = CGSize(width: 800, height: 600)
    if let s = sizeRef, let axS = asAXValue(s) { AXValueGetValue(axS, .cgSize, &sz) }

    var newPos = CGPoint(
        x: vis.minX + (vis.width - sz.width) / 2,
        y: (pH - vis.maxY) + (vis.height - sz.height) / 2
    )
    if let axPos = AXValueCreate(.cgPoint, &newPos) {
        AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, axPos)
        dpLog("Moved window to primary screen center")
    }
}
