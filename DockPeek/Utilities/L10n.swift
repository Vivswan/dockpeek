import Foundation

enum Language: String, CaseIterable {
    case en, ko

    var displayName: String {
        switch self {
        case .en: "English"
        case .ko: "한국어"
        }
    }
}

/// Localization helper that loads strings from .lproj bundles based on the
/// user's in-app language setting. Falls back to the key if no translation found.
enum L10n {
    static var current: Language {
        Language(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "en") ?? .en
    }

    /// Localized bundle for the current language.
    private static var bundle: Bundle {
        guard let path = Bundle.main.path(forResource: current.rawValue, ofType: "lproj"),
              let b = Bundle(path: path) else {
            return Bundle.main
        }
        return b
    }

    /// Look up a key in Localizable.strings for the current language.
    static func s(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    // MARK: - Menu

    static var settings: String { s("settings") }
    static var aboutDockPeek: String { s("aboutDockPeek") }
    static var quitDockPeek: String { s("quitDockPeek") }

    // MARK: - Tabs

    static var general: String { s("general") }
    static var appearance: String { s("appearance") }
    static var about: String { s("about") }

    // MARK: - General

    static var enableDockPeek: String { s("enableDockPeek") }
    static var launchAtLogin: String { s("launchAtLogin") }
    static var language: String { s("language") }

    // MARK: - Behavior

    static var previewOnHover: String { s("previewOnHover") }
    static var hoverDelay: String { s("hoverDelay") }
    static var livePreviewOnHover: String { s("livePreviewOnHover") }
    static var forceNewWindowsToPrimary: String { s("forceNewWindowsToPrimary") }
    static var showWindowTitles: String { s("showWindowTitles") }
    static var showSnapButtons: String { s("showSnapButtons") }
    static var showCloseButton: String { s("showCloseButton") }
    static var thumbnailSize: String { s("thumbnailSize") }

    // MARK: - Permissions

    static var permissions: String { s("permissions") }
    static var accessibilityGranted: String { s("accessibilityGranted") }
    static var accessibilityRequired: String { s("accessibilityRequired") }
    static var grantPermission: String { s("grantPermission") }
    static var screenRecordingGranted: String { s("screenRecordingGranted") }
    static var screenRecordingRequired: String { s("screenRecordingRequired") }
    static var copyDiagnostics: String { s("copyDiagnostics") }
    static var diagnosticsCopied: String { s("diagnosticsCopied") }

    // MARK: - Updates

    static var checkForUpdates: String { s("checkForUpdates") }
    static var updateAvailable: String { s("updateAvailable") }
    static var updateMessage: String { s("updateMessage") }
    static var autoUpdate: String { s("autoUpdate") }
    static var autoUpdateHint: String { s("autoUpdateHint") }
    static var download: String { s("download") }
    static var later: String { s("later") }
    static var brewHint: String { s("brewHint") }
    static var upToDate: String { s("upToDate") }
    static var upToDateMessage: String { s("upToDateMessage") }
    static var autoUpdateToggle: String { s("autoUpdate_toggle") }
    static var updateInterval: String { s("updateInterval") }
    static var daily: String { s("daily") }
    static var weekly: String { s("weekly") }
    static var manual: String { s("manual") }
    static var lastChecked: String { s("lastChecked") }
    static var never: String { s("never") }
    static var checkNow: String { s("checkNow") }
    static var releaseNotes: String { s("releaseNotes") }
    static var newVersionAvailable: String { s("newVersionAvailable") }
    static var currentVersion: String { s("currentVersion") }
    static var updateNow: String { s("updateNow") }
    static var upgrading: String { s("upgrading") }
    static var upgradeComplete: String { s("upgradeComplete") }
    static var upgradeFailed: String { s("upgradeFailed") }
    static var restart: String { s("restart") }
    static var retry: String { s("retry") }

    // MARK: - About

    static var version: String { s("version") }
    static var buyMeACoffee: String { s("buyMeACoffee") }
    static var buyMeACoffeeDesc: String { s("buyMeACoffeeDesc") }
    static var gitHub: String { s("gitHub") }
    static var quit: String { s("quit") }

    // MARK: - Excluded Apps

    static var excludedApps: String { s("excludedApps") }
    static var addPlaceholder: String { s("addPlaceholder") }
    static var add: String { s("add") }

    // MARK: - Preview

    static var minimized: String { s("minimized") }
    static var otherDesktop: String { s("otherDesktop") }
    static var showMinimizedWindows: String { s("showMinimizedWindows") }
    static var showOtherSpaceWindows: String { s("showOtherSpaceWindows") }

    // MARK: - Onboarding

    static var onboardingTitle: String { s("onboardingTitle") }
    static var onboardingBody: String { s("onboardingBody") }
    static var onboardingStep1: String { s("onboardingStep1") }
    static var onboardingStep2: String { s("onboardingStep2") }
    static var onboardingStep3: String { s("onboardingStep3") }
    static var onboardingOpenSettings: String { s("onboardingOpenSettings") }
    static var onboardingConfirm: String { s("onboardingConfirm") }
}
