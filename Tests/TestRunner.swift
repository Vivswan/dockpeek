import XCTest

@main
enum TestRunner {
    static func main() {
        let suite = XCTestSuite.default
        suite.run()

        guard let run = suite.testRun else {
            print("No test run produced")
            exit(1)
        }

        let total = run.testCaseCount
        let failures = Int(run.failureCount)
        let errors = Int(run.unexpectedExceptionCount)
        let passed = total - failures - errors

        print("")
        print("=== Test Results ===")
        print("Ran: \(total)  Passed: \(passed)  Failed: \(failures)  Errors: \(errors)")

        exit(failures + errors > 0 ? 1 : 0)
    }
}
