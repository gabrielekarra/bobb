import AppKit
import Foundation
import BobbCore

/// Opens a real reply window in Mail with Bobb's draft in it. Never
/// sends: the user reads it, edits it and presses Send themselves.
///
/// The reply is opened through Mail's scripting interface (the message is
/// found by its Message-ID, in the current selection first because that is
/// nearly always where it is), then the draft is pasted at the cursor, which
/// Mail places at the top of a new reply above the quoted original. Setting
/// the reply's `content` by script would replace the quote, and on recent
/// macOS versions does not display reliably, so it is not used.
@MainActor
enum MailComposer {
    enum Outcome {
        case opened
        case notFound
        case failed(String)
    }

    static let replyScript = """
    on canonical(theId)
        if theId starts with "<" and theId ends with ">" then return text 2 thru -2 of theId
        return theId
    end canonical

    on openreply(theId, mode, followupTo)
        tell application "Mail"
            set target to missing value
            repeat with m in (selection as list)
                if my canonical(message id of m) is my canonical(theId) then
                    set target to contents of m
                    exit repeat
                end if
            end repeat
            if target is missing value then
                set found to (messages of inbox whose message id is theId)
                if (count of found) is 0 then set found to (messages of inbox whose message id is ("<" & theId & ">"))
                if (count of found) > 0 then set target to item 1 of found
            end if
            if target is missing value then
                set found to (messages of sent mailbox whose message id is theId)
                if (count of found) is 0 then set found to (messages of sent mailbox whose message id is ("<" & theId & ">"))
                if (count of found) > 0 then set target to item 1 of found
            end if
            if target is missing value then set target to my findmessage(theId)
            if target is missing value then return "notfound"
            if mode is "forward" then
                set om to forward target with opening window
            else if mode is "replyall" then
                set om to reply target with opening window and reply to all
            else
                set om to reply target with opening window
            end if
            if mode is "followup" then
                delete every to recipient of om
                delete every cc recipient of om
                set AppleScript's text item delimiters to ","
                set targets to text items of followupTo
                set AppleScript's text item delimiters to ""
                repeat with target in targets
                    if target is not "" then
                        tell om to make new to recipient at end of to recipients with properties {address:contents of target}
                    end if
                end repeat
            end if
            activate
            return (id of om) as string
        end tell
    end openreply
    """

    static let newScript = """
    on newdraft(theSubject, theBody, theTo)
        tell application "Mail"
            set om to make new outgoing message with properties {subject:theSubject, content:theBody, visible:true}
            set AppleScript's text item delimiters to linefeed
            set targets to text items of theTo
            set AppleScript's text item delimiters to ""
            repeat with target in targets
                if target is not "" then
                    tell om to make new to recipient at end of to recipients with properties {address:contents of target}
                end if
            end repeat
            activate
            return (id of om) as string
        end tell
    end newdraft
    """

    private static let existingReplyScript = """
    on readreply(theId)
        tell application "Mail"
            set found to (outgoing messages whose id is (theId as integer))
            if (count of found) is not 1 then return ""
            set om to item 1 of found
            if not (visible of om) then return ""
            set matchingWindows to (outgoing messages whose visible is true and subject is (subject of om))
            if (count of matchingWindows) is not 1 then return ""
            set us to (character id 31)
            set rcpts to ""
            repeat with r in recipients of om
                set rcpts to rcpts & (address of r) & linefeed
            end repeat
            set sig to ""
            try
                set sig to content of message signature of om
            end try
            return ((id of om) as string) & us & (subject of om) & us & rcpts & us & sig & us & (content of om)
        end tell
    end readreply
    """

