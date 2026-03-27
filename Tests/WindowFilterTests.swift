import AppKit
import XCTest

// MARK: - CG Dictionary Helpers

/// Build a fake CGWindowListCopyWindowInfo dictionary entry.
private func makeCGWindow(
    id: CGWindowID,
    pid: pid_t,
    title: String? = "Window",
    ownerName: String = "TestApp",
    layer: Int = 0,
    width: CGFloat = 800,
    height: CGFloat = 600,
    alpha: Double = 1.0,
    isOnScreen: Bool = true
) -> [String: Any] {
    var info: [String: Any] = [
        kCGWindowNumber as String: id,
        kCGWindowOwnerPID as String: pid,
        kCGWindowOwnerName as String: ownerName,
        kCGWindowLayer as String: layer,
        kCGWindowAlpha as String: alpha,
        kCGWindowIsOnscreen as String: isOnScreen,
        kCGWindowBounds as String: [
            "X": 0, "Y": 0,
            "Width": width, "Height": height
        ] as [String: Any]
    ]
    // Only include kCGWindowName if title is non-nil
    // (simulates real CG behavior where ghost windows may lack this key)
    if let title {
        info[kCGWindowName as String] = title
    }
    return info
}

// MARK: - Ghost Window Filtering Tests

final class WindowFilterTests: XCTestCase {

    let testPID: pid_t = 1234

    // MARK: - Bug 1: Ghost window filtering

    func testFilter_deduplicatesByWindowID() {
        // Same windowID appearing twice in CG list
        let list = [
            makeCGWindow(id: 100, pid: testPID, title: "Window A"),
            makeCGWindow(id: 100, pid: testPID, title: "Window A") // duplicate
        ]
        let axInfo: [CGWindowID: Bool] = [100: false]

        let result = WindowManager.filterWindows(
            from: list, pid: testPID, axInfo: axInfo,
            includeMinimized: false, includeOtherSpaces: false
        )

        XCTAssertEqual(result.count, 1, "Duplicate windowIDs should be deduplicated")
        XCTAssertEqual(result.first?.id, 100)
    }

    func testFilter_offScreenEmptyTitle_filteredOutWhenNotInAX() {
        // Ghost windows: off-screen, empty title, not in AX set
        // These are toolbar bars (1800x39), splash screens (500x500), etc.
        let list = [
            makeCGWindow(id: 100, pid: testPID, title: "Real Window", isOnScreen: true),
            makeCGWindow(id: 200, pid: testPID, title: "", width: 1800, height: 39, isOnScreen: false), // toolbar ghost
            makeCGWindow(id: 201, pid: testPID, title: "", width: 500, height: 500, isOnScreen: false), // splash ghost
            makeCGWindow(id: 202, pid: testPID, title: "", width: 64, height: 64, isOnScreen: false) // dock tile ghost
        ]
        let axInfo: [CGWindowID: Bool] = [100: false]

        let result = WindowManager.filterWindows(
            from: list, pid: testPID, axInfo: axInfo,
            includeMinimized: false, includeOtherSpaces: true
        )

        XCTAssertEqual(result.count, 1, "Ghost windows with empty titles should be filtered")
        XCTAssertEqual(result.first?.title, "Real Window")
    }

    func testFilter_offScreenWithTitle_includedAsOtherSpace() {
        // Real window on another Space: off-screen, has title, not in AX
        let list = [
            makeCGWindow(id: 100, pid: testPID, title: "Editor", isOnScreen: true),
            makeCGWindow(id: 200, pid: testPID, title: "Chat | Teams", isOnScreen: false)
        ]
        let axInfo: [CGWindowID: Bool] = [100: false]

        let result = WindowManager.filterWindows(
            from: list, pid: testPID, axInfo: axInfo,
            includeMinimized: false, includeOtherSpaces: true
        )

        XCTAssertEqual(result.count, 2, "Off-screen windows with titles should be included")
        XCTAssertTrue(result[1].isOnOtherSpace)
        XCTAssertEqual(result[1].title, "Chat | Teams")
    }

