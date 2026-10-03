import AppKit
import BobbCore

/// Fixed, read-only Mail scripts. External text is passed as handler
/// arguments; only the resulting structured snapshot enters the daemon.
@MainActor
enum MailBridge {
    static let script = """
    on snapshot(m, boxKind)
        tell application "Mail"
            set us to character id 31
            set mb to ""
            set accountName to ""
            try
                set mb to name of mailbox of m
                set accountName to name of account of mailbox of m
            end try
            set rcpts to ""
            repeat with r in to recipients of m
                set rcpts to rcpts & (address of r) & ", "
            end repeat
            set copied to ""
            repeat with r in cc recipients of m
                set copied to copied & (address of r) & ", "
            end repeat
            set files to ""
            try
                repeat with a in mail attachments of m
                    set files to files & (name of a) & linefeed
                end repeat
            end try
            set stamp to date received of m
            if boxKind is "sent" then set stamp to date sent of m
            set contentText to content of m
            if (length of contentText) > 64000 then set contentText to text 1 thru 64000 of contentText
            return ((id of m) as string) & us & (message id of m) & us & (sender of m) & us & (subject of m) & us & ((read status of m) as string) & us & mb & us & (reply to of m) & us & (stamp as «class isot» as string) & us & rcpts & us & copied & us & files & us & (all headers of m) & us & accountName & us & ((flagged status of m) as string) & us & contentText
        end tell
    end snapshot

    on readselected()
        if application "Mail" is not running then return ""
        tell application "Mail"
            set sel to selection
            if (count of sel) is not 1 then return ""
            set m to item 1 of sel
        end tell
        return my snapshot(m, "received")
    end readselected

    on readbatch(boxKind, requested)
        if application "Mail" is not running then return ""
        with timeout of 4 seconds
            tell application "Mail"
                if boxKind is "sent" then
                    set box to sent mailbox
                else
                    set box to inbox
                end if
                set n to count of messages of box
                set cap to requested as integer
                if cap > 50 then set cap to 50
                if n > cap then set n to cap
                set out to ""
                repeat with i from 1 to n
                    set m to message i of box
                    try
                        set out to out & my snapshot(m, boxKind) & (character id 30)
                    end try
                end repeat
                return out
            end tell
        end timeout
    end readbatch

    on collectboxes(boxes, accountId, accountName, parentPath, ownAddresses)
        set out to ""
        tell application "Mail"
            repeat with box in boxes
                set boxName to name of box
                set boxPath to parentPath & boxName
                set n to count of messages of box
                set out to out & accountId & (character id 31) & accountName & (character id 31) & boxPath & (character id 31) & (n as string) & (character id 31) & ownAddresses & (character id 30)
                set children to mailboxes of box
                if (count of children) > 0 then set out to out & my collectboxes(children, accountId, accountName, boxPath & linefeed, ownAddresses)
            end repeat
        end tell
        return out
    end collectboxes

    on archiveboxes()
        if application "Mail" is not running then return ""
        with timeout of 20 seconds
            set out to ""
            tell application "Mail"
                repeat with acct in accounts
                    if enabled of acct then
                        set ownAddresses to ""
                        repeat with addr in email addresses of acct
                            set ownAddresses to ownAddresses & (contents of addr) & linefeed
                        end repeat
                        set out to out & my collectboxes(mailboxes of acct, id of acct, name of acct, "", ownAddresses)
                    end if
                end repeat
                -- Application-level mailboxes include local folders. Account
                -- folders are already enumerated above, so exclude duplicates.
                repeat with box in mailboxes
                    set isLocal to false
                    try
                        set isLocal to (account of box is missing value)
                    on error
                        set isLocal to true
                    end try
                    if isLocal then set out to out & my collectboxes({contents of box}, "", "On My Mac", "", "")
                end repeat
            end tell
            return out
        end timeout
    end archiveboxes

    on archivepage(accountId, boxPath, offsetText, requested)
        if application "Mail" is not running then error "Mail closed during synchronization" number -600
        with timeout of 8 seconds
            tell application "Mail"
                if accountId is "" then
                    set parentBox to application "Mail"
                else
                    set parentBox to account id accountId
                end if
                set AppleScript's text item delimiters to linefeed
                set parts to text items of boxPath
                set AppleScript's text item delimiters to ""
                repeat with part in parts
                    set parentBox to mailbox (contents of part) of parentBox
                end repeat
                set n to count of messages of parentBox
                set cursor to offsetText as integer
                set cap to requested as integer
                if cap > 10 then set cap to 10
                set ending to cursor + cap
                if ending > n then set ending to n
                set out to ""
                set failures to 0
                repeat while cursor < ending
                    set cursor to cursor + 1
                    try
                        set m to message cursor of parentBox
                        set out to out & my snapshot(m, "archive") & (character id 30)
                    on error errText number errCode
                        if errCode is -1743 or errCode is -1744 then error errText number errCode
                        set failures to failures + 1
                    end try
                end repeat
                return (cursor as string) & (character id 31) & (n as string) & (character id 31) & (failures as string) & (character id 30) & out
            end tell
        end timeout
    end archivepage

    on canonicalmailid(theId)
        if theId starts with "<" and theId ends with ">" then return text 2 thru -2 of theId
        return theId
    end canonicalmailid

    on findinboxes(boxes, theId)
        tell application "Mail"
            repeat with box in boxes
                set found to (messages of box whose message id is theId)
                if (count of found) is 0 then set found to (messages of box whose message id is ("<" & theId & ">"))
                if (count of found) > 0 then return item 1 of found
                set children to mailboxes of box
                if (count of children) > 0 then
                    set foundMessage to my findinboxes(children, theId)
                    if foundMessage is not missing value then return foundMessage
                end if
            end repeat
        end tell
        return missing value
    end findinboxes

    on findmessage(theId)
        if application "Mail" is not running then return missing value
        set theId to my canonicalmailid(theId)
        tell application "Mail"
            repeat with m in selection
                if my canonicalmailid(message id of m) is theId then return contents of m
            end repeat
            repeat with acct in accounts
                if enabled of acct then
                    set foundMessage to my findinboxes(mailboxes of acct, theId)
                    if foundMessage is not missing value then return foundMessage
                end if
            end repeat
            return my findinboxes(mailboxes, theId)
        end tell
    end findmessage

    on changemessage(theId, operation)
        with timeout of 20 seconds
            set m to my findmessage(theId)
            if m is missing value then return ""
            tell application "Mail"
                if operation is "read" then
                    set read status of m to true
                else if operation is "unread" then
                    set read status of m to false
                else if operation is "flag" then
                    set flagged status of m to true
                else if operation is "unflag" then
                    set flagged status of m to false
                else
                    error "Unsupported message action"
                end if
                set verified to false
                if operation is "read" then set verified to (read status of m is true)
                if operation is "unread" then set verified to (read status of m is false)
                if operation is "flag" then set verified to (flagged status of m is true)
                if operation is "unflag" then set verified to (flagged status of m is false)
                if not verified then error "Mail did not confirm the change"
            end tell
            return my snapshot(m, "archive")
        end timeout
    end changemessage
    """

