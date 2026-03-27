import XCTest

final class DockAppTests: XCTestCase {

    func testInit_withAllFields() {
        let app = DockApp(
            bundleIdentifier: "com.apple.safari",
            name: "Safari",
            pid: 1234,
            isRunning: true
        )
        XCTAssertEqual(app.bundleIdentifier, "com.apple.safari")
        XCTAssertEqual(app.name, "Safari")
        XCTAssertEqual(app.pid, 1234)
        XCTAssertTrue(app.isRunning)
    }

    func testInit_nilBundleIdentifier() {
        let app = DockApp(bundleIdentifier: nil, name: "Unknown", pid: 42, isRunning: true)
        XCTAssertNil(app.bundleIdentifier)
        XCTAssertEqual(app.name, "Unknown")
    }

    func testInit_nilPID() {
        let app = DockApp(bundleIdentifier: "com.example.app", name: "Example", pid: nil, isRunning: false)
        XCTAssertNil(app.pid)
        XCTAssertFalse(app.isRunning)
    }

    func testInit_notRunning() {
        let app = DockApp(bundleIdentifier: "com.example.app", name: "App", pid: nil, isRunning: false)
        XCTAssertFalse(app.isRunning)
    }
}