    func testFilter_offScreenWithTitle_excludedWhenOtherSpacesDisabled() {
        let list = [
            makeCGWindow(id: 100, pid: testPID, title: "Editor", isOnScreen: true),
            makeCGWindow(id: 200, pid: testPID, title: "Chat | Teams", isOnScreen: false)
        ]
        let axInfo: [CGWindowID: Bool] = [100: false]

        let result = WindowManager.filterWindows(
            from: list, pid: testPID, axInfo: axInfo,
            includeMinimized: false, includeOtherSpaces: false
        )

        XCTAssertEqual(result.count, 1, "Other-space windows excluded when setting is off")
    }

    func testFilter_onScreenNotInAX_filteredWhenAXHasData() {
        // On-screen window not in AX set = overlay/helper (e.g. Chrome translation bar)
        let list = [
            makeCGWindow(id: 100, pid: testPID, title: "Real", isOnScreen: true),
            makeCGWindow(id: 200, pid: testPID, title: "Overlay", isOnScreen: true)
        ]
        let axInfo: [CGWindowID: Bool] = [100: false] // Only 100 in AX

        let result = WindowManager.filterWindows(
            from: list, pid: testPID, axInfo: axInfo,
            includeMinimized: false, includeOtherSpaces: false
        )

        XCTAssertEqual(result.count, 1, "On-screen windows not in AX should be filtered")
        XCTAssertEqual(result.first?.id, 100)
    }

    func testFilter_onScreenNotInAX_keptWhenAXEmpty() {
        // When AX returns nothing (e.g. app just launched), keep all on-screen windows
        let list = [
            makeCGWindow(id: 100, pid: testPID, title: "Window", isOnScreen: true)
        ]
        let axInfo: [CGWindowID: Bool] = [:] // Empty AX

        let result = WindowManager.filterWindows(
            from: list, pid: testPID, axInfo: axInfo,
            includeMinimized: false, includeOtherSpaces: false
        )

        XCTAssertEqual(result.count, 1, "On-screen windows should be kept when AX is empty")
    }

    func testFilter_inAX_alwaysIncluded() {
        // Windows confirmed by AX are always included regardless of other heuristics
        let list = [
            makeCGWindow(id: 100, pid: testPID, title: "Normal", isOnScreen: false)
        ]
        let axInfo: [CGWindowID: Bool] = [100: true] // AX says minimized

        let result = WindowManager.filterWindows(
            from: list, pid: testPID, axInfo: axInfo,
            includeMinimized: true, includeOtherSpaces: true
        )

        XCTAssertEqual(result.count, 1, "Windows in AX set should always be included")
        XCTAssertTrue(result.first?.isMinimized == true)
    }

    func testFilter_allGhostsOnOtherSpace_noneShown() {
        // All windows on other space, all empty titles (the iTerm ghost scenario)
        let list = [
            makeCGWindow(id: 200, pid: testPID, title: "", width: 1800, height: 39, isOnScreen: false),
            makeCGWindow(id: 201, pid: testPID, title: "", width: 1800, height: 39, isOnScreen: false),
            makeCGWindow(id: 202, pid: testPID, title: "", width: 1800, height: 39, isOnScreen: false),
            makeCGWindow(id: 203, pid: testPID, title: "", width: 1800, height: 39, isOnScreen: false)
        ]
        let axInfo: [CGWindowID: Bool] = [:] // AX can't see other-space windows

        let result = WindowManager.filterWindows(
            from: list, pid: testPID, axInfo: axInfo,
            includeMinimized: true, includeOtherSpaces: true
        )

        XCTAssertEqual(result.count, 0, "Ghost windows with empty titles should all be filtered")
    }

