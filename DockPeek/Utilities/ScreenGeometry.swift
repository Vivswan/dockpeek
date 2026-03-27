import AppKit
import ApplicationServices

/// Shared utilities for CG ↔ Cocoa coordinate conversion.
///
/// macOS uses two coordinate systems:
/// - **CG (Core Graphics):** origin at top-left of the primary screen, Y increases downward
/// - **Cocoa (AppKit):** origin at bottom-left of the primary screen, Y increases upward
///
/// Converting between them requires the primary screen height. This is always
/// `NSScreen.screens.first?.frame.height` — CG's origin is defined relative to the primary.
enum ScreenGeometry {

    /// Cached height of the primary screen in points.
    /// Updated on screen-change notifications; avoids hitting NSScreen.screens
    /// on every call (~15x/sec during active hover polling).
    private static var cachedHeight: CGFloat = NSScreen.screens.first?.frame.height ?? 900

    /// Height of the primary screen in points. Returns a safe default of 900
    /// if no screens are available (headless/test contexts).
    static var primaryScreenHeight: CGFloat { cachedHeight }

    /// Re-read the primary screen height. Call from the screen-change observer.
    static func invalidateCache() {
        cachedHeight = NSScreen.screens.first?.frame.height ?? 900
    }

    /// Convert a CG point (top-left origin) to a Cocoa point (bottom-left origin).
    static func cgToCocoa(_ point: CGPoint) -> NSPoint {
        NSPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// Convert a Cocoa point (bottom-left origin) to a CG point (top-left origin).
    static func cocoaToCG(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }
}

// MARK: - Safe CF Type Casts

/// Safely cast an AnyObject to AXUIElement by checking CFGetTypeID first.
/// Returns nil if the object is not actually an AXUIElement.
func asAXUIElement(_ ref: AnyObject) -> AXUIElement? {
    guard CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
    return (ref as! AXUIElement)
}

/// Safely cast an AnyObject to AXValue by checking CFGetTypeID first.
/// Returns nil if the object is not actually an AXValue.
func asAXValue(_ ref: AnyObject) -> AXValue? {
    guard CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
    return (ref as! AXValue)
}
