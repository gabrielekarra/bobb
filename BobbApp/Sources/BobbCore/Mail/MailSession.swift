import Foundation

/// One message as Mail reports it through its scripting interface.
public struct MailMessage: Sendable, Equatable {
    public var id: String
    public var messageId: String
    public var sender: String
    public var subject: String
    public var body: String
    public var read: Bool
    public var mailbox: String
    public var replyTo: String
    public var to: String
    public var cc: String
    public var date: Date?
    public var attachments: [String]
    public var headers: MailHeaders
    public var account: String
    public var flagged: Bool

    public init(id: String, messageId: String, sender: String, subject: String, body: String, read: Bool, mailbox: String, replyTo: String = "",
                to: String = "", cc: String = "", date: Date? = nil, attachments: [String] = [], headers: MailHeaders = MailHeaders(), account: String = "", flagged: Bool = false) {
        self.id = id
        self.messageId = messageId
        self.sender = sender
        self.subject = subject
        self.body = body
        self.read = read
        self.mailbox = mailbox
        self.replyTo = replyTo
        self.to = to; self.cc = cc; self.date = date; self.attachments = attachments; self.headers = headers
        self.account = account
        self.flagged = flagged
    }
}

/// The delimiters the AppleScript bridge joins fields with. Unit and record
/// separators never appear in mail headers or bodies, unlike tabs or pipes.
public enum MailScriptFormat {
    public static let unit = "\u{1F}"

    /// Parses `id␟message id␟sender␟subject␟read␟mailbox␟content`.
    public static func parseSelected(_ output: String, includesReplyTo: Bool = false, includesMetadata: Bool = false, includesAccount: Bool = false, includesFlag: Bool = false) -> MailMessage? {
        let fields = output.components(separatedBy: unit)
        let bodyIndex = includesMetadata ? (includesAccount ? (includesFlag ? 14 : 13) : 12) : includesReplyTo ? 7 : 6
        guard fields.count > bodyIndex, !fields[0].isEmpty else { return nil }
        return MailMessage(
            id: fields[0],
            messageId: fields[1],
            sender: fields[2],
            subject: fields[3],
            body: fields[bodyIndex...].joined(separator: unit),
            read: fields[4].lowercased() == "true",
            mailbox: fields[5],
            replyTo: includesReplyTo || includesMetadata ? fields[6] : "",
            to: includesMetadata ? fields[8] : "", cc: includesMetadata ? fields[9] : "",
            date: includesMetadata ? isoDate(fields[7]) : nil,
            attachments: includesMetadata ? fields[10].components(separatedBy: "\n").filter { !$0.isEmpty } : [],
            headers: includesMetadata ? MailHeaders(raw: fields[11]) : MailHeaders(),
            account: includesMetadata && includesAccount ? fields[12] : "",
            flagged: includesMetadata && includesAccount && includesFlag && fields[13].lowercased() == "true"
        )
    }

    /// Parses `subject␟recipient␟content` of the frontmost outgoing message.
    public static func parseOutgoing(_ output: String) -> (subject: String, to: String, content: String)? {
        let fields = output.components(separatedBy: unit)
        guard fields.count >= 3 else { return nil }
        return (fields[0], fields[1], fields[2...].joined(separator: unit))
    }

    /// `id␟subject␟recipients (one per line)␟signature␟content`.
    public static func parseCompose(_ output: String, includesAttachmentCount: Bool = false) -> MailComposeSnapshot? {
        let fields = output.components(separatedBy: unit)
        let bodyIndex = includesAttachmentCount ? 5 : 4
        guard fields.count > bodyIndex, !fields[0].isEmpty else { return nil }
        return MailComposeSnapshot(id: fields[0], subject: fields[1],
            recipients: fields[2].components(separatedBy: "\n").filter { !$0.isEmpty },
            content: fields[bodyIndex...].joined(separator: unit), signature: fields[3],
            attachmentCount: includesAttachmentCount ? Int(fields[4]) ?? -1 : -1)
    }

