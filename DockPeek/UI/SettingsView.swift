import SwiftUI
import ServiceManagement

// MARK: - Settings Pane Views

struct GeneralSettingsPane: View {
    @ObservedObject var appState: AppState
    @ObservedObject var updateChecker: UpdateChecker = .shared
    @State private var langRefresh = UUID()
    @State private var isCheckingUpdate = false

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
    var body: some View {
        Settings.Container(contentWidth: 450) {
            Settings.Section(title: "", bottomDivider: true) {
                Toggle(L10n.enableDockPeek, isOn: $appState.isEnabled)
                Toggle(L10n.launchAtLogin, isOn: $appState.launchAtLogin)
                    .onChange(of: appState.launchAtLogin) { _, newValue in
                        do {
                            if newValue { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch { dpLog("Login item: \(error)") }
                    }
            }

            Settings.Section(title: "", bottomDivider: true) {
                Toggle(L10n.autoUpdateToggle, isOn: $appState.autoUpdateEnabled)
                HStack(spacing: 8) {
                    Button(action: performUpdateCheck) {
                        HStack(spacing: 6) {
                            if isCheckingUpdate { ProgressView().controlSize(.small) }
                            Text(L10n.checkNow)
                        }
                    }
                    .disabled(isCheckingUpdate)
                    if let lastDate = updateChecker.lastCheckDate {
                        Text("\(L10n.lastChecked) \(Self.relativeDateFormatter.localizedString(for: lastDate, relativeTo: Date()))")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                if updateChecker.updateAvailable || updateChecker.upgradeState != .idle {
                    updateAvailableSection
                }
            }

            Settings.Section(bottomDivider: true, verticalAlignment: .center, label: { Text(L10n.language) }) {
                Picker("", selection: $appState.language) {
                    ForEach(Language.allCases, id: \.rawValue) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                .offset(x: -24)
                .onChange(of: appState.language) { _, _ in langRefresh = UUID() }
            }

            Settings.Section(verticalAlignment: .top, label: { Text(L10n.permissions) }) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(AccessibilityManager.shared.isAccessibilityGranted ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(AccessibilityManager.shared.isAccessibilityGranted
                        ? L10n.accessibilityGranted : L10n.accessibilityRequired)
                        .font(.caption).foregroundColor(.secondary)
                    if !AccessibilityManager.shared.isAccessibilityGranted {
                        Button(L10n.grantPermission) { AccessibilityManager.shared.openAccessibilitySettings() }
                            .font(.caption)
                    }
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(screenRecordingOK ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(screenRecordingOK
                        ? L10n.screenRecordingGranted : L10n.screenRecordingRequired)
                        .font(.caption).foregroundColor(.secondary)
                }
                .onAppear { screenRecordingOK = DiagnosticChecker.isScreenRecordingEffective }
            }
        }
        .id(langRefresh)
    }

    // MARK: - Update

    private func performUpdateCheck() {
        isCheckingUpdate = true
        updateChecker.check(force: true, intervalSetting: appState.updateCheckInterval) { _ in
            isCheckingUpdate = false
        }
    }

    private var updateAvailableSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if updateChecker.updateAvailable {
                Text(String(format: L10n.newVersionAvailable, updateChecker.latestVersion))
                    .font(.callout.bold())
                if !updateChecker.releaseBody.isEmpty {
                    ScrollView {
                        Text(.init(updateChecker.releaseBody))
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 80)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                }
            }

            switch updateChecker.upgradeState {
            case .idle:
                if updateChecker.updateAvailable {
                    HStack(spacing: 8) {
                        Button(L10n.updateNow) { updateChecker.downloadAndInstall() }
                        Button(L10n.download) {
                            if let url = URL(string: updateChecker.releaseURL) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            case let .downloading(progress):
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                    Text(L10n.upgrading).font(.caption).foregroundColor(.secondary)
                }
            case .completed:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text(L10n.upgradeComplete)
                    Spacer()
                    Button(L10n.restart) { updateChecker.relaunchApp() }
                }
            case let .failed(msg):
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                        Text(L10n.upgradeFailed)
                    }
                    Text(msg).font(.caption).foregroundColor(.secondary).lineLimit(2)
                    Button(L10n.retry) {
                        updateChecker.resetUpgradeState()
                        updateChecker.downloadAndInstall()
                    }
                }
            }
        }
    }

    // MARK: - Permissions

    @State private var screenRecordingOK = DiagnosticChecker.isScreenRecordingEffective
}

// MARK: - Appearance Pane

struct AppearanceSettingsPane: View {
    @ObservedObject var appState: AppState
    @State private var newExcludedID = ""

    var body: some View {
        Settings.Container(contentWidth: 450) {
            // Preview on hover + live overlay + delay slider
            Settings.Section(title: "", bottomDivider: false) {
                Toggle(L10n.previewOnHover, isOn: $appState.previewOnHover)
                Toggle(L10n.livePreviewOnHover, isOn: $appState.livePreviewOnHover)
            }

            Settings.Section(bottomDivider: true, label: { Text(L10n.hoverDelay) }) {
                HStack {
                    Slider(value: $appState.hoverDelay, in: 0.05 ... 2.0, step: 0.05)
                        .frame(width: 200)
                    Text("\(Int(appState.hoverDelay * 1000))ms")
                        .font(.caption).foregroundColor(.secondary)
                        .frame(width: 45, alignment: .trailing)
                }
            }

            // Window display options + thumbnail size
            Settings.Section(title: "", bottomDivider: false) {
                Toggle(L10n.showWindowTitles, isOn: $appState.showWindowTitles)
                Toggle(L10n.showCloseButton, isOn: $appState.showCloseButton)
                Toggle(L10n.showSnapButtons, isOn: $appState.showSnapButtons)
                Toggle(L10n.showMinimizedWindows, isOn: $appState.showMinimizedWindows)
                Toggle(L10n.showOtherSpaceWindows, isOn: $appState.showOtherSpaceWindows)
                Toggle(L10n.forceNewWindowsToPrimary, isOn: $appState.forceNewWindowsToPrimary)
            }

            Settings.Section(bottomDivider: true, label: { Text(L10n.thumbnailSize) }) {
                HStack {
                    Slider(value: $appState.thumbnailSize, in: 120 ... 360, step: 20)
                        .frame(width: 200)
                    Text("\(Int(appState.thumbnailSize))px")
                        .font(.caption).foregroundColor(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }

            // Excluded apps
            Settings.Section(label: { Text(L10n.excludedApps) }) {
                exclusionList
            }
        }
    }

    private var exclusionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(appState.excludedBundleIDs.sorted()), id: \.self) { bid in
                HStack {
                    Text(bid).font(.caption).lineLimit(1)
                    Spacer()
                    Button {
                        var ids = appState.excludedBundleIDs
                        ids.remove(bid)
                        appState.excludedBundleIDs = ids
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                TextField(L10n.addPlaceholder, text: $newExcludedID)
                    .textFieldStyle(.roundedBorder).font(.caption)
                    .onSubmit { addExcludedApp() }
                Button(L10n.add) { addExcludedApp() }
                    .disabled(newExcludedID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addExcludedApp() {
        let t = newExcludedID.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var ids = appState.excludedBundleIDs
        ids.insert(t)
        appState.excludedBundleIDs = ids
        newExcludedID = ""
    }
}

// MARK: - About Pane

struct AboutSettingsPane: View {
    @State private var diagnosticsCopied = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "dock.rectangle")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
                Text("DockPeek").font(.title2.bold())
                Text("\(L10n.version) \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                    .font(.caption).foregroundColor(.secondary)
            }

            Divider().padding(.horizontal, 40)

            VStack(spacing: 8) {
                Text(L10n.buyMeACoffeeDesc)
                    .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                Button(action: {
                    if let url = URL(string: "https://buymeacoffee.com/zerry") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack {
                        Image(systemName: "cup.and.saucer.fill")
                        Text(L10n.buyMeACoffee)
                    }
                }
                .controlSize(.large)
            }

            Button(action: {
                if let url = URL(string: "https://github.com/ongjin/dockpeek") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                HStack { Image(systemName: "link"); Text(L10n.gitHub) }
            }
            .buttonStyle(.link)

            Spacer()

            Button(action: {
                let report = DiagnosticChecker.run()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report.text, forType: .string)
                diagnosticsCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { diagnosticsCopied = false }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc")
                    Text(diagnosticsCopied ? L10n.diagnosticsCopied : L10n.copyDiagnostics)
                }
            }
            .font(.caption)
            .padding(.bottom, 8)
        }
        .frame(minWidth: 400, minHeight: 300)
    }
}
