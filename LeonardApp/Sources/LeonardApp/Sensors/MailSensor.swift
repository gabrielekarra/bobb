import AppKit
import CoreGraphics
import Foundation
import LeonardCore

/// Watches Mail from the outside, the way a person does: which message is
/// open, and what is being written. Uses Mail's own scripting interface —
/// the same one Shortcuts uses — rather than a plugin inside Mail, and only
/// while Mail is the app in front, so it never launches or wakes Mail.
///
/// Reading is two-step to stay cheap: every tick asks only for the selected
/// message's id; the body is fetched once, when the id changes. Composing is
/// read from the frontmost outgoing message after a pause in typing.
@MainActor
final class MailSensor {
    static let bundleId = "com.apple.mail"

    var onEvent: ((EventFrame) -> Void)?
    var onPermissionDenied: (() -> Void)?

    private let tracker = MailSessionTracker(openAfter: 1.2)
    private let compose = ComposeWatcher()
    private var timer: Timer?
    private var cachedId: String?
    private var cachedMessage: MailMessage?
    private var deniedReported = false
    private var runner: AppleScriptRunner { .shared }

    private static let selectedIdScript = """
    tell application "Mail"
        set sel to selection
        if (count of sel) is 0 then return ""
        return (id of item 1 of sel) as string
    end tell
    """

    private static let selectedMessageScript = """
    tell application "Mail"
        set sel to selection
        if (count of sel) is 0 then return ""
        set m to item 1 of sel
        set us to (character id 31)
        set mb to ""
        try
            set mb to name of mailbox of m
        end try
        return ((id of m) as string) & us & (message id of m) & us & (sender of m) & us & (subject of m) & us & ((read status of m) as string) & us & mb & us & (content of m)
    end tell
    """

    private static let outgoingScript = """
    tell application "Mail"
        set oms to outgoing messages
        if (count of oms) is 0 then return ""
        set om to item -1 of oms
        set us to (character id 31)
        set rcpt to ""
        try
            set rcpt to address of item 1 of to recipients of om
        end try
        return (subject of om) & us & rcpt & us & (content of om)
    end tell
    """

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private var mailIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.bundleId
    }

    private func tick() {
        let now = Date()
        guard mailIsFrontmost else {
            emit(tracker.update(selected: nil, at: now))
            return
        }
        let windowTitle = frontWindowTitle()
        if isComposeWindow(windowTitle) {
            checkCompose()
            return
        }
        do {
            let id = try runner.run(Self.selectedIdScript)
            var selected: MailMessage?
            if !id.isEmpty {
                if id == cachedId, let cachedMessage {
                    selected = cachedMessage
                } else {
                    selected = MailScriptFormat.parseSelected(try runner.run(Self.selectedMessageScript))
                    cachedId = selected?.id
                    cachedMessage = selected
                }
            }
            emit(tracker.update(selected: selected, at: now))
        } catch let failure as AppleScriptRunner.Failure where failure.isPermissionDenied {
            reportDenied()
        } catch {
            // Mail busy or mid-launch: try again next tick.
        }
    }

    private func checkCompose() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        guard idle >= compose.pauseSeconds else { return }
        guard let raw = try? runner.run(Self.outgoingScript), let outgoing = MailScriptFormat.parseOutgoing(raw) else { return }
        guard compose.shouldCheck(draft: outgoing.content, subject: outgoing.subject, keyboardIdle: idle) else { return }
        onEvent?(MailEvents.composing(to: outgoing.to, subject: outgoing.subject, draft: outgoing.content,
                                      idleSeconds: Int(idle), typing: false))
    }

    private func emit(_ signals: [MailSessionTracker.Signal]) {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~UInt32(0))!) >= 90
        for signal in signals {
            switch signal {
            case .opened(let message, let wasUnread):
                onEvent?(MailEvents.opened(message, wasUnread: wasUnread, typing: false, idle: idle))
            case .closed(let message, let dwellMs, let stillUnread):
                onEvent?(MailEvents.closed(message, dwellMs: dwellMs, stillUnread: stillUnread, typing: false, idle: idle))
            }
        }
    }

    private func reportDenied() {
        guard !deniedReported else { return }
        deniedReported = true
        onPermissionDenied?()
    }

    private func frontWindowTitle() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "" }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFocusedWindow" as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return "" }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window as! AXUIElement, "AXTitle" as CFString, &title)
        return title as? String ?? ""
    }

    /// Mail titles a compose window with its subject, or "New Message" /
    /// "Nuovo messaggio" before there is one; the viewer's title is the
    /// mailbox. A reply's title starts with "Re:".
    private func isComposeWindow(_ title: String) -> Bool {
        let lowered = title.lowercased()
        if lowered.hasPrefix("re:") || lowered.hasPrefix("r:") || lowered.hasPrefix("fwd:") || lowered.hasPrefix("i:") { return true }
        return ["new message", "nuovo messaggio"].contains(lowered)
    }
}