    static func selected() throws -> MailMessage? {
        MailScriptFormat.parseSelected(try AppleScriptRunner.shared.call(script, handler: "readselected", arguments: []), includesMetadata: true, includesAccount: true, includesFlag: true)
    }

    static func batch(sent: Bool, limit: Int = 30) throws -> [MailMessage] {
        let output = try AppleScriptRunner.shared.call(script, handler: "readbatch", arguments: [sent ? "sent" : "inbox", String(min(50, max(1, limit)))])
        return output.components(separatedBy: MailScriptFormat.record).compactMap { MailScriptFormat.parseSelected($0, includesMetadata: true, includesAccount: true, includesFlag: true) }
    }

    struct Mailbox: Identifiable, Sendable {
        var accountId: String
        var account: String
        var path: String
        var count: Int
        var addresses: [String]
        var id: String { accountId + "\u{1F}" + path }
        var label: String { account + " · " + path.replacingOccurrences(of: "\n", with: " / ") }
        func sent(_ message: MailMessage) -> Bool {
            let sender = message.sender.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return addresses.contains { sender == $0.lowercased() || sender.contains("<" + $0.lowercased() + ">") }
                || ["sent", "sent messages", "inviata", "posta inviata"].contains(path.components(separatedBy: "\n").last?.lowercased() ?? "")
        }
    }

    struct Page: Sendable {
        var messages: [MailMessage]
        var next: Int
        var total: Int
        var failures: Int
    }

    static func mailboxes() throws -> [Mailbox] {
        let raw = try AppleScriptRunner.shared.call(script, handler: "archiveboxes", arguments: [])
        var seen = Set<String>()
        return raw.components(separatedBy: MailScriptFormat.record).compactMap { record in
            let f = record.components(separatedBy: MailScriptFormat.unit)
            guard f.count == 5, let count = Int(f[3]) else { return nil }
            let box = Mailbox(accountId: f[0], account: f[1], path: f[2], count: count,
                              addresses: f[4].components(separatedBy: "\n").filter { !$0.isEmpty })
            return seen.insert(box.id).inserted ? box : nil
        }
    }

    static func page(_ box: Mailbox, offset: Int) throws -> Page {
        let raw = try AppleScriptRunner.shared.call(script, handler: "archivepage", arguments: [box.accountId, box.path, String(max(0, offset)), "10"])
        let records = raw.components(separatedBy: MailScriptFormat.record)
        let f = (records.first ?? "").components(separatedBy: MailScriptFormat.unit)
        guard f.count == 3, let next = Int(f[0]), let total = Int(f[1]), let failures = Int(f[2]) else {
            throw AppleScriptRunner.Failure.run(-1, "Invalid Mail archive page")
        }
        let rawMessages = records.dropFirst().filter { !$0.isEmpty }
        let messages = rawMessages.compactMap { MailScriptFormat.parseSelected($0, includesMetadata: true, includesAccount: true, includesFlag: true) }
            .filter { !MailHeaders.canonicalID($0.messageId).isEmpty }
        return Page(messages: messages, next: next, total: total, failures: failures + rawMessages.count - messages.count)
    }

    static func change(_ identifier: String, operation: String) throws -> MailMessage? {
        guard ["read", "unread", "flag", "unflag"].contains(operation) else { return nil }
        let raw = try AppleScriptRunner.shared.call(script, handler: "changemessage", arguments: [identifier, operation])
        return MailScriptFormat.parseSelected(raw, includesMetadata: true, includesAccount: true, includesFlag: true)
    }

    static func snapshot(_ message: MailMessage, sent: Bool = false) -> JSONValue {
        var fields = EmailItem(message: message, direction: sent ? "sent" : "received").snapshot.objectValue ?? [:]
        fields["list_id"] = .string(message.headers.listId)
        fields["automatic"] = .bool(message.headers.automatic)
        return .object(fields)
    }
}
