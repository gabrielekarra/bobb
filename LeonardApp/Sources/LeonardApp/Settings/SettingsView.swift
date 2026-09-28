import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import LeonardCore

@MainActor
@Observable
final class SettingsUIModel {
    enum Tab: String, CaseIterable {
        case general, attention, acting, privacy, model, license, about
    }

    var tab: Tab = .general
    var licenseInput = ""
    var verifyFraction: Double?
    var verifyResult: String?
    var message: String?
    var confirmDeleteHistory = false
}

/// Everything the user can change, in seven tabs. Every control writes
/// through `LeonardCoordinator.updateSettings`, which persists the change
/// and sends the daemon the part it enforces.
struct SettingsView: View {
    @Bindable var state: AppState
    @Bindable var ui: SettingsUIModel
    @Bindable var license: LicenseController
    @Bindable var permissions: Permissions
    @Bindable var downloader: ModelDownloader
    @Bindable var calendar: CalendarSensor
    let coordinator: LeonardCoordinator
    let services: SettingsServices

    var body: some View {
        TabView(selection: $ui.tab) {
            general.tabItem { Label(L10n.t(.settingsGeneral), systemImage: "gearshape") }.tag(SettingsUIModel.Tab.general)
            attention.tabItem { Label(L10n.t(.settingsAttention), systemImage: "bell.badge") }.tag(SettingsUIModel.Tab.attention)
            acting.tabItem { Label(L10n.t(.settingsActing), systemImage: "cursorarrow.rays") }.tag(SettingsUIModel.Tab.acting)
            privacy.tabItem { Label(L10n.t(.settingsPrivacy), systemImage: "lock.shield") }.tag(SettingsUIModel.Tab.privacy)
            modelTab.tabItem { Label(L10n.t(.settingsModel), systemImage: "cpu") }.tag(SettingsUIModel.Tab.model)
            licenseTab.tabItem { Label(L10n.t(.settingsLicense), systemImage: "key") }.tag(SettingsUIModel.Tab.license)
            about.tabItem { Label(L10n.t(.settingsAbout), systemImage: "info.circle") }.tag(SettingsUIModel.Tab.about)
        }
        .padding(20)
        .frame(width: 600, height: 520)
        .tint(Theme.accent)
        .onAppear { permissions.refresh() }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<LeonardSettings, T>) -> Binding<T> {
        Binding(
            get: { state.settings[keyPath: keyPath] },
            set: { value in coordinator.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: General

    private var general: some View {
        Form {
            Picker(L10n.t(.settingsLanguage), selection: binding(\.language)) {
                Text(L10n.t(.settingsLanguageSystem)).tag(AppLanguage.system)
                Text("English").tag(AppLanguage.en)
                Text("Italiano").tag(AppLanguage.it)
            }
            Toggle(L10n.t(.settingsLaunchAtLogin), isOn: binding(\.launchAtLogin))
            Section {
                LabeledContent(L10n.t(.settingsHotkey)) {
                    Text(state.settings.hotkey.display)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                }
                hint(L10n.t(.settingsHotkeyHint))
            }
            Section(L10n.t(.settingsPermissions)) {
                permissionRow(L10n.t(.settingsAccessibility), permissions.accessibility) { Permissions.openAccessibilitySettings() }
                permissionRow(L10n.t(.settingsAutomation), permissions.mailAutomation) { Permissions.openAutomationSettings() }
                HStack {
                    Text(L10n.t(.settingsCalendar)).font(.system(size: 12))
                    Spacer()
                    switch calendar.access {
                    case .granted:
                        Label(L10n.t(.settingsGranted), systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 11))
                    case .notDetermined:
                        Button(L10n.t(.onbGrant)) { calendar.requestAccess() }.controlSize(.small)
                    case .denied:
                        Button(L10n.t(.settingsOpenSystemSettings)) { Permissions.openCalendarSettings() }.controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func permissionRow(_ title: String, _ status: Permissions.Status, open: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            if status == .granted {
                Label(L10n.t(.settingsGranted), systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 11))
            } else {
                Button(L10n.t(.settingsOpenSystemSettings)) { open() }.controlSize(.small)
            }
        }
    }

    // MARK: Attention

    private var attention: some View {
        Form {
            Section {
                Toggle(L10n.t(.settingsMailProactive), isOn: binding(\.mailProactive))
                hint(L10n.t(.settingsMailProactiveHint))
                Toggle(L10n.t(.settingsChatProactive), isOn: binding(\.chatProactive))
                hint(L10n.t(.settingsChatProactiveHint))
                Toggle(L10n.t(.settingsMeetingPrep), isOn: binding(\.meetingPrep))
                hint(L10n.t(.settingsMeetingPrepHint))
                if state.settings.meetingPrep && calendar.access != .granted {
                    Button(L10n.t(.settingsCalendarAllow)) { calendar.requestAccess() }.controlSize(.small)
                }
                Toggle(L10n.t(.settingsTrackPromises), isOn: binding(\.trackPromises))
                hint(L10n.t(.settingsTrackPromisesHint))
                Toggle(L10n.t(.settingsToneCheck), isOn: binding(\.toneCheck))
                hint(L10n.t(.settingsToneCheckHint))
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t(.settingsFloor)).font(.system(size: 12))
                    Slider(value: binding(\.floor), in: 0.4...0.9, step: 0.01)
                    hint(L10n.t(.settingsFloorHint, ["value": L10n.percent(state.settings.floor)]))
                }
                Toggle(L10n.t(.settingsAdaptive), isOn: binding(\.adaptive))
                hint(L10n.t(.settingsAdaptiveHint))
            }
            Section {
                Toggle(L10n.t(.settingsQuietHours), isOn: binding(\.quietHoursEnabled))
                if state.settings.quietHoursEnabled {
                    HStack {
                        Picker(L10n.t(.settingsQuietFrom), selection: binding(\.quietFrom)) {
                            ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                        }
                        Picker(L10n.t(.settingsQuietTo), selection: binding(\.quietTo)) {
                            ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                        }
                    }
                }
                Picker(L10n.t(.settingsOverlaySeconds), selection: binding(\.overlaySeconds)) {
                    ForEach([8, 14, 20, 30, 60], id: \.self) { Text("\($0) s").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Using apps

    private var acting: some View {
        Form {
            Section {
                Toggle(L10n.t(.settingsActingEnabled), isOn: binding(\.actingEnabled))
                hint(L10n.t(.settingsActingHint))
            }
            if state.settings.actingEnabled {
                Section {
                    Picker(L10n.t(.settingsActingApproval), selection: binding(\.actingApproval)) {
                        Text(L10n.t(.settingsApprovalImportant)).tag(ActingApproval.important)
                        Text(L10n.t(.settingsApprovalEvery)).tag(ActingApproval.everyStep)
                    }
                    .pickerStyle(.radioGroup)
                }
                Section(L10n.t(.settingsAllowRules)) {
                    if state.settings.actionAllowRules.isEmpty {
                        hint(L10n.t(.settingsAllowRulesEmpty))
                    }
                    ForEach(state.settings.actionAllowRules, id: \.self) { rule in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("“\(rule.label)”").font(.system(size: 12))
                                Text(rule.app).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(L10n.t(.settingsRemove)) {
                                coordinator.updateSettings { $0.actionAllowRules.removeAll { $0 == rule } }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Privacy

    private var privacy: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "network.slash").foregroundStyle(Theme.accent).font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.t(.settingsNetworkTitle)).font(.system(size: 12.5, weight: .semibold))
                        hint(L10n.t(.settingsNetworkBody))
                    }
                }
            }
            Section {
                Toggle(L10n.t(.settingsMemoryEnabled), isOn: binding(\.memoryEnabled))
                hint(L10n.t(.settingsMemoryEnabledHint))
                Picker(L10n.t(.settingsMemoryRetention), selection: binding(\.memoryRetentionDays)) {
                    ForEach(LeonardSettings.retentionChoices, id: \.self) { Text(L10n.t(.settingsDays, ["count": "\($0)"])).tag($0) }
                }
                Picker(L10n.t(.settingsHistoryRetention), selection: binding(\.historyRetentionDays)) {
                    ForEach(LeonardSettings.retentionChoices, id: \.self) { Text(L10n.t(.settingsDays, ["count": "\($0)"])).tag($0) }
                }
                Button(L10n.t(.settingsOpenMemory)) { services.openMemory() }
            }
            Section(L10n.t(.settingsProtectedApps)) {
                hint(L10n.t(.settingsProtectedAppsHint))
                ForEach(state.settings.extraProtectedApps, id: \.self) { app in
                    HStack {
                        Text(app).font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Button(L10n.t(.settingsRemove)) {
                            coordinator.updateSettings { $0.extraProtectedApps.removeAll { $0 == app } }
                        }
                        .controlSize(.small)
                    }
                }
                Button(L10n.t(.settingsAddApp)) { addProtectedApp() }
            }
            Section {
                Button(L10n.t(.settingsDeleteHistory), role: .destructive) { ui.confirmDeleteHistory = true }
                if let message = ui.message { hint(message) }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(L10n.t(.settingsDeleteHistoryConfirm), isPresented: $ui.confirmDeleteHistory) {
            Button(L10n.t(.genericDelete), role: .destructive) {
                Task {
                    let count = await coordinator.deleteHistory()
                    ui.message = count.map { L10n.t(.memoryDeleted, ["count": "\($0)"]) }
                }
            }
            Button(L10n.t(.genericCancel), role: .cancel) {}
        }
    }

    private func addProtectedApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        coordinator.updateSettings { settings in
            for id in ids where !settings.extraProtectedApps.contains(id) {
                settings.extraProtectedApps.append(id)
            }
        }
    }

    // MARK: Model

    private var modelTab: some View {
        Form {
            Section {
                LabeledContent(L10n.t(.settingsModelName), value: downloader.manifest.id)
                LabeledContent(L10n.t(.settingsModelLicense), value: downloader.manifest.license)
                LabeledContent(L10n.t(.settingsModelLocation)) {
                    Button(L10n.t(.settingsModelReveal)) {
                        NSWorkspace.shared.activateFileViewerSelecting([downloader.installDirectory])
                    }
                    .controlSize(.small)
                    .disabled(!downloader.isInstalled)
                }
                if downloader.isInstalled {
                    Text(L10n.t(.settingsModelInstalled, ["size": ModelInstallation.formatBytes(downloader.manifest.totalBytes)]))
                        .font(.system(size: 12))
                } else {
                    Text(L10n.t(.settingsModelMissing)).font(.system(size: 12)).foregroundStyle(Theme.attention)
                    Button(L10n.t(.onbDownload)) { services.startDownload() }
                }
            }
            Section {
                HStack {
                    Button(ui.verifyFraction == nil ? L10n.t(.settingsModelVerify) : L10n.t(.settingsModelVerifying)) { verify() }
                        .disabled(ui.verifyFraction != nil || !downloader.isInstalled)
                    if let fraction = ui.verifyFraction { ProgressView(value: fraction).frame(width: 160) }
                }
                if let result = ui.verifyResult { hint(result) }
                Button(L10n.t(.settingsDaemonRestart)) { services.restartDaemon() }
            }
        }
        .formStyle(.grouped)
    }

    private func verify() {
        ui.verifyFraction = 0
        ui.verifyResult = nil
        Task {
            let bad = await downloader.verifyInstalled { fraction in ui.verifyFraction = fraction }
            ui.verifyFraction = nil
            ui.verifyResult = bad.isEmpty ? L10n.t(.settingsModelOK) : L10n.t(.settingsModelCorrupt) + " (" + bad.joined(separator: ", ") + ")"
        }
    }

    // MARK: License

    private var licenseTab: some View {
        Form {
            Section {
                switch license.entitlement {
                case .trial(let days):
                    Label(L10n.t(.licenseTrial, ["days": "\(days)"]), systemImage: "hourglass")
                case .trialExpired:
                    Label(L10n.t(.licenseTrialExpired), systemImage: "hourglass.bottomhalf.filled").foregroundStyle(Theme.attention)
                    hint(L10n.t(.licenseExpiredBody))
                case .licensed(let payload):
                    Label(L10n.t(.licenseLicensed, ["name": payload.name]), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    LabeledContent(L10n.t(.licenseEdition), value: "\(payload.editionDisplay) · \(payload.seats)")
                    LabeledContent(L10n.t(.licenseUpdatesUntil, ["date": LicenseDates.display(payload.updatesUntil)]), value: "")
                case .updatesExpired(let payload):
                    Label(L10n.t(.licenseUpdatesExpired, ["date": LicenseDates.display(payload.updatesUntil)]), systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(Theme.attention)
                }
                if BuildInfo.isDevelopmentBuild {
                    Pill(text: L10n.t(.licenseDevBuild), color: Theme.attention)
                }
            }
            Section(L10n.t(.licenseEnter)) {
                TextField(L10n.t(.licensePlaceholder), text: $ui.licenseInput, axis: .vertical)
                    .lineLimit(3...5)
                    .font(.system(size: 11, design: .monospaced))
                HStack {
                    Button(L10n.t(.licenseActivate)) {
                        if license.activate(ui.licenseInput) {
                            ui.licenseInput = ""
                            services.entitlementChanged()
                        }
                    }
                    .disabled(ui.licenseInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(L10n.t(.licenseBuy)) { NSWorkspace.shared.open(BuildInfo.buyURL) }
                    Spacer()
                    if license.license != nil {
                        Button(L10n.t(.licenseRemove), role: .destructive) {
                            license.remove()
                            services.entitlementChanged()
                        }
                    }
                }
                if let error = license.lastError {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: About

    private var about: some View {
        VStack(spacing: 14) {
            Spacer()
            LeonardAppIcon(size: 72)
            Text("Leonard").font(.system(size: 24, weight: .bold))
            Text(L10n.t(.settingsVersion, ["version": "\(BuildInfo.version) (\(BuildInfo.build))"]))
                .foregroundStyle(.secondary)
            Text(L10n.t(.settingsBuiltWithLlama))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            HStack {
                Button(L10n.t(.settingsCheckUpdates)) { NSWorkspace.shared.open(BuildInfo.releasesURL) }
                Button(L10n.t(.settingsExportDiagnostics)) { services.exportDiagnostics() }
                Button(L10n.t(.settingsThirdParty)) { services.openNotices() }
            }
            Text(BuildInfo.supportEmail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// App services the settings window can trigger.
struct SettingsServices {
    var openMemory: () -> Void
    var startDownload: () -> Void
    var restartDaemon: () -> Void
    var exportDiagnostics: () -> Void
    var openNotices: () -> Void
    var entitlementChanged: () -> Void
}
