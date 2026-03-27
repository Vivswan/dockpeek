import AppKit
import ScreenCaptureKit

// Private API: get CGWindowID from an AXUIElement (100% reliable window matching)
// Shared across WindowManager and WindowManager+Actions
typealias AXUIElementGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
let _axGetWindow: AXUIElementGetWindowFn? = {
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

    /// Active capture tasks — cancelled when preview is dismissed or new captures start
    private var activeThumbnailTask: Task<Void, Never>?
    private var activeOverlayTask: Task<Void, Never>?

    /// SCWindow lookup cache: windowID → SCWindow (avoids per-window SCShareableContent calls)
    private var scWindows: [CGWindowID: SCWindow] = [:]
    private var scWindowsTimestamp: Date = .distantPast
    private let scWindowsTTL: TimeInterval = 2.0

    /// Lock protecting ALL mutable caches from concurrent access.
    /// Guards: thumbnailCache, scWindows, scWindowsTimestamp, windowListCache,
    /// windowListCacheTimestamp, axWindowInfoCache.
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
    /// Prunes expired/excess entries on the write path to keep cache bounded.
    private nonisolated func storeThumbnail(_ image: NSImage, for windowID: CGWindowID) {
        stateLock.lock()
        thumbnailCache[windowID] = (image: image, timestamp: Date())

        // Prune expired entries and enforce size limit
        if thumbnailCache.count > maxCacheSize {
            let effectiveTTL = isPreviewVisible ? extendedCacheTTL : cacheTTL
            let now = Date()
            thumbnailCache = thumbnailCache.filter { now.timeIntervalSince($0.value.timestamp) < effectiveTTL }
            if thumbnailCache.count >= maxCacheSize {
                let sorted = thumbnailCache.sorted { $0.value.timestamp < $1.value.timestamp }
                for (id, _) in sorted.prefix(thumbnailCache.count - maxCacheSize + 1) {
                    thumbnailCache.removeValue(forKey: id)
                }
            }
        }

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

    /// Cancel any in-flight capture tasks (e.g. when preview is dismissed).
    func cancelActiveTasks() {
        activeThumbnailTask?.cancel()
        activeThumbnailTask = nil
        activeOverlayTask?.cancel()
        activeOverlayTask = nil
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

    /// Serializes CGWindowListCopyWindowInfo fetches so only one thread
    /// fetches at a time (avoids redundant system calls when cache is stale).
    private let fetchLock = NSLock()

    /// AX window info cache: pid → (map of windowID → isMinimized, timestamp)
    private var axWindowInfoCache: [pid_t: ([CGWindowID: Bool], Date)] = [:]
    private let axWindowInfoCacheTTL: TimeInterval = 1.0

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

        // Serialize fetches: only one thread calls CGWindowListCopyWindowInfo.
        // Others wait, then see the updated cache.
        fetchLock.lock()
        defer { fetchLock.unlock() }

        // Double-check: another thread may have fetched while we waited
        stateLock.lock()
        if Date().timeIntervalSince(windowListCacheTimestamp) < windowListCacheTTL {
            let cached = windowListCache
            stateLock.unlock()
            return cached
        }
        stateLock.unlock()

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

    /// Enumerate windows for an app. Returns on-screen windows by default.
    /// When `includeMinimized` is true, includes minimized (Dock-stashed) windows.
    /// When `includeOtherSpaces` is true, includes windows on other macOS Spaces/desktops.
    /// Cross-references CGWindow list with AXUIElement windows to filter out
    /// overlays, helper windows, and other non-standard windows (e.g. Chrome translation bar).
    func windowsForApp(pid: pid_t, includeMinimized: Bool = false, includeOtherSpaces: Bool = false) -> [WindowInfo] {
        let list = cachedWindowList()
        let axInfo = axWindowInfo(for: pid)
        return Self.filterWindows(
            from: list, pid: pid, axInfo: axInfo,
            includeMinimized: includeMinimized, includeOtherSpaces: includeOtherSpaces
        )
    }

    /// Pure filtering logic extracted for testability.
    /// Takes raw CG window list and AX info, returns filtered+sorted WindowInfo array.
    static func filterWindows(
        from list: [[String: Any]],
        pid: pid_t,
        axInfo: [CGWindowID: Bool],
        includeMinimized: Bool,
        includeOtherSpaces: Bool
    ) -> [WindowInfo] {
        let axIDs = Set(axInfo.keys)

        var windows: [WindowInfo] = []
        var seenIDs = Set<CGWindowID>()

        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID else { continue }

            // Deduplicate: CGWindowListCopyWindowInfo can return duplicate entries
            guard seenIDs.insert(windowID).inserted else { continue }

            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            guard layer == 0 else { continue }

            guard let bd = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: bd as CFDictionary),
                  bounds.width > 1, bounds.height > 1 else { continue }

            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0 else { continue }

            let isOnScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
            let title = info[kCGWindowName as String] as? String ?? ""
            let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""
            let isInAX = axIDs.contains(windowID)

            // Filter ghost/helper windows:
            // - On-screen windows: must be in AX set (if we have AX data) to exclude
            //   overlays, tooltips, and helper windows.
            // - Off-screen windows: AX can't see windows on other Spaces, so we can't
            //   use AX filtering. Instead, require a non-empty title — real user windows
            //   always have titles, while ghost windows (toolbars 1800x39, splash screens,
            //   Dock tiles, UI accessories) have empty titles.
            if isInAX {
                // AX confirmed this is a real window — always include
            } else if isOnScreen {
                // On-screen but not in AX — ghost/helper window
                if !axIDs.isEmpty { continue }
            } else {
                // Off-screen and not in AX — require non-empty title
                if title.isEmpty { continue }
            }

            // Determine actual minimized vs other-Space state using AX info
            let isMinimized = !isOnScreen && (axInfo[windowID] ?? false)
            let isOnOtherSpace = !isOnScreen && !isMinimized

            // Filter based on settings
            if !isOnScreen {
                if isMinimized, !includeMinimized { continue }
                if isOnOtherSpace, !includeOtherSpaces { continue }
            }

            windows.append(WindowInfo(
                id: windowID, title: title, bounds: bounds,
                ownerPID: ownerPID, ownerName: ownerName,
                isOnScreen: isOnScreen, isMinimized: isMinimized,
                isOnOtherSpace: isOnOtherSpace,
                thumbnail: nil
            ))
        }

        // Sort: on-screen first, then other Space, then minimized
        windows.sort { a, b in
            let orderA = a.isOnScreen ? 0 : (a.isOnOtherSpace ? 1 : 2)
            let orderB = b.isOnScreen ? 0 : (b.isOnOtherSpace ? 1 : 2)
            return orderA < orderB
        }

        dpLog(
            "Found \(windows.count) windows for PID \(pid) (includeMinimized=\(includeMinimized), includeOtherSpaces=\(includeOtherSpaces), axIDs=\(axIDs.count))"
        )
        return windows
    }

    /// Get a map of CGWindowID → isMinimized for real standard AX windows.
    /// Filters out popups, dialogs, floating panels, overlays (e.g. Chrome translation bar).
    /// Results are cached for 1 second to avoid redundant AX IPC calls.
    private func axWindowInfo(for pid: pid_t) -> [CGWindowID: Bool] {
        stateLock.lock()
        let now = Date()
        if let cached = axWindowInfoCache[pid],
           now.timeIntervalSince(cached.1) < axWindowInfoCacheTTL {
            let info = cached.0
            stateLock.unlock()
            return info
        }
        stateLock.unlock()

        guard let getWindow = _axGetWindow else { return [:] }
        let axApp = AXUIElementCreateApplication(pid)
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let axWindows = ref as? [AXUIElement] else { return [:] }

        var info: [CGWindowID: Bool] = [:]
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
                // Query minimized state from AX
                var minimizedRef: AnyObject?
                AXUIElementCopyAttributeValue(axWin, kAXMinimizedAttribute as CFString, &minimizedRef)
                let isMinimized = (minimizedRef as? Bool) ?? false
                info[wid] = isMinimized
            }
        }

        stateLock.lock()
        axWindowInfoCache[pid] = (info, now)
        stateLock.unlock()
        return info
    }

    // MARK: - Thumbnails

    /// Returns a cached thumbnail synchronously, or nil on cache miss.
    /// This is the fast path — no async work, no capture, no side effects.
    func thumbnail(for windowID: CGWindowID) -> NSImage? {
        let effectiveTTL = isPreviewVisible ? extendedCacheTTL : cacheTTL

        stateLock.lock()
        defer { stateLock.unlock() }

        if let cached = thumbnailCache[windowID],
           Date().timeIntervalSince(cached.timestamp) < effectiveTTL {
            return cached.image
        }

        return nil
    }

    /// Captures thumbnails for multiple windows asynchronously via ScreenCaptureKit.
    /// Calls completion on the main queue with captured images.
    /// Cancels any previously running thumbnail capture task.
    func captureThumbnails(
        for windowIDs: [CGWindowID],
        maxSize: CGFloat = 200,
        completion: @escaping ([CGWindowID: NSImage]) -> Void
    ) {
        activeThumbnailTask?.cancel()
        activeThumbnailTask = Task.detached { [weak self] in
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

            guard !Task.isCancelled else { return }

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

            guard !Task.isCancelled else { return }

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
    /// Cancels any previously running overlay capture task.
    func captureOverlayImage(
        for windowID: CGWindowID,
        bounds: CGRect,
        completion: @escaping (NSImage?) -> Void
    ) {
        activeOverlayTask?.cancel()
        activeOverlayTask = Task.detached { [weak self] in
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

}
