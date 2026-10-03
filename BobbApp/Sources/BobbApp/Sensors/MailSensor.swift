import AppKit
import CoreGraphics
import Foundation
import BobbCore

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
    var permitted: (() -> Bool)?

    private let tracker = MailSessionTracker(openAfter: 1.2)
    private let compose = ComposeWatcher()
    private let replyStart = ReplyStartWatcher()
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

    private static let selectedMessageScript = MailBridge.script

    private static let outgoingScript = """
    on inspectcompose(theTitle)
        tell application "Mail"
            set total to count of outgoing messages
            set shown to 0
            set matched to 0
            repeat with om in outgoing messages
                if visible of om then
                    set shown to shown + 1
                    if subject of om is theTitle then set matched to matched + 1
                end if
            end repeat
            return (total as string) & "," & (shown as string) & "," & (matched as string)
        end tell
    end inspectcompose

    on readcompose(theTitle)
        tell application "Mail"
            set matches to {}
            repeat with om in outgoing messages
                if visible of om and ((subject of om is theTitle) or ((subject of om is "") and (theTitle is "New Message" or theTitle is "Nuovo messaggio"))) then
                    set end of matches to contents of om
                end if
            end repeat
            if (count of matches) is not 1 then return ""
            set om to item 1 of matches
            set us to (character id 31)
            set rcpts to ""
            repeat with rcpt in recipients of om
                set rcpts to rcpts & (address of rcpt) & linefeed
            end repeat
            set sig to ""
            try
                set sig to content of message signature of om
            end try
            set fileCount to -1
            try
                set fileCount to count of attachments of content of om
            end try
            return ((id of om) as string) & us & (subject of om) & us & rcpts & us & sig & us & (fileCount as string) & us & (content of om)
        end tell
    end readcompose
    """

    /// Read-only diagnostics for the native smoke check; never includes
    /// message text, subjects, recipients or other account data.
    func diagnostics() -> [String: Any] {
        let scripts = [Self.selectedIdScript, Self.selectedMessageScript, Self.outgoingScript]
        let compileOK = scripts.allSatisfy { source in
            var error: NSDictionary?
            return NSAppleScript(source: source)?.compileAndReturnError(&error) == true
        }
        return ["accessibilityTrusted": AXIsProcessTrusted(),
                "mailRunning": !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleId).isEmpty,
                "mailFrontmost": mailIsFrontmost, "scriptsCompile": compileOK,
                "composeWindowDetected": frontWindowHasSendButton()]
    }

    /// Inspect each gate without recording any message text or headers.
    /// Used only by the explicit --diagnose-mail development command.
    func liveDiagnostics() -> [String: Any] {
        var result = diagnostics()
        guard permitted?() != false else { result["permitted"] = false; return result }
        result["permitted"] = true
        guard mailIsFrontmost else { return result }
        let title = frontWindowTitle()
        result["replyTitleDetected"] = isComposeWindow(title)
        result["sendButtonDetected"] = frontWindowHasSendButton()
        var stage = "outgoing-counts"
        do {
            let counts = try runner.call(Self.outgoingScript, handler: "inspectcompose", arguments: [title])
                .split(separator: ",").compactMap { Int($0) }
            if counts.count == 3 {
                result["outgoingCount"] = counts[0]
                result["visibleOutgoingCount"] = counts[1]
                result["titleMatches"] = counts[2]
            }
            stage = "compose"
            let outgoing = MailScriptFormat.parseCompose(try runner.call(Self.outgoingScript, handler: "readcompose", arguments: [title]), includesAttachmentCount: true)
            result["composeParsed"] = outgoing != nil
            stage = "original"
            let original = try MailBridge.selected()
            result["originalParsed"] = original != nil
            result["originalHasBody"] = original?.body.isEmpty == false
            if let outgoing {
                result["authoredTextEmpty"] = outgoing.authoredText.isEmpty
                result["recipientCount"] = outgoing.recipients.count
                result["replyMatchesOriginal"] = original.map { outgoing.replies(to: $0) } ?? false
            }
        } catch let AppleScriptRunner.Failure.run(code, _) {
            result["failureStage"] = stage
            result["scriptErrorCode"] = code
        } catch { result["failureStage"] = stage }
        return result
    }

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
        guard permitted?() != false else { cachedId = nil; cachedMessage = nil; return }
        let now = Date()
        guard mailIsFrontmost else {
            emit(tracker.update(selected: nil, at: now))
            return
        }
        let windowTitle = frontWindowTitle()
        if frontWindowHasSendButton() {
            checkCompose(windowTitle: windowTitle)
            return
        }
        compose.reset()
        do {
            let id = try runner.run(Self.selectedIdScript)
            var selected: MailMessage?
            if !id.isEmpty {
                if id == cachedId, let cachedMessage {
                    selected = cachedMessage
                } else {
                    selected = try MailBridge.selected()
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

    private func checkCompose(windowTitle: String) {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        do {
            let raw = try runner.call(Self.outgoingScript, handler: "readcompose", arguments: [windowTitle])
            guard let outgoing = MailScriptFormat.parseCompose(raw, includesAttachmentCount: true) else { return }
            // Read Mail's current selection again: a cached previous email
            // must never supply the body of a different reply.
            let selectedId = try runner.run(Self.selectedIdScript)
            if selectedId != cachedId {
                cachedMessage = try MailBridge.selected()
                cachedId = cachedMessage?.id
            }
            if replyStart.shouldOffer(outgoing, original: cachedMessage, keyboardIdle: idle), let original = cachedMessage {
                onEvent?(MailEvents.replyStarted(original, composeId: outgoing.id, to: outgoing.recipients))
                return
            }
            let authored = outgoing.authoredText
            guard compose.shouldCheck(draft: authored, subject: outgoing.subject, keyboardIdle: idle) else { return }
            let issues = MailDraftChecks.issues(draft: authored, subject: outgoing.subject, recipients: outgoing.recipients, attachmentCount: outgoing.attachmentCount)
            if !issues.isEmpty {
                var event = MailEvents.composing(to: outgoing.recipients.joined(separator: ", "), subject: outgoing.subject,
                                                draft: authored, idleSeconds: Int(idle), typing: false)
                event.kind = .mailDraftCheck
                event.payload.fields["compose_id"] = .string(outgoing.id)
                event.payload.fields["issues"] = .array(issues.map { .string($0) })
                onEvent?(event)
                return
            }
            onEvent?(MailEvents.composing(to: outgoing.recipients.joined(separator: ", "), subject: outgoing.subject,
                                         draft: authored, idleSeconds: Int(idle), typing: false))
        } catch let failure as AppleScriptRunner.Failure where failure.isPermissionDenied {
            reportDenied()
        } catch {
            // Mail is changing windows; sample again next second.
        }
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
        AXUIElementSetMessagingTimeout(element, 0.2)
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
        if ["re:", "r:", "aw:", "sv:", "fwd:", "fw:", "i:"].contains(where: lowered.hasPrefix) { return true }
        return ["new message", "nuovo messaggio"].contains(lowered)
    }

    /// A reader window can also be titled "Re: …". Require Mail's compose
    /// toolbar before reading an outgoing message with that subject.
    private func frontWindowHasSendButton() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        var pending = [raw as! AXUIElement]
        var checked = 0
        let deadline = Date().addingTimeInterval(0.6)
        while let node = pending.popLast(), checked < 180, Date() < deadline {
            checked += 1
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role)
            if role as? String == kAXButtonRole {
                for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
                    var value: CFTypeRef?
                    AXUIElementCopyAttributeValue(node, attribute as CFString, &value)
                    let label = (value as? String ?? "").lowercased()
                    if label == "send" || label == "invia" || label.hasPrefix("send the message") || label.hasPrefix("invia il messaggio") { return true }
                }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
               let children = children as? [AXUIElement] { pending.append(contentsOf: children.reversed()) }
        }
        return false
    }
}
