import AppKit

#if !TESTING
    @main
#endif
enum DockPeekMain {
    /// Stored as a static property so the delegate stays alive for the
    /// entire process lifetime. A local variable with `app.delegate = …`
    /// used a weak reference, which could drop the delegate immediately.
    static let appDelegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = appDelegate
        app.run()
    }
}
