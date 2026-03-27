import AppKit
import XCTest

final class WindowInfoTests: XCTestCase {

    // MARK: - displayTitle

    func testDisplayTitle_withTitle() {
        let info = makeWindowInfo(title: "My Document", ownerName: "TextEdit")
        XCTAssertEqual(info.displayTitle, "My Document")
    }

    func testDisplayTitle_emptyTitle_fallsBackToOwnerName() {
        let info = makeWindowInfo(title: "", ownerName: "Finder")
        XCTAssertEqual(info.displayTitle, "Finder")
    }

    // MARK: - Equatable

    func testEquality_sameValues() {
        let img = NSImage()
        let a = makeWindowInfo(id: 1, title: "T", thumbnail: img)
        let b = makeWindowInfo(id: 1, title: "T", thumbnail: img)
        XCTAssertEqual(a, b)
    }

    func testEquality_differentID() {
        let a = makeWindowInfo(id: 1)
        let b = makeWindowInfo(id: 2)
        XCTAssertNotEqual(a, b)
    }

    func testEquality_differentTitle() {
        let a = makeWindowInfo(title: "A")
        let b = makeWindowInfo(title: "B")
        XCTAssertNotEqual(a, b)
    }

    func testEquality_differentBounds() {
        let a = makeWindowInfo(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let b = makeWindowInfo(bounds: CGRect(x: 10, y: 10, width: 100, height: 100))
        XCTAssertNotEqual(a, b)
    }

    func testEquality_differentPID() {
        let a = makeWindowInfo(ownerPID: 100)
        let b = makeWindowInfo(ownerPID: 200)
        XCTAssertNotEqual(a, b)
    }

    func testEquality_differentOnScreen() {
        let a = makeWindowInfo(isOnScreen: true)
        let b = makeWindowInfo(isOnScreen: false)
        XCTAssertNotEqual(a, b)
    }

    func testEquality_differentMinimized() {
        let a = makeWindowInfo(isMinimized: false)
        let b = makeWindowInfo(isMinimized: true)
        XCTAssertNotEqual(a, b)
    }

    func testEquality_differentOtherSpace() {
        let a = makeWindowInfo(isOnOtherSpace: false)
        let b = makeWindowInfo(isOnOtherSpace: true)
        XCTAssertNotEqual(a, b)
    }

    func testEquality_thumbnailIdentity() {
        let img1 = NSImage(size: NSSize(width: 10, height: 10))
        let img2 = NSImage(size: NSSize(width: 10, height: 10))

        let a = makeWindowInfo(thumbnail: img1)
        let b = makeWindowInfo(thumbnail: img1) // same instance
        let c = makeWindowInfo(thumbnail: img2) // different instance

        XCTAssertEqual(a, b, "Same NSImage instance should be equal (=== check)")
        XCTAssertNotEqual(a, c, "Different NSImage instances should not be equal (=== check)")
    }

    func testEquality_bothThumbnailsNil() {
        let a = makeWindowInfo(thumbnail: nil)
        let b = makeWindowInfo(thumbnail: nil)
        XCTAssertEqual(a, b)
    }
}
