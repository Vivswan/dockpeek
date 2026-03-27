import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, EventTapManagerDelegate, NSWindowDelegate {

    // MARK: - Core dependencies

    private let appState = AppState()
    private let eventTapManager = EventTapManager()
    private let dockInspector = DockAXInspector()
    private let windowManager = WindowManager()
    private let previewPanel = PreviewPanel()
    private let highlightOverlay = HighlightOverlay()

    // MARK: - Controllers (created in applicationDidFinishLaunching)

    private var hoverController: HoverPreviewController!
    private var screenEnforcer: PrimaryScreenEnforcer!
    private var previewCoordinator: PreviewCoordinator!

    // MARK: - UI state

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var settingsWindowController: SettingsWindowController?
    private let updateChecker = UpdateChecker.shared
    private var lastClickTime: Date = .distantPast
    private let debounceInterval: TimeInterval = 0.3
    private var accessibilityTimer: Timer?
    private var permissionMonitorTimer: Timer?
    private var cmdCommaMonitor: Any?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create controllers
        hoverController = HoverPreviewController(
            appState: appState,
            dockInspector: dockInspector,
            windowManager: windowManager,
            previewPanel: previewPanel,
            highlightOverlay: highlightOverlay
        )
        screenEnforcer = PrimaryScreenEnforcer(appState: appState)
        previewCoordinator = PreviewCoordinator(
            appState: appState,
            windowManager: windowManager,
            previewPanel: previewPanel,
            highlightOverlay: highlightOverlay
        )

        // Wire cross-controller communication
        hoverController.showPreview = { [weak self] windows, point in
            self?.previewCoordinator.showPreviewForWindows(windows, at: point)
        }
        previewCoordinator.onPreviewVisibilityChanged = { [weak self] visible in
            self?.hoverController.previewIsVisible = visible
        }

        // Clean up backup from a previous successful update
        UpdateChecker.shared.cleanupPendingBackup()

        setupStatusItem()
        setupCmdCommaShortcut()
        screenEnforcer.setupNewWindowObserver()
        setupScreenChangeObserver()

        if AccessibilityManager.shared.isAccessibilityGranted {
            startEventTap()
            if appState.previewOnHover { hoverController.startHoverMonitor() }
            startPermissionMonitor()
        } else {
            showOnboarding()
            startAccessibilityPolling()
        }

        hoverController.observeHoverSetting()

        // Auto-check for updates (respects cooldown, interval, and user setting)
        if appState.autoUpdateEnabled && appState.updateCheckInterval != "manual" {
            updateChecker.check(force: false, intervalSetting: appState.updateCheckInterval) { [weak self] available in
                if available { self?.notifyUpdateAvailable() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventTapManager.stop()
        hoverController.tearDown()
        screenEnforcer.tearDown()
        permissionMonitorTimer?.invalidate()
        accessibilityTimer?.invalidate()
        if let m = cmdCommaMonitor { NSEvent.removeMonitor(m) }

        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "macwindow.on.rectangle",
                                   accessibilityDescription: "DockPeek")
            button.action = #selector(showMenu)
            button.target = self
        }
    }

    // MARK: - Menu

    @objc private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: L10n.settings, action: #selector(openSettings), keyEquivalent: ",")

        let updateTitle = updateChecker.updateAvailable
            ? "\(L10n.checkForUpdates) ●"
            : L10n.checkForUpdates
        menu.addItem(withTitle: updateTitle, action: #selector(checkForUpdates), keyEquivalent: "")

        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.aboutDockPeek, action: #selector(openAbout), keyEquivalent: "")
        menu.addItem(withTitle: L10n.quitDockPeek, action: #selector(quitApp), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Clear menu so subsequent clicks trigger action again
        DispatchQueue.main.async { self.statusItem.menu = nil }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func openAbout() {
        NSApp.setActivationPolicy(.regular)
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.restoreAccessoryPolicyIfNeeded()
        }
    }

    // MARK: - Update Check

    @objc private func checkForUpdates() {
        updateChecker.check(force: true, intervalSetting: appState.updateCheckInterval) { [weak self] available in
            if available {
                self?.openSettings()
            } else {
                self?.showUpToDateAlert()
            }
        }
    }

    private func notifyUpdateAvailable() {
        openSettings()
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.upToDate
        alert.informativeText = L10n.upToDateMessage
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }

    // MARK: - Settings Window

    @objc func openSettings() {
        NSApp.setActivationPolicy(.regular)

        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                panes: [
                    Settings.Pane(
                        identifier: .init("general"),
                        title: L10n.general,
                        toolbarIcon: NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)!
                    ) {
                        GeneralSettingsPane(appState: self.appState)
                    },
                    Settings.Pane(
                        identifier: .init("appearance"),
                        title: L10n.appearance,
                        toolbarIcon: NSImage(systemSymbolName: "paintbrush", accessibilityDescription: nil)!
                    ) {
                        AppearanceSettingsPane(appState: self.appState)
                    },
                    Settings.Pane(
                        identifier: .init("about"),
                        title: L10n.about,
                        toolbarIcon: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)!
                    ) {
                        AboutSettingsPane()
                    },
                ],
                animated: true
            )
        }

        settingsWindowController?.show()
        settingsWindowController?.window?.orderFrontRegardless()
        settingsWindow = settingsWindowController?.window
        settingsWindow?.delegate = self
        NSApp.activate()
    }

    // MARK: - Cmd+, Shortcut

    private func setupCmdCommaShortcut() {
        cmdCommaMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," {
                self?.openSettings()
                return nil
            }
            return event
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        DispatchQueue.main.async { [weak self] in
            self?.restoreAccessoryPolicyIfNeeded()
        }
    }

    private func restoreAccessoryPolicyIfNeeded() {
        let hasVisibleWindow = settingsWindow?.isVisible == true
        if !hasVisibleWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 350),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "DockPeek Setup"
        window.center()
        window.contentView = NSHostingView(rootView: OnboardingView(onDismiss: {
            window.close()
        }))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func startAccessibilityPolling() {
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if AccessibilityManager.shared.isAccessibilityGranted {
                self.startEventTap()
                if self.appState.previewOnHover { self.hoverController.startHoverMonitor() }
                timer.invalidate()
                self.accessibilityTimer = nil
                self.startPermissionMonitor()
            }
        }
    }

    // MARK: - Event Tap

    private func startEventTap() {
        eventTapManager.delegate = self
        eventTapManager.start()
        dpLog("Event tap delegate connected")
    }

    // MARK: - Screen Change Observer

    private func setupScreenChangeObserver() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    @objc private func screenDidChange() {
        hoverController.updateCachedDockRect()
    }

    // MARK: - Permission Monitor

    private func startPermissionMonitor() {
        permissionMonitorTimer?.invalidate()
        permissionMonitorTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) {
            [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if !AccessibilityManager.shared.isAccessibilityGranted {
                dpLog("Permission revoked — stopping event tap")
                self.eventTapManager.stop()
                self.hoverController.stopHoverMonitor()
                timer.invalidate()
                self.permissionMonitorTimer = nil
                self.startAccessibilityPolling()
            }
        }
    }

    // MARK: - EventTapManagerDelegate

    func eventTapManager(_ manager: EventTapManager, didDetectClickAt point: CGPoint) -> Bool {
        guard appState.isEnabled else { return false }

        // Cancel any pending hover/dismiss timers on click
        hoverController.cancelHoverTimers()

        // If preview is visible, handle click
        if previewPanel.isVisible {
            let cocoaPoint = ScreenGeometry.cgToCocoa(point)
            if previewPanel.frame.contains(cocoaPoint) {
                // Click is on the preview panel — let it through to SwiftUI
                return false
            }

            // Click is on a Dock icon — check what app it is
            if hoverController.isPointInDockArea(point),
               let dockApp = dockInspector.appAtPoint(point),
               dockApp.isRunning, let pid = dockApp.pid,
               !appState.isExcluded(bundleID: dockApp.bundleIdentifier) {
                let windows = windowManager.windowsForApp(pid: pid)
                if windows.count >= 2 {
                    let bundleID = dockApp.bundleIdentifier ?? dockApp.name
                    if bundleID != hoverController.lastHoveredBundleID {
                        // Clicked a different app — switch preview
                        highlightOverlay.hide()
                        previewPanel.dismissPanel(animated: false)
                        hoverController.lastHoveredBundleID = bundleID
                        DispatchQueue.main.async { [weak self] in
                            self?.previewCoordinator.showPreviewForWindows(windows, at: point)
                        }
                    }
                    return true
                } else {
                    // 1 window: dismiss preview, let click through
                    highlightOverlay.hide()
                    previewPanel.dismissPanel(animated: false)
                    hoverController.previewIsVisible = false
                    hoverController.lastHoveredBundleID = dockApp.bundleIdentifier ?? dockApp.name
                    return false
                }
            }

            // Click is outside dock — dismiss and suppress
            highlightOverlay.hide()
            previewPanel.dismissPanel(animated: false)
            hoverController.lastHoveredBundleID = nil
            return true
        }

        // No preview visible — clear hover state
        hoverController.lastHoveredBundleID = nil

        // Debounce (only for new preview triggers)
        let now = Date()
        guard now.timeIntervalSince(lastClickTime) > debounceInterval else { return false }
        lastClickTime = now

        // Fast geometric check: skip AX calls if click is outside Dock area
        guard hoverController.isPointInDockArea(point) else { return false }

        // Hit-test the Dock
        guard let dockApp = dockInspector.appAtPoint(point) else { return false }

        // App not running → Dock will launch it. Warp cursor to primary.
        guard dockApp.isRunning, let pid = dockApp.pid else {
            if appState.forceNewWindowsToPrimary {
                screenEnforcer.warpCursorToPrimaryBriefly()
            }
            return false
        }
        if appState.isExcluded(bundleID: dockApp.bundleIdentifier) { return false }

        let windows = windowManager.windowsForApp(pid: pid)

        // Running app with < 2 windows: warp cursor for primary placement
        if windows.count < 2, appState.forceNewWindowsToPrimary {
            screenEnforcer.warpCursorToPrimaryBriefly()
            return false
        }

        guard windows.count >= 2 else { return false }

        // Suppress click and show preview asynchronously
        dpLog("Will show preview for \(dockApp.name) (\(windows.count) windows)")
        DispatchQueue.main.async { [weak self] in
            self?.previewCoordinator.showPreviewForWindows(windows, at: point)
        }
        return true
    }
}
