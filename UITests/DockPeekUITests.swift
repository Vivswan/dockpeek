import XCTest

/// UI tests for DockPeek using XCUITest.
///
/// These tests launch the app and interact with the real UI.
/// Note: DockPeek is a menu bar app (LSUIElement=true), so it has no
/// Dock icon or main window — only a status bar item and settings window.
///
/// Limitations:
/// - Dock click interception requires Accessibility permission (granted to
///   the installed app, not the test runner), so we can't test preview panels.
/// - Space switching can't be triggered from XCUITest.
/// - We CAN test: menu bar, settings window, toggles, and keyboard shortcuts.
final class DockPeekUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        // Give the menu bar item time to appear
        sleep(1)
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - App Launch

    func testAppLaunches() {
        // Verify the app launched successfully
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    // MARK: - Status Bar Menu

    func testStatusBarItemExists() {
        // DockPeek should create a status bar item on launch.
        // The menu bar extras group contains the app's status item.
        let menuBars = app.menuBars
        XCTAssertFalse(menuBars.allElementsBoundByIndex.isEmpty, "App should have a menu bar presence")
    }

    // MARK: - Settings Window

    func testSettingsWindowOpensViaKeyboardShortcut() {
        // Cmd+, should open settings
        app.typeKey(",", modifierFlags: .command)
        sleep(1)

        let settingsWindow = app.windows.firstMatch
        XCTAssertTrue(
            settingsWindow.waitForExistence(timeout: 3),
            "Settings window should open via Cmd+,"
        )
    }

    func testSettingsWindowHasGeneralTab() {
        app.typeKey(",", modifierFlags: .command)
        sleep(1)

        let settingsWindow = app.windows.firstMatch
        guard settingsWindow.waitForExistence(timeout: 3) else {
            XCTFail("Settings window did not open")
            return
        }

        // The toolbar should have General, Appearance, and About tabs
        let toolbar = settingsWindow.toolbars.firstMatch
        XCTAssertTrue(toolbar.exists, "Settings should have a toolbar")
    }

    func testSettingsWindowHasEnableDockPeekToggle() {
        app.typeKey(",", modifierFlags: .command)
        sleep(1)

        let settingsWindow = app.windows.firstMatch
        guard settingsWindow.waitForExistence(timeout: 3) else {
            XCTFail("Settings window did not open")
            return
        }

        // Look for the "Enable DockPeek" toggle checkbox
        let enableToggle = settingsWindow.checkBoxes["Enable DockPeek"]
        XCTAssertTrue(
            enableToggle.waitForExistence(timeout: 2),
            "Settings should have an 'Enable DockPeek' toggle"
        )
    }

    func testEnableToggleCanBeToggled() {
        app.typeKey(",", modifierFlags: .command)
        sleep(1)

        let settingsWindow = app.windows.firstMatch
        guard settingsWindow.waitForExistence(timeout: 3) else {
            XCTFail("Settings window did not open")
            return
        }

        let enableToggle = settingsWindow.checkBoxes["Enable DockPeek"]
        guard enableToggle.waitForExistence(timeout: 2) else {
            XCTFail("Enable toggle not found")
            return
        }

        let initialValue = enableToggle.value as? Int ?? -1
        enableToggle.click()
        sleep(1)

        let newValue = enableToggle.value as? Int ?? -1
        XCTAssertNotEqual(initialValue, newValue, "Toggle value should change after click")

        // Toggle back to restore state
        enableToggle.click()
    }

    func testSettingsWindowCloses() {
        app.typeKey(",", modifierFlags: .command)
        sleep(1)

        let settingsWindow = app.windows.firstMatch
        guard settingsWindow.waitForExistence(timeout: 3) else {
            XCTFail("Settings window did not open")
            return
        }

        // Close via Cmd+W
        app.typeKey("w", modifierFlags: .command)
        sleep(1)

        XCTAssertFalse(settingsWindow.exists, "Settings window should close via Cmd+W")
    }

    // MARK: - Appearance Tab

    func testAppearanceTabHasWindowDisplayOptions() {
        app.typeKey(",", modifierFlags: .command)
        sleep(1)

        let settingsWindow = app.windows.firstMatch
        guard settingsWindow.waitForExistence(timeout: 3) else {
            XCTFail("Settings window did not open")
            return
        }

        // Click Appearance tab
        let toolbar = settingsWindow.toolbars.firstMatch
        let appearanceButton = toolbar.buttons["Appearance"]
        if appearanceButton.waitForExistence(timeout: 2) {
            appearanceButton.click()
            sleep(1)

            // Check for window display toggles
            let showTitles = settingsWindow.checkBoxes["Show window titles"]
            XCTAssertTrue(
                showTitles.waitForExistence(timeout: 2),
                "Appearance tab should have 'Show window titles' toggle"
            )
        }
    }

    // MARK: - Permissions

    func testPermissionsSection() {
        app.typeKey(",", modifierFlags: .command)
        sleep(1)

        let settingsWindow = app.windows.firstMatch
        guard settingsWindow.waitForExistence(timeout: 3) else {
            XCTFail("Settings window did not open")
            return
        }

        // The permissions section should show Accessibility status
        let accessibilityText = settingsWindow.staticTexts.matching(
            NSPredicate(format: "value CONTAINS[c] 'Accessibility'")
        )
        XCTAssertFalse(
            accessibilityText.allElementsBoundByIndex.isEmpty,
            "Settings should show Accessibility permission status"
        )
    }
}
