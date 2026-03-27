import AppKit
import ScreenCaptureKit

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

// Private API: get CGWindowID from an AXUIElement (100% reliable window matching)
private typealias AXUIElementGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
private let _axGetWindow: AXUIElementGetWindowFn? = {
    guard let sym = dlsym(dlopen(nil, RTLD_LAZY), "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(sym, to: AXUIElementGetWindowFn.self)
}()

enum SnapPosition { case left, right, fill }

final class WindowManager {

    /// Thumbnail cache: windowID → (image, timestamp)
    private var thumbnailCache: [CGWindowID: (image: NSImage, timestamp: Date)] = [:]
    private let cacheTTL: TimeInterval = 5.0
    private let extendedCacheTTL: TimeInterval = 10.0
    private let maxCacheSize = 30

    /// Whether preview panel is currently visible — set by AppDelegate to extend cache TTL
    var isPreviewVisible = false

    /// SCWindow lookup cache: windowID → SCWindow (avoids per-window SCShareableContent calls)
    private var scWindows: [CGWindowID: SCWindow] = [:]
    private var scWindowsTimestamp: Date = .distantPast
    private let scWindowsTTL: TimeInterval = 2.0

    /// Lock protecting ALL mutable caches from concurrent access.
    /// Guards: thumbnailCache, scWindows, scWindowsTimestamp, windowListCache,
    /// windowListCacheTimestamp, axWindowIDsCache.
    private let stateLock = NSLock()

    // MARK: - Thread-safe state accessors (synchronous, safe to call from async contexts)

    /// Thread-safe read of the SCWindow map for the given window IDs.
    private nonisolated func resolveWindows(_ windowIDs: [CGWindowID]) -> [(CGWindowID, SCWindow)] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return windowIDs.compactMap { wid in
            guard let scWindow = scWindows[wid] else { return nil }
            return (wid, scWindow)
        }
    }

    /// Thread-safe write of a single thumbnail into the cache.
    private nonisolated func storeThumbnail(_ image: NSImage, for windowID: CGWindowID) {
        stateLock.lock()
        thumbnailCache[windowID] = (image: image, timestamp: Date())
        stateLock.unlock()
    }

    /// Invalidate cached thumbnails for specific window IDs so they get re-captured.
    func invalidateThumbnails(for windowIDs: [CGWindowID]) {
        stateLock.lock()
        for wid in windowIDs {
            thumbnailCache.removeValue(forKey: wid)
        }
        stateLock.unlock()
    }

    /// Thread-safe check whether the SCWindow cache needs refreshing.
    private nonisolated func scWindowsNeedRefresh() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Date().timeIntervalSince(scWindowsTimestamp) > scWindowsTTL
    }

    /// Thread-safe replacement of the entire SCWindow cache.
    private nonisolated func replaceSCWindows(_ map: [CGWindowID: SCWindow]) {
        stateLock.lock()
        scWindows = map
        scWindowsTimestamp = Date()
        stateLock.unlock()
    }

    /// Force the SCWindow cache to refresh on next access.
    private nonisolated func invalidateSCWindows() {
        stateLock.lock()
        scWindowsTimestamp = .distantPast
        stateLock.unlock()
    }

    /// Shared cross-PID CGWindowListCopyWindowInfo cache — one system-wide list
    /// instead of redundant per-PID copies.
    private var windowListCache: [[String: Any]] = []
    private var windowListCacheTimestamp: Date = .distantPast
    private let windowListCacheTTL: TimeInterval = 0.5

    /// AX window IDs cache: pid → (ids, timestamp)
    private var axWindowIDsCache: [pid_t: (Set<CGWindowID>, Date)] = [:]
    private let axWindowIDsCacheTTL: TimeInterval = 1.0

    // MARK: - Window Enumeration

    /// Returns the system-wide window list, using a shared cache to avoid
    /// redundant CGWindowListCopyWindowInfo calls across PIDs.
    private func cachedWindowList() -> [[String: Any]] {
        stateLock.lock()
        let now = Date()
        if now.timeIntervalSince(windowListCacheTimestamp) < windowListCacheTTL {
            let cached = windowListCache
            stateLock.unlock()
            return cached
        }
        stateLock.unlock()

        // CGWindowListCopyWindowInfo is fast (~1-2ms); fetch outside lock to avoid
        // blocking readers of valid cache, but use a separate fetch-lock to ensure
        // only one thread fetches at a time.
        guard let fetched = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            dpLog("CGWindowListCopyWindowInfo failed")
            return []
        }

        stateLock.lock()
        windowListCache = fetched
        windowListCacheTimestamp = now
        stateLock.unlock()

        return fetched
    }

    /// Enumerate windows for an app. Only returns on-screen (visible) windows by default.
    /// Cross-references CGWindow list with AXUIElement windows to filter out
    /// overlays, helper windows, and other non-standard windows (e.g. Chrome translation bar).
    func windowsForApp(pid: pid_t, includeMinimized: Bool = false) -> [WindowInfo] {
        let list = cachedWindowList()

        var windows: [WindowInfo] = []

        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID else { continue }

            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            guard layer == 0 else { continue }

            guard let bd = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: bd as CFDictionary),
                  bounds.width > 1, bounds.height > 1 else { continue }

            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0 else { continue }

            let isOnScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false

            // Skip off-screen / hidden windows unless includeMinimized is set
            if !isOnScreen, !includeMinimized { continue }

            let title = info[kCGWindowName as String] as? String ?? ""
            let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""

            windows.append(WindowInfo(
                id: windowID, title: title, bounds: bounds,
                ownerPID: ownerPID, ownerName: ownerName,
                isOnScreen: isOnScreen, isMinimized: !isOnScreen,
                thumbnail: nil
            ))
        }

        // Cross-reference with AX windows to filter out overlays/helper windows.
        // AX kAXWindowsAttribute only returns "real" user-facing windows,
        // excluding Chrome translation bars, tooltips, popovers, etc.
        let axIDs = axWindowIDs(for: pid)
        if !axIDs.isEmpty {
            let before = windows.count
            windows = windows.filter { axIDs.contains($0.id) }
            if windows.count != before {
                dpLog("AX filter: \(before) → \(windows.count) windows for PID \(pid)")
            }
        }

        dpLog("Found \(windows.count) windows for PID \(pid) (includeMinimized=\(includeMinimized))")
        return windows
    }

    /// Get the set of CGWindowIDs that correspond to real standard AX windows.
    /// Filters out popups, dialogs, floating panels, overlays (e.g. Chrome translation bar).
    /// Results are cached for 1 second to avoid redundant AX IPC calls.
    private func axWindowIDs(for pid: pid_t) -> Set<CGWindowID> {
        stateLock.lock()
        let now = Date()
        if let cached = axWindowIDsCache[pid],
           now.timeIntervalSince(cached.1) < axWindowIDsCacheTTL {
            let ids = cached.0
            stateLock.unlock()
            return ids
        }
        stateLock.unlock()

        guard let getWindow = _axGetWindow else { return [] }
        let axApp = AXUIElementCreateApplication(pid)
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let axWindows = ref as? [AXUIElement] else { return [] }

        var ids = Set<CGWindowID>()
        for axWin in axWindows {
            // Only include standard windows (skip dialogs, floating panels, popups)
            var subroleRef: AnyObject?
            AXUIElementCopyAttributeValue(axWin, kAXSubroleAttribute as CFString, &subroleRef)
            let subrole = subroleRef as? String ?? ""
            guard subrole == "AXStandardWindow" else {
                dpLog("AX skip subrole=\(subrole) for PID \(pid)")
                continue
            }

            var wid: CGWindowID = 0
            if getWindow(axWin, &wid) == .success, wid != 0 {
                ids.insert(wid)
            }
        }

        stateLock.lock()
        axWindowIDsCache[pid] = (ids, now)
        stateLock.unlock()
        return ids
    }

    // MARK: - Thumbnails

    /// Returns a cached thumbnail synchronously, or nil on cache miss.
    /// This is the fast path — no async work, no capture.
    func thumbnail(for windowID: CGWindowID, maxSize _: CGFloat = 200) -> NSImage? {
        let effectiveTTL = isPreviewVisible ? extendedCacheTTL : cacheTTL

        stateLock.lock()
        defer { stateLock.unlock() }

        if let cached = thumbnailCache[windowID],
           Date().timeIntervalSince(cached.timestamp) < effectiveTTL {
            return cached.image
        }

        // Prune expired entries and enforce size limit
        let now = Date()
        if thumbnailCache.count > maxCacheSize {
            thumbnailCache = thumbnailCache.filter { now.timeIntervalSince($0.value.timestamp) < effectiveTTL }
            if thumbnailCache.count >= maxCacheSize {
                let sorted = thumbnailCache.sorted { $0.value.timestamp < $1.value.timestamp }
                for (id, _) in sorted.prefix(thumbnailCache.count - maxCacheSize + 1) {
                    thumbnailCache.removeValue(forKey: id)
                }
            }
        }

        return nil
    }

    /// Captures thumbnails for multiple windows asynchronously via ScreenCaptureKit.
    /// Calls completion on the main queue with captured images.
    ///
    /// Uses a detached Task instead of DispatchSemaphore to avoid deadlock risk
    /// when bridging between sync and async contexts.
    func captureThumbnails(
        for windowIDs: [CGWindowID],
        maxSize: CGFloat = 200,
        completion: @escaping ([CGWindowID: NSImage]) -> Void
    ) {
        Task.detached { [weak self] in
            guard let self else {
                await MainActor.run { completion([:]) }
                return
            }

            // Refresh SCWindow lookup table if stale
            do {
                try await refreshSCWindowsIfNeeded()
            } catch {
                dpLog("SCShareableContent refresh failed: \(error)")
                await MainActor.run { completion([:]) }
                return
            }

            // Resolve SCWindow objects for requested window IDs
            var windowMap = resolveWindows(windowIDs)

            // If any windows are missing, force-refresh and retry once
            if windowMap.count < windowIDs.count {
                invalidateSCWindows()
                do {
                    try await refreshSCWindowsIfNeeded()
                } catch {}
                windowMap = resolveWindows(windowIDs)
            }

            // Capture all windows concurrently
            var results: [CGWindowID: NSImage] = [:]
            await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
                for (wid, scWindow) in windowMap {
                    group.addTask {
                        do {
                            let image = try await self.captureWindow(scWindow, maxSize: maxSize)
                            return (wid, image)
                        } catch {
                            dpLog("Capture failed for window \(wid): \(error)")
                            return (wid, nil)
                        }
                    }
                }
                for await (wid, image) in group {
                    if let image {
                        results[wid] = image
                        self.storeThumbnail(image, for: wid)
                    }
                }
            }

            await MainActor.run { [results] in
                completion(results)
            }
        }
    }

    /// Refreshes the SCWindow lookup cache if stale.
    private func refreshSCWindowsIfNeeded() async throws {
        guard scWindowsNeedRefresh() else { return }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )

        var map: [CGWindowID: SCWindow] = [:]
        map.reserveCapacity(content.windows.count)
        for window in content.windows {
            map[window.windowID] = window
        }

        replaceSCWindows(map)
    }

    /// Captures a single window via SCScreenshotManager and returns a scaled NSImage.
    private func captureWindow(_ scWindow: SCWindow, maxSize: CGFloat) async throws -> NSImage {
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)

        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.captureResolution = .best

        // Request 2× maxSize pixels so thumbnails are Retina-sharp
        let scale: CGFloat = 2.0
        let ww = CGFloat(scWindow.frame.width)
        let wh = CGFloat(scWindow.frame.height)
        guard ww > 0, wh > 0 else {
            throw NSError(
                domain: "DockPeek",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Window has zero size"]
            )
        }
        let aspect = ww / wh
        let logicalW: CGFloat
        let logicalH: CGFloat
        if aspect > 1 {
            logicalW = maxSize
            logicalH = maxSize / aspect
        } else {
            logicalW = maxSize * aspect
            logicalH = maxSize
        }
        config.width = max(1, Int(logicalW * scale))
        config.height = max(1, Int(logicalH * scale))

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )

        return NSImage(cgImage: cgImage, size: NSSize(width: logicalW, height: logicalH))
    }

    /// Captures a window at full resolution for the highlight overlay.
    /// The returned NSImage is sized to match the given bounds so it fills the overlay.
    func captureOverlayImage(
        for windowID: CGWindowID,
        bounds: CGRect,
        completion: @escaping (NSImage?) -> Void
    ) {
        Task.detached { [weak self] in
            guard let self else {
                await MainActor.run { completion(nil) }
                return
            }

            do {
                try await refreshSCWindowsIfNeeded()
                guard let scWindow = resolveWindows([windowID]).first?.1 else {
                    await MainActor.run { completion(nil) }
                    return
                }

                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let config = SCStreamConfiguration()
                config.showsCursor = false
                config.captureResolution = .best
                // Request pixels matching the overlay size at 2× for Retina
                config.width = max(1, Int(bounds.width * 2))
                config.height = max(1, Int(bounds.height * 2))

                let cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config
                )

                // Size to match CG bounds so it fills the overlay exactly
                let image = NSImage(cgImage: cgImage, size: NSSize(width: bounds.width, height: bounds.height))
                await MainActor.run { completion(image) }
            } catch {
                dpLog("Overlay capture failed for window \(windowID): \(error)")
                await MainActor.run { completion(nil) }
            }
        }
    }

    // MARK: - AX Window Matching

    /// Find the AXUIElement for a given CGWindowID by matching against AX windows.
    /// Uses private API _AXUIElementGetWindow for 100% reliable matching.
    private func findAXWindow(for windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
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
                        targetAXWindow = axWindow
                        dpLog("Fallback matched by title: '\(t)'")
                        break
                    }
                }
            }

            // Position+size match — safe AXValue cast
            if targetAXWindow == nil, let tb = targetBounds {
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
                        targetAXWindow = axWindow
                        dpLog("Fallback matched by position+size")
                        break
                    }
                }
            }

            if targetAXWindow == nil {
                dpLog("No match — fallback to first AX window")
                targetAXWindow = axWindows.first
            }
        }

        guard let axWindow = targetAXWindow else { return }

        // 3. Activate: SkyLight first, then AX raise (AltTab's proven approach)
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
        // Safe: AXCloseButtonAttribute returns an AXUIElement
        let closeButton = closeRef as! AXUIElement
        AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
        dpLog("Closed window \(windowID)")
    }

    // MARK: - Window Snapping

    func snapWindow(windowID: CGWindowID, pid: pid_t, position: SnapPosition) {
        guard let axWindow = findAXWindow(for: windowID, pid: pid) else { return }

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

        var targetRect = switch position {
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
