import AppKit
import ApplicationServices
import BobbCore

/// Uses native controls in the user's browser, with its ordinary macOS URL handler.
@MainActor
final class UserBrowserComputer: TaskDriver {
    let applicationURL: URL
    let bundleId: String
    let applicationName: String
    private let settings: () -> BobbSettings
    private let ownsScreen: () -> Bool
    private let native: NativeComputer
    private var startURL: URL?
    private var prepared = false, closed = false
    private var expectedPID: pid_t?
    private var expectedWindow: AXUIElement?
    private var mayNavigateUntil = Date.distantPast
    private(set) var currentURL: URL?
    private(set) var error = ""

    init?(url: URL? = nil, goal: String = "", preferredApp: String? = nil, settings: @escaping () -> BobbSettings, ownsScreen: @escaping () -> Bool) {
        let lookup = url ?? URL(string: "https://example.invalid/")!
        let workspace = NSWorkspace.shared
        var locations: [String: URL] = [:]
        let candidates: [UserApplication] = workspace.urlsForApplications(toOpen: lookup).compactMap { location in
            guard let id = Bundle(url: location)?.bundleIdentifier, locations[id] == nil,
                  id != Bundle.main.bundleIdentifier else { return nil }
            locations[id] = location
            let name = location.deletingPathExtension().lastPathComponent
            let short = id.split(separator: ".").last.map(String.init) ?? name
            return UserApplication(bundleId: id, name: name, aliases: [short])
        }
        let front = workspace.frontmostApplication
        let defaultID = workspace.urlForApplication(toOpen: lookup).flatMap { Bundle(url: $0)?.bundleIdentifier }
        guard let selected = UserApplicationSelection.browser(goal: goal, active: preferredApp ?? front?.bundleIdentifier,
                defaultBrowser: defaultID, candidates: candidates), let location = locations[selected.bundleId] else { return nil }
        let config = settings()
        guard config.bobb.boundaries.app(bundleId: selected.bundleId, name: selected.name) != nil,
              !ActionPolicy(extraProtected: config.extraProtectedApps).isProtected(bundleId: selected.bundleId, appName: selected.name) else { return nil }
        applicationURL = location; bundleId = selected.bundleId; applicationName = selected.name
        self.settings = settings; self.ownsScreen = ownsScreen
        let primary = AXDriver(); primary.settings = settings; primary.stillOwnsScreen = ownsScreen
        native = NativeComputer(primary: primary, fallback: CUANativeComputer(settings: settings, ownsScreen: ownsScreen))
        startURL = url
        if let url, !permits(url) { return nil }
        if front?.bundleIdentifier == bundleId { expectedPID = front?.processIdentifier }
    }
    func open(_ url: URL) -> Bool {
        guard !closed, permits(url) else { return false }
        startURL = url; prepared = false; currentURL = nil; error = ""; return true
    }
    private func permits(_ url: URL) -> Bool {
        let s = settings()
        guard ["http", "https"].contains(url.scheme ?? ""), let host = url.host,
              url.user == nil, url.password == nil, s.actingEnabled, s.bobb.boundaries.canWork(),
              let app = s.bobb.boundaries.app(bundleId: bundleId, name: applicationName), app.mode(.navigate) != .deny,
              let site = s.bobb.boundaries.webApp(host: host, browserBundleId: bundleId, browserName: applicationName) else { return false }
        return site.mode(.navigate) != .deny
    }
    private func prepare() async -> Bool {
        guard !closed, !Task.isCancelled, ownsScreen(), AXIsProcessTrusted(),
              let url = startURL, permits(url) else { error = "accessibilityRequired"; return false }
        let previousPage = runningApplication().flatMap { AX.pageURL(pid: $0.processIdentifier) }
        if let app = runningApplication() { app.activate() }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true; configuration.createsNewApplicationInstance = false
        let pid: pid_t? = await withCheckedContinuation { continuation in
            NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: configuration) { app, _ in
                continuation.resume(returning: app?.processIdentifier)
            }
        }
        guard let pid, !Task.isCancelled, ownsScreen() else { error = "browserOpenFailed"; return false }
        expectedPID = pid
        error = "browserPageUnavailable"
        for _ in 0..<40 {
            guard !Task.isCancelled, ownsScreen() else { return false }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
               let page = AX.pageURL(pid: pid), permits(page),
               Self.arrived(page, requested: url, previous: previousPage) {
                expectedWindow = AX.element(AX.application(pid), "AXFocusedWindow")
                currentURL = page; prepared = true; error = ""; return true
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                error = "browserNotFrontmost"
            } else if AX.element(AX.application(pid), "AXFocusedWindow") == nil {
                error = "browserWindowUnavailable"
            } else if let page = AX.pageURL(pid: pid) {
                error = permits(page) ? "browserNavigationUnverified" : "unavailableWebsite"
            } else {
                error = "browserPageUnavailable"
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }
    private static func arrived(_ page: URL, requested: URL, previous: URL?) -> Bool {
        func canonical(_ value: URL) -> String {
            var parts = URLComponents(url: value, resolvingAgainstBaseURL: false)
            if parts?.path.isEmpty == true { parts?.path = "/" }
            parts?.fragment = nil
            return parts?.string ?? value.absoluteString
        }
        if canonical(page) == canonical(requested) { return true }
        // Same-site redirects can settle; an unchanged unrelated tab cannot.
        return page != previous && page.host == requested.host
    }
    func observe() async -> ScreenObservation? {
        guard !closed, ownsScreen(), !Task.isCancelled else { return nil }
        if !prepared, !(await prepare()) { return unavailable() }
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == expectedPID else {
            error = "applicationChanged"; return unavailable()
        }
        guard let liveWindow = AX.element(AX.application(front.processIdentifier), "AXFocusedWindow"),
              expectedWindow.map({ CFEqual($0, liveWindow) }) == true else { error = "windowChanged"; return unavailable() }
        if front.bundleIdentifier == bundleId {
            guard let page = AX.pageURL(pid: front.processIdentifier), permits(page) else {
                error = "unavailableWebsite"; return unavailable()
            }
            guard page == currentURL || Date() < mayNavigateUntil else { error = "browserTabChanged"; return unavailable() }
            currentURL = page
        } else { currentURL = nil }
        guard var screen = await native.observe(), screen.bundleId == front.bundleIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID else { return unavailable() }
        if let currentURL {
            screen.sourceURL = currentURL.absoluteString
            if !screen.screenText.hasPrefix("Source URL:") { screen.screenText = "Source URL: \(currentURL.absoluteString)\n" + screen.screenText }
        }
        error = ""; return screen
    }
    func perform(_ action: DriverAction) async -> DriverResult {
        guard !closed, ownsScreen(), !Task.isCancelled, AXIsProcessTrusted(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID else { return .stale }
        guard let pid = expectedPID, let window = AX.element(AX.application(pid), "AXFocusedWindow"),
              expectedWindow.map({ CFEqual($0, window) }) == true else { return .stale }
        if let currentURL {
            guard let pid = expectedPID, AX.pageURL(pid: pid) == currentURL, permits(currentURL) else { return .stale }
        }
        let result = await native.perform(action)
        if result == .ok { mayNavigateUntil = Date().addingTimeInterval(10) }
        if case .openApp = action, result == .ok {
            expectedPID = NSWorkspace.shared.frontmostApplication?.processIdentifier; currentURL = nil
            expectedWindow = expectedPID.flatMap { AX.element(AX.application($0), "AXFocusedWindow") }
        }
        return result
    }
    func installedApps() -> [String] { native.installedApps() }
    func bundleIdentifier(forApp name: String) -> String? { native.bundleIdentifier(forApp: name) }
    func offeredKeys(for observation: ScreenObservation) -> [KeyChord] { native.offeredKeys(for: observation) }
    func permissionDetail(for action: DriverAction) -> String? { native.permissionDetail(for: action) }
    func settle() async { await native.settle() }
    func undoLast() async -> Bool { await native.undoLast() }
    func completionProblem(goal: String) async -> String? { error.isEmpty ? await native.completionProblem(goal: goal) : error }
    func close() async { closed = true; await native.close() }
    /// Focus remains available after completion; cleanup never quits the app.
    func inspect() {
        guard settings().bobb.boundaries.app(bundleId: bundleId, name: applicationName) != nil else { return }
        if let app = runningApplication() { app.activate(); return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true; configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, _ in }
    }
    private func runningApplication() -> NSRunningApplication? {
        if let expectedPID, let app = NSRunningApplication(processIdentifier: expectedPID),
           !app.isTerminated, app.bundleIdentifier == bundleId { return app }
        return NSWorkspace.shared.runningApplications.first { !$0.isTerminated && $0.bundleIdentifier == bundleId && $0.activationPolicy == .regular }
    }
    private func unavailable() -> ScreenObservation {
        ScreenObservation(app: applicationName, bundleId: bundleId, window: "", elements: [], screenText: error, unreadable: true)
    }
}
