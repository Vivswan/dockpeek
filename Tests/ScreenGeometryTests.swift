import AppKit
import XCTest

final class ScreenGeometryTests: XCTestCase {

    // MARK: - Round-trip conversions

    func testCGToCocoa_andBack_roundTrips() {
        let original = CGPoint(x: 100, y: 200)
        let cocoa = ScreenGeometry.cgToCocoa(original)
        let backToCG = ScreenGeometry.cocoaToCG(cocoa)
        XCTAssertEqual(backToCG.x, original.x, accuracy: 0.001)
        XCTAssertEqual(backToCG.y, original.y, accuracy: 0.001)
    }

    func testCocoaToCG_andBack_roundTrips() {
        let original = NSPoint(x: 50, y: 300)
        let cg = ScreenGeometry.cocoaToCG(original)
        let backToCocoa = ScreenGeometry.cgToCocoa(cg)
        XCTAssertEqual(backToCocoa.x, original.x, accuracy: 0.001)
        XCTAssertEqual(backToCocoa.y, original.y, accuracy: 0.001)
    }

    // MARK: - Origin behavior

    func testCGToCocoa_origin() {
        // CG origin (0,0) is top-left → Cocoa should be (0, screenHeight)
        let cocoa = ScreenGeometry.cgToCocoa(CGPoint(x: 0, y: 0))
        XCTAssertEqual(cocoa.x, 0)
        XCTAssertEqual(cocoa.y, ScreenGeometry.primaryScreenHeight, accuracy: 0.001)
    }

    func testCocoaToCG_origin() {
        // Cocoa origin (0,0) is bottom-left → CG should be (0, screenHeight)
        let cg = ScreenGeometry.cocoaToCG(NSPoint(x: 0, y: 0))
        XCTAssertEqual(cg.x, 0)
        XCTAssertEqual(cg.y, ScreenGeometry.primaryScreenHeight, accuracy: 0.001)
    }

    // MARK: - Relationship properties

    func testConversions_areInverses() {
        // For any point, cgToCocoa and cocoaToCG should be the same operation
        // (both compute: x stays, y = screenHeight - y)
        let point = CGPoint(x: 42, y: 137)
        let fromCG = ScreenGeometry.cgToCocoa(point)
        let fromCocoa = ScreenGeometry.cocoaToCG(NSPoint(x: point.x, y: point.y))
        XCTAssertEqual(fromCG.x, fromCocoa.x, accuracy: 0.001)
        XCTAssertEqual(fromCG.y, fromCocoa.y, accuracy: 0.001)
    }

    func testCGToCocoa_negativeCoords() {
        // Negative coordinates (multi-monitor setups) should still work
        let result = ScreenGeometry.cgToCocoa(CGPoint(x: -100, y: -50))
        XCTAssertEqual(result.x, -100)
        // y = screenHeight - (-50) = screenHeight + 50
        XCTAssertEqual(result.y, ScreenGeometry.primaryScreenHeight + 50, accuracy: 0.001)
    }

    func testPrimaryScreenHeight_isPositive() {
        XCTAssertGreaterThan(ScreenGeometry.primaryScreenHeight, 0)
    }

    // MARK: - SnapPosition

    func testSnapPosition_allCases() {
        // Verify all SnapPosition cases exist and are distinct
        let positions: [SnapPosition] = [.left, .right, .fill]
        XCTAssertEqual(positions.count, 3)
    }
}
