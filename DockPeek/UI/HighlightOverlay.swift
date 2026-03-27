import AppKit

/// Shows the window's actual content at its screen position so the user
/// can identify which window they're about to select.
final class HighlightOverlay {

    private var overlayWindow: NSWindow?
    private(set) var currentID: CGWindowID?
    private var isHiding = false
    private var overlayGeneration = 0

    func show(for windowInfo: WindowInfo) {
        // Skip if already showing for this window
        if currentID == windowInfo.id { return }

        overlayGeneration &+= 1

        // If hide animation is in progress, force-finish it
        if isHiding, let window = overlayWindow {
            window.alphaValue = 0
            window.orderOut(nil)
            overlayWindow = nil
            isHiding = false
        }

        currentID = windowInfo.id

        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        guard screenForCGRect(windowInfo.bounds, primaryH: primaryH) != nil else { return }

        // Convert CG bounds (top-left origin) to Cocoa (bottom-left origin)
        let cocoaRect = NSRect(
            x: windowInfo.bounds.origin.x,
            y: primaryH - windowInfo.bounds.origin.y - windowInfo.bounds.height,
            width: windowInfo.bounds.width,
            height: windowInfo.bounds.height
        )

        let window = makeOrReuseWindow(cocoaRect)
        let container = makeContainer(size: cocoaRect.size, image: nil)
        window.contentView = container

        window.setFrame(cocoaRect, display: true)
        window.alphaValue = 0
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
        }

        overlayWindow = window
    }

    /// Update the overlay with a captured image (called after async capture completes).
    func updateImage(_ image: NSImage) {
        guard let window = overlayWindow else { return }
        let size = window.frame.size
        window.contentView = makeContainer(size: size, image: image)
    }

    func hide() {
        guard let window = overlayWindow, !isHiding else { return }
        isHiding = true
        currentID = nil
        let gen = overlayGeneration
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, overlayGeneration == gen else { return }
            window.orderOut(nil)
            overlayWindow = nil
            isHiding = false
        }
    }

    // MARK: - Private

    private func makeOrReuseWindow(_ frame: NSRect) -> NSWindow {
        if let existing = overlayWindow {
            existing.setFrame(frame, display: false)
            return existing
        }
        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .popUpMenu - 1
        window.ignoresMouseEvents = true
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return window
    }

    private func makeContainer(size: NSSize, image: NSImage?) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.masksToBounds = true
        container.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        container.layer?.borderWidth = 3

        if let image {
            let imgLayer = CALayer()
            imgLayer.frame = NSRect(origin: .zero, size: size)
            imgLayer.contents = image
            imgLayer.contentsGravity = .resizeAspect
            container.layer?.addSublayer(imgLayer)
        } else {
            container.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        }

        return container
    }

    private func screenForCGRect(_ rect: CGRect, primaryH: CGFloat? = nil) -> NSScreen? {
        let pH = primaryH ?? NSScreen.screens.first?.frame.height ?? 0
        let cocoaRect = NSRect(
            x: rect.origin.x,
            y: pH - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
        for screen in NSScreen.screens {
            if screen.frame.intersects(cocoaRect) {
                return screen
            }
        }
        return NSScreen.screens.first
    }
}
