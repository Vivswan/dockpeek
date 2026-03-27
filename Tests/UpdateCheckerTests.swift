import XCTest

final class UpdateCheckerTests: XCTestCase {

    // MARK: - compareVersions

    func testCompare_majorGreater() {
        XCTAssertTrue(UpdateChecker.compareVersions("2.0.0", isGreaterThan: "1.0.0"))
    }

    func testCompare_majorLess() {
        XCTAssertFalse(UpdateChecker.compareVersions("1.0.0", isGreaterThan: "2.0.0"))
    }

    func testCompare_minorGreater() {
        XCTAssertTrue(UpdateChecker.compareVersions("1.2.0", isGreaterThan: "1.1.0"))
    }

    func testCompare_minorLess() {
        XCTAssertFalse(UpdateChecker.compareVersions("1.1.0", isGreaterThan: "1.2.0"))
    }

    func testCompare_patchGreater() {
        XCTAssertTrue(UpdateChecker.compareVersions("1.0.2", isGreaterThan: "1.0.1"))
    }

    func testCompare_patchLess() {
        XCTAssertFalse(UpdateChecker.compareVersions("1.0.1", isGreaterThan: "1.0.2"))
    }

    func testCompare_equal() {
        XCTAssertFalse(UpdateChecker.compareVersions("1.2.3", isGreaterThan: "1.2.3"))
    }

    func testCompare_missingPatch_treatedAsZero() {
        // "1.2" is equivalent to "1.2.0" — should return false (equal)
        XCTAssertFalse(UpdateChecker.compareVersions("1.2", isGreaterThan: "1.2.0"))
        XCTAssertFalse(UpdateChecker.compareVersions("1.2.0", isGreaterThan: "1.2"))
    }

    func testCompare_shorterVersionGreater() {
        // "2" is equivalent to "2.0.0" — greater than "1.9.9"
        XCTAssertTrue(UpdateChecker.compareVersions("2", isGreaterThan: "1.9.9"))
    }

    func testCompare_longerVersionGreater() {
        // "1.0.0.1" > "1.0.0" (extra segment > 0)
        XCTAssertTrue(UpdateChecker.compareVersions("1.0.0.1", isGreaterThan: "1.0.0"))
    }

    func testCompare_zeroVersions() {
        XCTAssertFalse(UpdateChecker.compareVersions("0.0.0", isGreaterThan: "0.0.0"))
    }

    func testCompare_largeNumbers() {
        XCTAssertTrue(UpdateChecker.compareVersions("10.20.30", isGreaterThan: "10.20.29"))
        XCTAssertFalse(UpdateChecker.compareVersions("10.20.29", isGreaterThan: "10.20.30"))
    }

    func testCompare_singleDigit() {
        XCTAssertTrue(UpdateChecker.compareVersions("2", isGreaterThan: "1"))
        XCTAssertFalse(UpdateChecker.compareVersions("1", isGreaterThan: "2"))
    }

    func testCompare_emptyString() {
        // Empty string → no parts → all zeros
        XCTAssertFalse(UpdateChecker.compareVersions("", isGreaterThan: "1.0.0"))
        XCTAssertTrue(UpdateChecker.compareVersions("1.0.0", isGreaterThan: ""))
    }

    func testCompare_nonNumericParts() {
        // compactMap { Int($0) } filters out non-numeric segments
        // "1.0.a" → [1, 0], "1.0.1" → [1, 0, 1]
        XCTAssertFalse(UpdateChecker.compareVersions("1.0.a", isGreaterThan: "1.0.1"))
    }

    func testCompare_veryLongVersion() {
        XCTAssertTrue(UpdateChecker.compareVersions("1.2.3.4.5.6", isGreaterThan: "1.2.3.4.5.5"))
        XCTAssertFalse(UpdateChecker.compareVersions("1.2.3.4.5.5", isGreaterThan: "1.2.3.4.5.6"))
    }

    // MARK: - intervalForSetting

    func testInterval_daily() {
        let interval = UpdateChecker.intervalForSetting("daily")
        XCTAssertEqual(interval, 24 * 60 * 60)
    }

    func testInterval_weekly() {
        let interval = UpdateChecker.intervalForSetting("weekly")
        XCTAssertEqual(interval, 7 * 24 * 60 * 60)
    }

    func testInterval_manual() {
        XCTAssertNil(UpdateChecker.intervalForSetting("manual"))
    }

    func testInterval_unknown() {
        XCTAssertNil(UpdateChecker.intervalForSetting("monthly"))
    }

    func testInterval_emptyString() {
        XCTAssertNil(UpdateChecker.intervalForSetting(""))
    }
}