    func testFilter_realWindowAmongGhosts_onlyRealShown() {
        // One real window + ghost toolbars on another space (the real iTerm scenario)
        let list = [
            makeCGWindow(id: 100, pid: testPID, title: "user@host:~", isOnScreen: false),
            makeCGWindow(id: 200, pid: testPID, title: "", width: 1800, height: 39, isOnScreen: false),
            makeCGWindow(id: 201, pid: testPID, title: "", width: 1800, height: 39, isOnScreen: false),
            makeCGWindow(id: 202, pid: testPID, title: "", width: 1800, height: 39, isOnScreen: false),
            makeCGWindow(id: 203, pid: testPID, title: "", width: 1800, height: 39, isOnScreen: false)
        ]
        let axInfo: [CGWindowID: Bool] = [:] // AX can't see other-space windows

        let result = WindowManager.filterWindows(
            from: list, pid: testPID, axInfo: axInfo,
            includeMinimized: true, includeOtherSpaces: true
        )

        XCTAssertEqual(result.count, 1, "Only the real window with title should pass")
        XCTAssertEqual(result.first?.title, "user@host:~")
    }

    // MARK: - Sorting

    func testFilter_sortOrder_onScreenFirst() {
        let list = [
            makeCGWindow(id: 200, pid: testPID, title: "Other Space", isOnScreen: false),
            makeCGWindow(id: 100, pid: testPID, title: "Current", isOnScreen: true)
        ]
        let axInfo: [CGWindowID: Bool] = [100: false]

        let result = WindowManager.filterWindows(
            from: list, pid: testPID, axInfo: axInfo,
            includeMinimized: true, includeOtherSpaces: true
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].isOnScreen, "On-screen windows should sort first")
        XCTAssertTrue(result[1].isOnOtherSpace, "Other-space windows should sort after")
    }

    // MARK: - PID filtering

    func testFilter_ignoresWindowsFromOtherPIDs() {
        let list = [
            makeCGWindow(id: 100, pid: testPID, title: "Mine"),
            makeCGWindow(id: 200, pid: 9999, title: "Other App")
        ]
        let axInfo: [CGWindowID: Bool] = [100: false]

        let result = WindowManager.filterWindows(
            from: list, pid: testPID, axInfo: axInfo,
            includeMinimized: false, includeOtherSpaces: false
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.ownerPID, testPID)
    }

    // MARK: - Basic CG filters

    func testFilter_ignoresNonZeroLayer() {
        let list = [
            makeCGWindow(id: 100, pid: testPID, title: "Normal", layer: 0),
            makeCGWindow(id: 200, pid: testPID, title: "Menu Bar", layer: 25)
        ]
        let axInfo: [CGWindowID: Bool] = [100: false, 200: false]

        let result = WindowManager.filterWindows(
            from: list, pid: testPID, axInfo: axInfo,
            includeMinimized: false, includeOtherSpaces: false
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.title, "Normal")
    }

    func testFilter_ignoresZeroAlpha() {
        let list = [
            makeCGWindow(id: 100, pid: testPID, title: "Visible"),
            makeCGWindow(id: 200, pid: testPID, title: "Invisible", alpha: 0.0)
        ]
        let axInfo: [CGWindowID: Bool] = [100: false, 200: false]

        let result = WindowManager.filterWindows(
            from: list, pid: testPID, axInfo: axInfo,
            includeMinimized: false, includeOtherSpaces: false
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.title, "Visible")
    }

    func testFilter_ignoresTooSmallBounds() {
        let list = [
            makeCGWindow(id: 100, pid: testPID, title: "Normal"),
            makeCGWindow(id: 200, pid: testPID, title: "Tiny", width: 1, height: 1)
        ]
        let axInfo: [CGWindowID: Bool] = [100: false, 200: false]

        let result = WindowManager.filterWindows(
            from: list, pid: testPID, axInfo: axInfo,
            includeMinimized: false, includeOtherSpaces: false
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.title, "Normal")
    }
}
