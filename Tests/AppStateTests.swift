import XCTest

final class AppStateTests: XCTestCase {

    private var appState: AppState!

    override func setUp() {
        super.setUp()
        resetAppStateDefaults()
        appState = AppState()
    }

    override func tearDown() {
        resetAppStateDefaults()
        appState = nil
        super.tearDown()
    }

    // MARK: - isExcluded (tests parseExcludedIDs indirectly)

    func testIsExcluded_emptyList() {
        appState.excludedBundleIDsRaw = ""
        XCTAssertFalse(appState.isExcluded(bundleID: "com.example.app"))
    }

    func testIsExcluded_singleMatch() {
        appState.excludedBundleIDsRaw = "com.example.app"
        XCTAssertTrue(appState.isExcluded(bundleID: "com.example.app"))
    }

    func testIsExcluded_singleNoMatch() {
        appState.excludedBundleIDsRaw = "com.example.app"
        XCTAssertFalse(appState.isExcluded(bundleID: "com.other.app"))
    }

    func testIsExcluded_multipleEntries() {
        appState.excludedBundleIDsRaw = "com.foo,com.bar,com.baz"
        XCTAssertTrue(appState.isExcluded(bundleID: "com.foo"))
        XCTAssertTrue(appState.isExcluded(bundleID: "com.bar"))
        XCTAssertTrue(appState.isExcluded(bundleID: "com.baz"))
        XCTAssertFalse(appState.isExcluded(bundleID: "com.other"))
    }

    func testIsExcluded_nilBundleID() {
        appState.excludedBundleIDsRaw = "com.example.app"
        XCTAssertFalse(appState.isExcluded(bundleID: nil))
    }

    func testIsExcluded_whitespaceHandling() {
        appState.excludedBundleIDsRaw = " com.foo , com.bar "
        XCTAssertTrue(appState.isExcluded(bundleID: "com.foo"))
        XCTAssertTrue(appState.isExcluded(bundleID: "com.bar"))
    }

    func testIsExcluded_emptySegments() {
        appState.excludedBundleIDsRaw = "com.foo,,com.bar"
        XCTAssertTrue(appState.isExcluded(bundleID: "com.foo"))
        XCTAssertTrue(appState.isExcluded(bundleID: "com.bar"))
        XCTAssertFalse(appState.isExcluded(bundleID: ""))
    }

    func testIsExcluded_cacheUpdatesOnSet() {
        appState.excludedBundleIDsRaw = "com.old"
        XCTAssertTrue(appState.isExcluded(bundleID: "com.old"))

        appState.excludedBundleIDsRaw = "com.new"
        XCTAssertFalse(appState.isExcluded(bundleID: "com.old"))
        XCTAssertTrue(appState.isExcluded(bundleID: "com.new"))
    }

    // MARK: - excludedBundleIDs get/set

    func testExcludedBundleIDs_getEmpty() {
        appState.excludedBundleIDsRaw = ""
        XCTAssertTrue(appState.excludedBundleIDs.isEmpty)
    }

    func testExcludedBundleIDs_getMultiple() {
        appState.excludedBundleIDsRaw = "com.a,com.b,com.c"
        XCTAssertEqual(appState.excludedBundleIDs, ["com.a", "com.b", "com.c"])
    }

    func testExcludedBundleIDs_setUpdatesRaw() {
        appState.excludedBundleIDs = ["com.z", "com.a", "com.m"]
        // Setting sorts alphabetically and joins with ", "
        XCTAssertEqual(appState.excludedBundleIDsRaw, "com.a, com.m, com.z")
    }

    func testExcludedBundleIDs_setEmptySet() {
        appState.excludedBundleIDsRaw = "com.old"
        appState.excludedBundleIDs = []
        XCTAssertEqual(appState.excludedBundleIDsRaw, "")
    }

    // MARK: - Default values

    func testDefaults_thumbnailSize() {
        XCTAssertEqual(appState.thumbnailSize, 200)
    }

    func testDefaults_isEnabled() {
        XCTAssertTrue(appState.isEnabled)
    }
}
