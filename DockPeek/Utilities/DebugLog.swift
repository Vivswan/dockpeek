import Foundation
import os.log

private let logger = Logger(subsystem: "com.dockpeek.app", category: "general")

#if DEBUG
func dpLog(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) {
    let filename = (file as NSString).lastPathComponent
    let msg = message()
    print("[DockPeek] \(filename):\(line) \(msg)")
    logger.debug("\(filename, privacy: .public):\(line) \(msg, privacy: .public)")
}
#else
func dpLog(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) {
    // Use .debug level in release so messages are NOT visible in Console by default.
    // They only appear when explicitly enabled via log(1) or Instruments.
    let msg = message()
    logger.debug("\(msg, privacy: .private)")
}
#endif
