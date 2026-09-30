import AppKit
import Foundation

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

    private static let replyScript = """
    on openreply(theId)
        tell application "Mail"
            set target to missing value
            repeat with m in (selection as list)
                if (message id of m) is theId then
                    set target to contents of m
                    exit repeat
                end if
            end repeat
            if target is missing value then
                set found to (messages of inbox whose message id is theId)
                if (count of found) > 0 then set target to item 1 of found
            end if
            if target is missing value then return "notfound"
            reply target with opening window
            activate
            return "ok"
        end tell
    end openreply
    """

    static func reply(messageId: String, body: String) async -> Outcome {
        do {
            let result = try AppleScriptRunner.shared.call(replyScript, handler: "openreply", arguments: [messageId])
            guard result == "ok" else { return .notFound }
        } catch {
            return .failed(String(describing: error))
        }
        // Wait for the compose window to take focus before pasting into it.
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.mail" { break }
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
        await Clipboard.paste(body + "\n")
        return .opened
    }
}
