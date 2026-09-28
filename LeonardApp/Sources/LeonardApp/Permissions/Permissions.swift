import AppKit
import ApplicationServices
import Observation

/// The two permissions Leonard needs, and nothing else: Accessibility, to
/// read the text of the window in front of the user and insert what it
/// writes; and Automation of Mail, to read the open message and open a
/// reply window. Both are asked for in onboarding with the reason shown
/// first, and both can be checked at any time without prompting.
@MainActor
@Observable
final class Permissions {
    enum Status: Equatable {
        case granted
        case denied
        case notDetermined
        /// Mail is not running, so macOS cannot say yet.
        case unknown
    }

    private(set) var accessibility: Status = .notDetermined
    private(set) var mailAutomation: Status = .unknown
    private var pollTimer: Timer?

    init() {
        refresh()
    }

    func refresh() {
        accessibility = AXIsProcessTrusted() ? .granted : .notDetermined
        let mail = Self.automationStatus(bundleId: "com.apple.mail", ask: false)
        if mail != .unknown || mailAutomation == .unknown {
            mailAutomation = mail
        }
    }

    /// Shows macOS's own Accessibility prompt, then watches for the switch
    /// to be turned on in System Settings — which happens in another app,
    /// so there is no callback, only a poll that stops once it is granted.
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                if self.accessibility == .granted {
                    self.pollTimer?.invalidate()
                    self.pollTimer = nil
                }
            }
        }
    }

    /// Asks macOS for permission to send Apple Events to Mail. The call
    /// blocks until the user answers the system dialog, so it runs off the
    /// main thread; Mail is launched first because macOS can only ask about
    /// a running app.
    func requestMailAutomation() {
        let mailURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail")
        let open: @Sendable () -> Void = {
            DispatchQueue.global(qos: .userInitiated).async {
                let status = Self.automationStatus(bundleId: "com.apple.mail", ask: true)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.mailAutomation = status }
                }
            }
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty, let mailURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            NSWorkspace.shared.openApplication(at: mailURL, configuration: configuration) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { open() }
            }
        } else {
            open()
        }
    }

    nonisolated static func automationStatus(bundleId: String, ask: Bool) -> Status {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
        guard let desc = target.aeDesc else { return .unknown }
        let status = Int(AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask))
        if status == Int(noErr) { return .granted }
        if status == Int(errAEEventNotPermitted) { return .denied }
        if status == Int(errAEEventWouldRequireUserConsent) { return .notDetermined }
        return .unknown
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openAutomationSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
