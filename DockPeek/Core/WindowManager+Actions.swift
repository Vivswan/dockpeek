import AppKit

/// Private/deprecated API wrappers loaded at runtime via dlsym
private let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

private typealias SLPSSetFrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError
private let _slpsSetFront: SLPSSetFrontFn? = {
    guard let handle = skylight, let sym = dlsym(handle, "_SLPSSetFrontProcessWithOptions") else { return nil }
    return unsafeBitCast(sym, to: SLPSSetFrontFn.self)
}()

@_silgen_name("GetProcessForPID")
@discardableResult
private func GetPSNForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

// MARK: - Window Actions (Activate, Close, Snap)

extension WindowManager {

    // MARK: - AX Window Matching

    /// Find the AXUIElement for a given CGWindowID by matching against AX windows.
    /// Uses private API _AXUIElementGetWindow for 100% reliable matching.
    func findAXWindow(for windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return nil }

        guard let getWindow = _axGetWindow else { return nil }
        for axWin in axWindows {
            var axWID: CGWindowID = 0
            if getWindow(axWin, &axWID) == .success, axWID == windowID {
                return axWin
            }
        }
        return nil
    }

    // MARK: - Window Activation

    /// Fallback AX window matching when the private CGWindowID API is unavailable.
    /// Tries title match first, then position+size match, then falls back to first window.
    private func fallbackMatchAXWindow(
        windowID: CGWindowID, pid _: pid_t, axWindows: [AXUIElement]
    ) -> AXUIElement? {
        // Look up CG window info for title/bounds to match against
        var targetTitle: String?
        var targetBounds: CGRect?
        if let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            for info in list {
                if let wid = info[kCGWindowNumber as String] as? CGWindowID, wid == windowID {
                    targetTitle = info[kCGWindowName as String] as? String
                    if let bd = info[kCGWindowBounds as String] as? [String: Any] {
                        targetBounds = CGRect(dictionaryRepresentation: bd as CFDictionary)
                    }
                    break
                }
            }
        }

        // Title match
        if let t = targetTitle, !t.isEmpty {
            for axWindow in axWindows {
                var titleRef: AnyObject?
                AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
                if let axTitle = titleRef as? String, axTitle == t {
                    dpLog("Fallback matched by title: '\(t)'")
                    return axWindow
                }
            }
        }

        // Position+size match — safe AXValue cast
        if let tb = targetBounds {
            for axWindow in axWindows {
                var posRef: AnyObject?
                var sizeRef: AnyObject?
                AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef)
                AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
                var pos = CGPoint.zero
                var size = CGSize.zero
                if let p = posRef, let axP = asAXValue(p) { AXValueGetValue(axP, .cgPoint, &pos) }
                if let s = sizeRef, let axS = asAXValue(s) { AXValueGetValue(axS, .cgSize, &size) }
                if abs(tb.origin.x - pos.x) < 5, abs(tb.origin.y - pos.y) < 5,
                   abs(tb.width - size.width) < 5, abs(tb.height - size.height) < 5 {
                    dpLog("Fallback matched by position+size")
                    return axWindow
                }
            }
        }

        dpLog("No match — fallback to first AX window")
        return axWindows.first
    }

    func activateWindow(windowID: CGWindowID, pid: pid_t) {
        let app = NSRunningApplication(processIdentifier: pid)

        // 1. Match AX window by CGWindowID (100% reliable via private API)
        var targetAXWindow = findAXWindow(for: windowID, pid: pid)

        if targetAXWindow != nil {
            dpLog("Matched by CGWindowID: \(windowID)")
        }

        // Fallback: get AX windows list for title/position matching
        if targetAXWindow == nil {
            let axApp = AXUIElementCreateApplication(pid)
            var windowsRef: AnyObject?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let axWindows = windowsRef as? [AXUIElement], !axWindows.isEmpty else {
                dpLog("Could not get AX windows for PID \(pid) — activating app only")
                app?.activate()
                return
            }
            targetAXWindow = fallbackMatchAXWindow(windowID: windowID, pid: pid, axWindows: axWindows)
        }

        guard let axWindow = targetAXWindow else { return }

        // Unminimize if the window is currently minimized
        var minimizedRef: AnyObject?
        AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef)
        if (minimizedRef as? Bool) == true {
            AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            dpLog("Unminimized window \(windowID)")
        }

        // 2. Activate: SkyLight first, then AX raise (AltTab's proven approach)
        //    SkyLight handles both Space switching (full-screen) and single-window
        //    activation (normal). AX raise after ensures the correct window is on top.
        var psn = ProcessSerialNumber()
        GetPSNForPID(pid, &psn)

        if let slps = _slpsSetFront {
            _ = slps(&psn, UInt32(windowID), 0x2)
        } else {
            app?.activate()
        }

        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)

        // Set this window as the app's focused window so keyboard input goes to it
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, axWindow)

        // Ensure the app is frontmost with keyboard focus
        app?.activate()

        dpLog("Activated window \(windowID) for PID \(pid)")
    }

    // MARK: - Close Window

    func closeWindow(windowID: CGWindowID, pid: pid_t) {
        guard let axWindow = findAXWindow(for: windowID, pid: pid) else {
            dpLog("closeWindow: no AX match for window \(windowID)")
            return
        }

        // Get the close button and press it
        var closeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &closeRef) == .success else {
            dpLog("closeWindow: no close button for window \(windowID)")
            return
        }
        // closeRef is guaranteed non-nil here (guard above); AXCloseButtonAttribute
        // always returns an AXUIElement. Validate the CFTypeID to be defensive.
        let closeButton = closeRef as! AXUIElement // swiftlint:disable:this force_cast
        guard CFGetTypeID(closeButton) == AXUIElementGetTypeID() else {
            dpLog("closeWindow: close button has unexpected CF type for window \(windowID)")
            return
        }
        AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
        dpLog("Closed window \(windowID)")
    }

    // MARK: - Window Snapping

    func snapWindow(windowID: CGWindowID, pid: pid_t, position: SnapPosition) {
        guard let axWindow = findAXWindow(for: windowID, pid: pid) else { return }

        // Unminimize if the window is currently minimized
        var minimizedRef: AnyObject?
        AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef)
        if (minimizedRef as? Bool) == true {
            AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            dpLog("Unminimized window \(windowID) before snapping")
        }

        // Get current window position to determine which screen it's on
        var posRef: AnyObject?
        AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef)
        var currentPos = CGPoint.zero
        if let p = posRef, let axP = asAXValue(p) { AXValueGetValue(axP, .cgPoint, &currentPos) }

        guard let primaryScreen = NSScreen.screens.first else { return }
        let primaryH = primaryScreen.frame.height
        let screen = NSScreen.screens.first { s in
            let f = s.frame
            let cgFrame = CGRect(x: f.minX, y: primaryH - f.maxY, width: f.width, height: f.height)
            return cgFrame.contains(currentPos)
        } ?? primaryScreen

        let vis = screen.visibleFrame
        let cgY = primaryH - vis.maxY

        let targetRect = switch position {
        case .left:
            CGRect(x: vis.minX, y: cgY, width: vis.width / 2, height: vis.height)
        case .right:
            CGRect(x: vis.midX, y: cgY, width: vis.width / 2, height: vis.height)
        case .fill:
            CGRect(x: vis.minX, y: cgY, width: vis.width, height: vis.height)
        }

        var pos = targetRect.origin
        var size = targetRect.size
        if let axPos = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, axPos)
        }
        if let axSize = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, axSize)
        }

        activateWindow(windowID: windowID, pid: pid)
        dpLog("Snapped window \(windowID) to \(position)")
    }
}
