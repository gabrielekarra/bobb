import AppKit
import ApplicationServices
import BobbCore

/// Only the synthetic localhost page is read. Existing personal tab contents
/// are not logged. Cleanup leaves the user's browser and test tab open.
@MainActor
func runUserBrowserSmokeCheck() {
    Task {
        guard let raw = AppPaths.argument("--check-user-browser"), let url = URL(string: raw),
              ["localhost", "127.0.0.1"].contains(url.host ?? "") else { exit(2) }
        let id = "user-browser-smoke-" + UUID().uuidString
        guard ScreenLease.shared.acquire(id) else { exit(3) }
        let settings = BobbSettings()
        guard let computer = UserBrowserComputer(url: url, preferredApp: AppPaths.argument("--browser-app"),
                settings: { settings }, ownsScreen: { ScreenLease.shared.owner == id }) else { exit(4) }
        let before = NSRunningApplication.runningApplications(withBundleIdentifier: computer.bundleId)
            .filter { !$0.isTerminated && $0.activationPolicy == .regular }.map(\.processIdentifier)
        var automated = false
        let trusted = AXIsProcessTrusted()
        if trusted {
            let query = "Bobb user session test"
            if let initial = await computer.observe(), let field = initial.elements.first(where: { $0.title == "Search query" || $0.description == "Search query" || $0.placeholder == "Search query" }) {
                let typed = await computer.perform(.type(key: field.key, text: query, submit: false))
                await computer.settle()
                if typed == .ok, let filled = await computer.observe(), filled.elements.contains(where: { $0.value == query }),
                   let button = filled.elements.first(where: { ElementClassifier.label(of: $0) == "Search" && ElementClassifier.kind(of: $0) == .press }) {
                    let clicked = await computer.perform(.press(key: button.key)); await computer.settle()
                    if clicked == .ok, let result = await computer.observe() { automated = result.screenText.contains("Results for: " + query) }
                }
            }
        } else { computer.inspect(); try? await Task.sleep(for: .milliseconds(800)) }
        await computer.close(); ScreenLease.shared.release(id)
        let after = NSRunningApplication.runningApplications(withBundleIdentifier: computer.bundleId)
            .filter { !$0.isTerminated && $0.activationPolicy == .regular }.map(\.processIdentifier)
        let reused = before.isEmpty || before.contains(where: after.contains)
        let report: [String: Any] = ["application": computer.applicationName, "bundleId": computer.bundleId,
            "applicationPath": computer.applicationURL.path, "profile": "user_session", "existingPIDs": before,
            "remainingPIDs": after, "reusedExistingApplication": reused, "leftApplicationRunning": !after.isEmpty,
            "accessibilityGranted": trusted, "automationVerified": automated, "detail": computer.error,
            "passed": reused && !after.isEmpty && trusted && automated]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            if let path = AppPaths.argument("--report") { try? data.write(to: URL(fileURLWithPath: path)) }
            print(String(decoding: data, as: UTF8.self))
        }
        exit(reused && !after.isEmpty && trusted && automated ? 0 : 1)
    }
}
