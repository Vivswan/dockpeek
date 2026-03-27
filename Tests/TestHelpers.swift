import AppKit
import XCTest

// MARK: - Factory Helpers

func makeWindowInfo(
    id: CGWindowID = 1,
    title: String = "Test Window",
    bounds: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
    ownerPID: pid_t = 123,
    ownerName: String = "TestApp",
    isOnScreen: Bool = true,
    isMinimized: Bool = false,
    isOnOtherSpace: Bool = false,
    thumbnail: NSImage? = nil
) -> WindowInfo {
    WindowInfo(
        id: id,
        title: title,
        bounds: bounds,
        ownerPID: ownerPID,
        ownerName: ownerName,
        isOnScreen: isOnScreen,
        isMinimized: isMinimized,
        isOnOtherSpace: isOnOtherSpace,
        thumbnail: thumbnail
    )
}

// MARK: - UserDefaults Cleanup

/// All AppState @AppStorage keys — remove between tests to isolate state.
private let appStateDefaultsKeys = [
    "isEnabled",
    "thumbnailSize",
    "showWindowTitles",
    "livePreviewOnHover",
    "launchAtLogin",
    "forceNewWindowsToPrimary",
    "previewOnHover",
    "hoverDelay",
    "excludedBundleIDs",
    "appLanguage",
    "autoUpdateEnabled",
    "updateCheckInterval",
    "showSnapButtons",
    "showCloseButton",
    "showMinimizedWindows",
    "showOtherSpaceWindows"
]

func resetAppStateDefaults() {
    for key in appStateDefaultsKeys {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
