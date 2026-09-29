import AppKit
import ServiceManagement
import SwiftUI
import LeonardCore

/// The composition root: builds every long-lived object once, wires them
/// together, and owns their lifetimes. Nothing else in the app constructs a
/// controller or a service.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState!
    private var settingsStore: SettingsStore!
    private var coordinator: LeonardCoordinator!
    private var supervisor: DaemonSupervisor!
    private var license: LicenseController!
    private var downloader: ModelDownloader!
    private var permissions: Permissions!
    private var screenSensor: ScreenMemorySensor!
    private var conversations = ConversationTracker()
    private var sentMail: SentMailSensor!
    private(set) var calendar: CalendarSensor!
    private var hotkey: GlobalHotkey!
    private var talkHotkey: GlobalHotkey!

    private var statusItemController: StatusItemController!
    private var overlayController: OverlayController!
    private var draftPanel: DraftPanelController!
    private var commandBar: CommandBarController!
    private var tasks: TaskController!
    private var mindWindowController: MindWindowController!
    private var auditWindowController: AuditWindowController!
    private var settingsWindow: NSWindow?
    private var memoryWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private let settingsUI = SettingsUIModel()
    private let memoryModel = MemoryBrowserModel()
    private let onboardingModel = OnboardingModel()
    private var housekeeping: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppPaths.prepare()

        settingsStore = SettingsStore(url: AppPaths.settingsFile)
        let settings = settingsStore.load()
        L10n.code = settings.language.code

        let state = AppState()
        state.settings = settings
        self.state = state

        license = LicenseController(
            licenseFile: AppPaths.licenseFile,
            trialFile: AppPaths.dataDirectory.appendingPathComponent(".trial"),
            publicKey: BuildInfo.licensePublicKey
        )
        state.entitlement = license.entitlement

        downloader = ModelDownloader(modelsDirectory: AppPaths.modelsDirectory)
        state.modelInstalled = downloader.isInstalled
        permissions = Permissions()

        supervisor = DaemonSupervisor(command: DaemonCommand.resolve(
            dataDir: AppPaths.dataDirectory, modelsDir: AppPaths.modelsDirectory,
            logFile: AppPaths.logsDirectory.appendingPathComponent("leonardd.log")
        ))

        let client = IPCClient(socketPath: AppPaths.socketPath)
        let eventSource: EventSource
        if AppPaths.flag("--mock-events") {
            eventSource = MockEventSource(scenario: MockEventSource.demoScenario())
        } else {
            let composite = CompositeEventSource()
            composite.mail.onPermissionDenied = { [weak self] in self?.permissions.refresh() }
            eventSource = composite
        }
        let coordinator = LeonardCoordinator(state: state, client: client, eventSource: eventSource)
        self.coordinator = coordinator
        coordinator.onSettingsChanged = { [weak self] settings in self?.settingsChanged(settings) }

        screenSensor = ScreenMemorySensor(policy: ScreenMemoryPolicy(extraProtected: settings.extraProtectedApps))
        screenSensor.onFrame = { [weak coordinator] frame in coordinator?.observe(frame) }
        screenSensor.onWindowText = { [weak self] text in self?.windowRead(text) }
        sentMail = SentMailSensor(seenFile: AppPaths.dataDirectory.appendingPathComponent("sent-seen.json"))
        sentMail.onEvent = { [weak coordinator] event in coordinator?.submit(event) }
        calendar = CalendarSensor()
        calendar.onEvent = { [weak coordinator] event in coordinator?.submit(event) }
        calendar.onMemory = { [weak coordinator] frame in coordinator?.observe(frame) }

        overlayController = OverlayController(state: state, coordinator: coordinator)
        draftPanel = DraftPanelController(state: state, coordinator: coordinator)
        commandBar = CommandBarController(state: state, coordinator: coordinator)
        tasks = TaskController(state: state, coordinator: coordinator)
        commandBar.startTask = { [weak self] goal in self?.tasks.start(goal: goal) }
        mindWindowController = MindWindowController(state: state, coordinator: coordinator)
        auditWindowController = AuditWindowController(auditPath: AppPaths.auditDatabase)
        statusItemController = StatusItemController(state: state) { [weak self] controller in
            self?.menuActions(closing: controller) ?? MenuBarActions.empty
        }

        hotkey = GlobalHotkey { [weak self] in self?.openCommandBar() }
        hotkey.register(settings.hotkey)
        talkHotkey = GlobalHotkey { [weak self] in self?.commandBar.listen() }
        talkHotkey.register(settings.talkHotkey)

        supervisor.start()
        coordinator.start()
        if Self.needsScreenSensor(settings) { screenSensor.start() }
        syncSensors(settings)
        syncLoginItem(settings.launchAtLogin)

        housekeeping = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshEntitlement() }
        }

        if !settings.onboardingCompleted || !downloader.isInstalled {
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
        screenSensor?.stop()
        supervisor?.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Settings

    private func settingsChanged(_ settings: LeonardSettings) {
        try? settingsStore.save(settings)
        hotkey.register(settings.hotkey)
        talkHotkey.register(settings.talkHotkey)
        screenSensor.updateProtectedApps(settings.extraProtectedApps)
        if Self.needsScreenSensor(settings) {
            screenSensor.start()
        } else {
            screenSensor.stop()
        }
        syncSensors(settings)
        syncLoginItem(settings.launchAtLogin)
    }

    private func syncSensors(_ settings: LeonardSettings) {
        screenSensor.readImages = settings.readImages && settings.memoryEnabled
        if settings.watching && settings.trackPromises { sentMail.start() } else { sentMail.stop() }
        if settings.watching && (settings.meetingPrep || settings.memoryEnabled) { calendar.start() } else { calendar.stop() }
    }

    /// The screen sensor's reads feed both screen memory and the
    /// conversation radar; it runs when either is wanted.
    private static func needsScreenSensor(_ settings: LeonardSettings) -> Bool {
        settings.watching && (settings.memoryEnabled || settings.chatProactive)
    }

    private func windowRead(_ text: WindowText) {
        guard state.settings.chatProactive else { return }
        let typing = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 2
        if let event = conversations.observe(app: text.app, bundleId: text.bundleId, window: text.window, text: text.text,
                                             typing: typing) {
            coordinator.submit(event)
        }
    }

    private func syncLoginItem(_ enabled: Bool) {
        // Only a real .app bundle can be a login item; a `swift run` binary cannot.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let service = SMAppService.mainApp
        do {
            if enabled, service.status != .enabled {
                try service.register()
            } else if !enabled, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            // The user can still add it by hand in System Settings > General > Login Items.
        }
    }

    private func refreshEntitlement() {
        license.evaluate()
        state.entitlement = license.entitlement
        state.expireForYou()
    }

    // MARK: Menu bar

    private func menuActions(closing controller: StatusItemController) -> MenuBarActions {
        MenuBarActions(
            approve: { [weak self, weak controller] decision in
                controller?.closePopover()
                self?.coordinator.approve(decision)
            },
            dismiss: { [weak self] decision in self?.coordinator.dismiss(decision) },
            setWatching: { [weak self] watching in self?.coordinator.setWatching(watching) },
            openCommandBar: { [weak self, weak controller] in
                controller?.closePopover()
                self?.commandBar.show(selection: nil)
            },
            openMind: { [weak self, weak controller] in
                controller?.closePopover()
                self?.mindWindowController.show()
            },
            openMemory: { [weak self, weak controller] in
                controller?.closePopover()
                self?.showMemory()
            },
            openSettings: { [weak self, weak controller] in
                controller?.closePopover()
                self?.showSettings(tab: .general)
            },
            openLicense: { [weak self, weak controller] in
                controller?.closePopover()
                self?.showSettings(tab: .license)
            },
            openOnboarding: { [weak self, weak controller] in
                controller?.closePopover()
                self?.showOnboarding()
            },
            quit: { NSApp.terminate(nil) },
            promise: { [weak self] promise, action in
                switch action {
                case .done: self?.coordinator.updateCommitment(promise.id, status: "done")
                case .dismiss: self?.coordinator.updateCommitment(promise.id, status: "dismissed")
                case .tomorrow:
                    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
                    self?.coordinator.updateCommitment(promise.id, dueTs: tomorrow.addingTimeInterval(18 * 3600).timeIntervalSince1970)
                }
            }
        )
    }

    private func openCommandBar() {
        guard state.entitlement.allowsAssistance else {
            showSettings(tab: .license)
            return
        }
        commandBar.toggle()
    }

    // MARK: Windows

    private func showSettings(tab: SettingsUIModel.Tab) {
        settingsUI.tab = tab
        if settingsWindow == nil {
            let view = SettingsView(
                state: state, ui: settingsUI, license: license, permissions: permissions, downloader: downloader,
                calendar: calendar, coordinator: coordinator,
                services: SettingsServices(
                    openMemory: { [weak self] in self?.showMemory() },
                    startDownload: { [weak self] in self?.startDownload() },
                    restartDaemon: { [weak self] in self?.supervisor.restart() },
                    exportDiagnostics: { [weak self] in self?.exportDiagnostics() },
                    openNotices: { Self.openNotices() },
                    entitlementChanged: { [weak self] in self?.refreshEntitlement() }
                )
            )
            settingsWindow = WindowPresenter.makeWindow(title: L10n.t(.settingsTitle), size: NSSize(width: 600, height: 520), resizable: false, content: view)
        }
        WindowPresenter.present(settingsWindow)
    }

    private func showMemory() {
        if memoryWindow == nil {
            let view = MemoryView(state: state, model: memoryModel, coordinator: coordinator)
            memoryWindow = WindowPresenter.makeWindow(title: L10n.t(.memoryTitle), size: NSSize(width: 880, height: 580), content: view)
        }
        memoryModel.refresh(using: coordinator)
        WindowPresenter.present(memoryWindow)
    }

    private func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(
                model: onboardingModel, permissions: permissions, downloader: downloader, calendar: calendar,
                hotkey: state.settings.hotkey,
                startDownload: { [weak self] in self?.startDownload() },
                finish: { [weak self] in self?.finishOnboarding() }
            )
            let window = WindowPresenter.makeWindow(title: "Leonard", size: NSSize(width: 640, height: 520), resizable: false, content: view)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            onboardingWindow = window
        }
        if downloader.isInstalled && state.settings.onboardingCompleted == false && onboardingModel.step == .model {
            onboardingModel.next()
        }
        WindowPresenter.present(onboardingWindow)
    }

    private func finishOnboarding() {
        coordinator.updateSettings { $0.onboardingCompleted = true }
        onboardingWindow?.close()
    }

    private func startDownload() {
        downloader.start { [weak self] in
            guard let self else { return }
            self.state.modelInstalled = true
            self.coordinator.reloadModel()
            if case .failed = self.supervisor.state { self.supervisor.restart() }
        }
    }

    // MARK: Support

    private static func openNotices() {
        if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(BuildInfo.website)
        }
    }

    /// A zip of what support needs and nothing it should not see: logs
    /// (timings, states and error types — never content), settings, and the
    /// machine's basics. No memory, no history, no drafts.
    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Leonard-diagnostics.zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("Leonard-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        if let logs = try? fm.contentsOfDirectory(at: AppPaths.logsDirectory, includingPropertiesForKeys: nil) {
            for log in logs { try? fm.copyItem(at: log, to: staging.appendingPathComponent(log.lastPathComponent)) }
        }
        try? fm.copyItem(at: AppPaths.settingsFile, to: staging.appendingPathComponent("app-settings.json"))
        let info = """
        Leonard \(BuildInfo.version) (\(BuildInfo.build))
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Memory: \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB
        Model installed: \(downloader.isInstalled)
        Daemon: \(supervisor.state)
        Connection: \(state.connection)
        Accessibility: \(permissions.accessibility), Mail automation: \(permissions.mailAutomation)
        Entitlement: \(state.entitlement)
        """
        try? info.write(to: staging.appendingPathComponent("system.txt"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: destination)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", staging.path, destination.path]
        try? ditto.run()
        ditto.waitUntilExit()
        try? fm.removeItem(at: staging)
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }
}

extension MenuBarActions {
    static var empty: MenuBarActions {
        MenuBarActions(
            approve: { _ in }, dismiss: { _ in }, setWatching: { _ in }, openCommandBar: {}, openMind: {},
            openMemory: {}, openSettings: {}, openLicense: {}, openOnboarding: {}, quit: {}
        )
    }
}
