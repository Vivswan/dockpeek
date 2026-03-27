import XCTest

final class DiagnosticReportTests: XCTestCase {

    func testReport_textJoinsLines() {
        let report = DiagnosticChecker.Report(lines: ["line1", "line2", "line3"])
        XCTAssertEqual(report.text, "line1\nline2\nline3")
    }

    func testReport_emptyLines() {
        let report = DiagnosticChecker.Report(lines: [])
        XCTAssertEqual(report.text, "")
    }

    func testReport_singleLine() {
        let report = DiagnosticChecker.Report(lines: ["only line"])
        XCTAssertEqual(report.text, "only line")
    }
}
