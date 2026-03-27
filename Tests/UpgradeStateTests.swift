import XCTest

final class UpgradeStateTests: XCTestCase {

    // MARK: - Same-case equality

    func testIdle_equality() {
        XCTAssertEqual(UpgradeState.idle, UpgradeState.idle)
    }

    func testDownloading_equalProgress() {
        XCTAssertEqual(UpgradeState.downloading(0.5), UpgradeState.downloading(0.5))
    }

    func testCompleted_equality() {
        XCTAssertEqual(UpgradeState.completed, UpgradeState.completed)
    }

    func testFailed_equalMessage() {
        XCTAssertEqual(UpgradeState.failed("error"), UpgradeState.failed("error"))
    }

    // MARK: - Inequality

    func testDownloading_differentProgress() {
        XCTAssertNotEqual(UpgradeState.downloading(0.5), UpgradeState.downloading(0.7))
    }

    func testFailed_differentMessage() {
        XCTAssertNotEqual(UpgradeState.failed("error A"), UpgradeState.failed("error B"))
    }

    func testDifferentCases_notEqual() {
        XCTAssertNotEqual(UpgradeState.idle, UpgradeState.completed)
        XCTAssertNotEqual(UpgradeState.downloading(0), UpgradeState.completed)
        XCTAssertNotEqual(UpgradeState.idle, UpgradeState.failed(""))
        XCTAssertNotEqual(UpgradeState.downloading(1.0), UpgradeState.failed("done"))
    }
}
