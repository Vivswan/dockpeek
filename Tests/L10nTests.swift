import XCTest

final class L10nTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "appLanguage")
        super.tearDown()
    }

    // MARK: - Language enum

    func testLanguage_displayName_en() {
        XCTAssertEqual(Language.en.displayName, "English")
    }

    func testLanguage_displayName_ko() {
        XCTAssertEqual(Language.ko.displayName, "한국어")
    }

    func testLanguage_allCases() {
        let cases = Language.allCases
        XCTAssertEqual(cases.count, 2)
        XCTAssertTrue(cases.contains(.en))
        XCTAssertTrue(cases.contains(.ko))
    }

    func testLanguage_rawValue() {
        XCTAssertEqual(Language.en.rawValue, "en")
        XCTAssertEqual(Language.ko.rawValue, "ko")
    }

    // MARK: - L10n.current

    func testL10n_currentDefaultsToEnglish() {
        UserDefaults.standard.removeObject(forKey: "appLanguage")
        XCTAssertEqual(L10n.current, .en)
    }
}