    static func reply(messageId: String, body: String, composeId: String? = nil, replyAll: Bool = false, forward: Bool = false,
                      followupTo: String? = nil, permitted: @MainActor () -> Bool = { true }) async -> Outcome {
        guard permitted() else { return .notFound }
        if let composeId { return await insertInExistingReply(composeId: composeId, body: body, permitted: permitted) }
        let outgoingId: String
        do {
            outgoingId = try AppleScriptRunner.shared.call(MailBridge.script + "\n" + replyScript, handler: "openreply", arguments: [MailHeaders.canonicalID(messageId),
                followupTo != nil ? "followup" : forward ? "forward" : replyAll ? "replyall" : "reply",
                (followupTo ?? "").components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: ",")])
            guard Int(outgoingId) != nil else { return .notFound }
        } catch {
            return .failed(String(describing: error))
        }
        try? await Task.sleep(for: .milliseconds(350))
        return await insertInExistingReply(composeId: outgoingId, body: body, permitted: permitted)
    }

    static func newDraft(subject: String, body: String, recipients: [String]) -> Outcome {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              recipients.allSatisfy({ !$0.contains("\n") && !$0.contains("\r") }) else { return .notFound }
        do {
            let result = try AppleScriptRunner.shared.call(newScript, handler: "newdraft", arguments: [subject, body, recipients.joined(separator: "\n")])
            return Int(result) == nil ? .notFound : .opened
        } catch { return .failed(String(describing: error)) }
    }

    static func canInsert(composeId: String, messageId: String) -> Bool {
        guard AXIsProcessTrusted(), CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) >= 0.7,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.mail",
              let raw = try? AppleScriptRunner.shared.call(existingReplyScript, handler: "readreply", arguments: [composeId]),
              let snapshot = MailScriptFormat.parseCompose(raw), snapshot.authoredText.isEmpty,
              let original = try? MailBridge.selected(), MailHeaders.canonicalID(original.messageId) == MailHeaders.canonicalID(messageId),
              snapshot.replies(to: original), let mail = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").first,
              let window = AX.element(AX.application(mail.processIdentifier), "AXFocusedWindow"),
              AX.string(window, "AXTitle") == snapshot.subject else { return false }
        return true
    }

    static func insertAutomatically(composeId: String, messageId: String, body: String, permitted: @MainActor () -> Bool) async -> Outcome {
        guard permitted(), canInsert(composeId: composeId, messageId: messageId) else { return .notFound }
        return await insertInExistingReply(composeId: composeId, body: body,
            permitted: { permitted() && canInsert(composeId: composeId, messageId: messageId) }, activate: false)
    }

    /// Reuse the reply that triggered the offer. If it was closed, changed
    /// or replaced by another window, leave the user's writing untouched.
    private static func insertInExistingReply(composeId: String, body: String, permitted: @MainActor () -> Bool, activate: Bool = true) async -> Outcome {
        guard permitted(), AXIsProcessTrusted(),
              let mail = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").first else { return .notFound }
        if activate {
            mail.activate()
            try? await Task.sleep(for: .milliseconds(180))
        }
        do {
            let raw = try AppleScriptRunner.shared.call(existingReplyScript, handler: "readreply", arguments: [composeId])
            guard permitted(), let snapshot = MailScriptFormat.parseCompose(raw), snapshot.authoredText.isEmpty,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.mail" else { return .notFound }
            let app = AX.application(mail.processIdentifier)
            guard let window = AX.element(app, "AXFocusedWindow"), AX.string(window, "AXTitle") == snapshot.subject else { return .notFound }
            var queue = [window]
            var head = 0
            let deadline = Date().addingTimeInterval(2)
            while head < queue.count, head < 250, Date() < deadline {
                let node = queue[head]; head += 1
                if AX.string(node, "AXRole") == "AXTextArea", !AX.isSecure(node) {
                    var settable = DarwinBoolean(false)
                    guard AXUIElementIsAttributeSettable(node, "AXSelectedTextRange" as CFString, &settable) == .success,
                          settable.boolValue else { continue }
                    var start = CFRange(location: 0, length: 0)
                    guard let range = AXValueCreate(.cfRange, &start),
                          AXUIElementSetAttributeValue(node, "AXFocused" as CFString, kCFBooleanTrue) == .success,
                          AXUIElementSetAttributeValue(node, "AXSelectedTextRange" as CFString, range) == .success else { return .notFound }
                    guard permitted(), !Task.isCancelled else { return .notFound }
                    // Direct AX insertion preserves the clipboard and has no
                    // suspension between checking the draft and inserting.
                    let inserted = AXUIElementSetAttributeValue(node, "AXSelectedText" as CFString, (body + "\n\n") as CFString)
                    if inserted != .success {
                        guard permitted(), !Task.isCancelled else { return .notFound }
                        await Clipboard.paste(body + "\n\n")
                    }
                    let verified = try AppleScriptRunner.shared.call(existingReplyScript, handler: "readreply", arguments: [composeId])
                    guard let result = MailScriptFormat.parseCompose(verified), result.authoredText.contains(body.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        return .failed("Mail did not confirm the inserted text")
                    }
                    return .opened
                }
                queue.append(contentsOf: AX.children(node))
            }
            return .notFound
        } catch { return .failed(String(describing: error)) }
    }
}