    /// Mail's scripting interface has no thread count. Replies quote what
    /// they answer, so the number of quote headers plus one is a fair
    /// estimate, and a `Re:` subject is at least two.
    public static func estimateThreadLength(subject: String, body: String) -> Int {
        let patterns = [
            #"(?m)^On .{3,120} wrote:\s*$"#,
            #"(?m)^Il giorno .{3,120} ha scritto:\s*$"#,
            #"(?m)^-{2,} ?(Original Message|Messaggio originale) ?-{2,}"#,
            #"(?m)^(From|Da): .+$"#,
        ]
        var quotes = 0
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                quotes += regex.numberOfMatches(in: body, range: NSRange(body.startIndex..., in: body))
            }
        }
        let isReply = subject.range(of: #"^\s*(re|r|aw|sv)\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil
        return max(quotes + 1, isReply ? 2 : 1)
    }

    /// The part of a body a person actually wrote: everything above the
    /// first quote header, so a long thread does not bury the new message.
    public static func newestPart(of body: String, limit: Int = 6000) -> String {
        let markers = [
            #"(?m)^On .{3,120} wrote:\s*$"#,
            #"(?m)^Il giorno .{3,120} ha scritto:\s*$"#,
            #"(?m)^-{2,} ?(Original Message|Messaggio originale) ?-{2,}"#,
        ]
        var cut = body.endIndex
        for pattern in markers {
            if let range = body.range(of: pattern, options: .regularExpression), range.lowerBound < cut {
                cut = range.lowerBound
            }
        }
        var text = String(body[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = body.trimmingCharacters(in: .whitespacesAndNewlines) }
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}

public struct MailComposeSnapshot: Equatable, Sendable {
    public var id: String
    public var subject: String
    public var recipients: [String]
    public var content: String
    public var signature: String
    public var attachmentCount: Int

    public init(id: String, subject: String, recipients: [String], content: String, signature: String = "", attachmentCount: Int = -1) {
        self.id = id; self.subject = subject; self.recipients = recipients
        self.content = content; self.signature = signature
        self.attachmentCount = attachmentCount
    }

    /// Unlike newestPart, an empty prefix must stay empty: quoted history
    /// and Mail's automatic signature are not words the user just typed.
    public var authoredText: String {
        let body = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let markers = [
            #"(?im)^(On .{3,200} wrote:|Il giorno .{3,200} ha scritto:|Am .{3,200} schrieb .{0,100}:)\s*$"#,
            #"(?im)^-{2,} ?(Original Message|Messaggio originale) ?-{2,}"#,
            #"(?m)^\s*>"#,
            #"(?im)^(Begin forwarded message:|Inizio messaggio inoltrato:|[- ]*Forwarded message[- ]*|[- ]*Messaggio inoltrato[- ]*)\s*$"#,
        ]
        var cut = body.endIndex
        for marker in markers {
            if let range = body.range(of: marker, options: .regularExpression), range.lowerBound < cut { cut = range.lowerBound }
        }
        var text = String(body[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        let automatic = signature.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !automatic.isEmpty, text.hasSuffix(automatic) {
            text = String(text.dropLast(automatic.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasSuffix("--") { text = String(text.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return text
    }

    public func replies(to message: MailMessage) -> Bool {
        guard !message.messageId.isEmpty, !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              subject.range(of: #"^\s*(re|r|aw|sv)\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil else { return false }
        func base(_ value: String) -> String {
            value.replacingOccurrences(of: #"^(\s*(re|r|aw|sv)\s*:)+\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        func address(_ value: String) -> String {
            if let start = value.lastIndex(of: "<"), let end = value[start...].firstIndex(of: ">") {
                return String(value[value.index(after: start)..<end]).lowercased()
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let target = address(message.replyTo.isEmpty ? message.sender : message.replyTo)
        return !target.isEmpty && base(subject) == base(message.subject) && recipients.contains { address($0) == target }
    }
}

/// A new, still-empty reply is an explicit opportunity to offer help.
/// Remember draft IDs across app switches; once someone starts writing,
/// deleting their text must not cause a fresh interruption.
public final class ReplyStartWatcher: @unchecked Sendable {
    private var handled: [String] = []

    public init() {}

    public func shouldOffer(_ draft: MailComposeSnapshot, original: MailMessage?, keyboardIdle: TimeInterval) -> Bool {
        guard !handled.contains(draft.id) else { return false }
        if !draft.authoredText.isEmpty {
            remember(draft.id)
            return false
        }
        guard keyboardIdle >= 0.7, let original, draft.replies(to: original) else { return false }
        remember(draft.id)
        return true
    }

    private func remember(_ id: String) {
        handled.append(id)
        if handled.count > 256 { handled.removeFirst(handled.count - 256) }
    }
}

/// Turns a stream of "which message is selected" samples into `mail.opened`
/// and `mail.closed` events.
///
/// A message counts as opened once it has stayed selected for `openAfter`
/// seconds: arrowing down an inbox selects a dozen messages a second, and
/// none of them was read. Closing reports how long it was open and whether
/// it was left unread, which is what the implicit labeller needs to tell
/// "read it and moved on" from "glanced and abandoned".
public final class MailSessionTracker: @unchecked Sendable {
    public enum Signal: Equatable, Sendable {
        case opened(MailMessage, wasUnread: Bool)
        case closed(MailMessage, dwellMs: Int, stillUnread: Bool)
    }

    public var openAfter: TimeInterval

    private var current: MailMessage?
    private var since: Date?
    private var firstSeenUnread = false
    private var opened = false

    public init(openAfter: TimeInterval = 1.2) {
        self.openAfter = openAfter
    }

    public func update(selected: MailMessage?, at now: Date) -> [Signal] {
        var signals: [Signal] = []
        if let message = selected, let current, message.id == current.id {
            self.current = message
            if !opened, let since, now.timeIntervalSince(since) >= openAfter {
                opened = true
                signals.append(.opened(message, wasUnread: firstSeenUnread))
            }
            return signals
        }
        if let current, opened, let since {
            let dwell = Int(now.timeIntervalSince(since) * 1000)
            signals.append(.closed(current, dwellMs: dwell, stillUnread: !current.read))
        }
        current = selected
        since = selected == nil ? nil : now
        firstSeenUnread = selected.map { !$0.read } ?? false
        opened = false
        if let selected, openAfter <= 0 {
            opened = true
            signals.append(.opened(selected, wasUnread: firstSeenUnread))
        }
        return signals
    }
}

/// Decides when a draft in progress is worth a tone check: after a pause in
/// typing, once it has enough words to judge, and only when it changed
/// meaningfully since the last check — so a long email costs a handful of
/// decisions, not one per keystroke.
public final class ComposeWatcher: @unchecked Sendable {
    public var pauseSeconds: TimeInterval
    public var minimumCharacters: Int

    private var lastChecked: String = ""
    private var lastSubject: String = ""

    public init(pauseSeconds: TimeInterval = 4, minimumCharacters: Int = 60) {
        self.pauseSeconds = pauseSeconds
        self.minimumCharacters = minimumCharacters
    }

    public func shouldCheck(draft: String, subject: String, keyboardIdle: TimeInterval) -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard keyboardIdle >= pauseSeconds, text.count >= minimumCharacters else { return false }
        if subject != lastSubject {
            lastSubject = subject
            lastChecked = ""
        }
        let grown = text.count - lastChecked.count
        let changedEnough = lastChecked.isEmpty || abs(grown) >= 40 || !text.hasPrefix(String(lastChecked.prefix(20)))
        guard changedEnough else { return false }
        lastChecked = text
        return true
    }

    public func reset() {
        lastChecked = ""
        lastSubject = ""
    }
}

public enum MailEvents {
    public static let bundleId = "com.apple.mail"

    public static func replyStarted(_ message: MailMessage, composeId: String, to: [String]) -> EventFrame {
        var event = opened(message, wasUnread: !message.read, typing: false, idle: false)
        event.kind = .mailReplyStarted
        event.payload.fields["compose_id"] = .string(composeId)
        event.payload.fields["reply_recipients"] = .array(to.map { .string($0) })
        event.payload.fields["draft"] = .string("")
        return event
    }

    public static func opened(_ message: MailMessage, wasUnread: Bool, typing: Bool, idle: Bool) -> EventFrame {
        var fields = EmailItem(message: message).snapshot.objectValue ?? [:]
        fields["list_id"] = .string(message.headers.listId)
        fields["automatic"] = .bool(message.headers.automatic)
        fields["body"] = .string(MailScriptFormat.newestPart(of: message.body))
        fields["message_id"] = .string(message.messageId)
        fields["thread_len"] = .number(Double(MailScriptFormat.estimateThreadLength(subject: message.subject, body: message.body)))
        fields["unread"] = .bool(wasUnread)
        fields["thread_id"] = .string(message.messageId)
        fields["bundle_id"] = .string(bundleId)
        return EventFrame(
            kind: .mailOpened,
            app: "Mail",
            payload: EventPayload(typing: typing, idle: idle, fields: fields)
        )
    }

    public static func closed(_ message: MailMessage, dwellMs: Int, stillUnread: Bool, typing: Bool, idle: Bool) -> EventFrame {
        EventFrame(
            kind: .mailClosed,
            app: "Mail",
            payload: EventPayload(typing: typing, idle: idle, fields: [
                "sender": .string(message.sender),
                "subject": .string(message.subject),
                "message_id": .string(message.messageId),
                "thread_id": .string(message.messageId),
                "dwell_ms": .number(Double(dwellMs)),
                "still_unread": .bool(stillUnread),
            ])
        )
    }

    public static func composing(to: String, subject: String, draft: String, idleSeconds: Int, typing: Bool) -> EventFrame {
        EventFrame(
            kind: .mailComposing,
            app: "Mail",
            payload: EventPayload(typing: typing, idle: false, fields: [
                "to": .string(to),
                "subject": .string(subject),
                "draft": .string(String(draft.prefix(4000))),
                "idle_seconds": .number(Double(idleSeconds)),
            ])
        )
    }
}
