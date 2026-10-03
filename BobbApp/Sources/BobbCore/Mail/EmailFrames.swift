import Foundation

public struct EmailCommandFrame: Codable, Sendable, Equatable {
    public var id: String
    public var op: String
    public var payload: JSONValue
    public init(op: String = "list", payload: JSONValue = .object([:]), id: String = "email_" + UUID().uuidString) {
        self.id = id; self.op = op; self.payload = payload
    }
}

public struct EmailItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var messageId: String
    public var direction: String
    public var sender: String
    public var to: String
    public var cc: String
    public var replyTo: String
    public var subject: String
    public var body: String
    public var mailbox: String
    public var account: String?
    public var flagged: Bool?
    public var sentAt: Double
    public var category: String
    public var priority: Int
    public var needsReply: Bool
    public var due: Double?
    public var evidence: [String]
    public var status: String
    public var unread: Bool
    public var attachments: [String]
    public var composeId: String?
    public var inReplyTo: String
    public var references: [String]

    enum CodingKeys: String, CodingKey {
        case id, direction, sender, to, cc, subject, body, mailbox, account, flagged, category, priority, due, evidence, status, unread, attachments, references
        case messageId = "message_id", replyTo = "reply_to", sentAt = "sent_at", needsReply = "needs_reply", composeId = "compose_id", inReplyTo = "in_reply_to"
    }

    public init(message: MailMessage, direction: String = "received", composeId: String? = nil) {
        id = MailHeaders.canonicalID(message.messageId); messageId = id
        self.direction = direction; sender = message.sender; to = message.to; cc = message.cc
        replyTo = message.replyTo; subject = message.subject; body = message.body; mailbox = message.mailbox
        account = message.account
        flagged = message.flagged
        sentAt = message.date?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        category = "personal_no_ask"; priority = 1; needsReply = false; due = nil; evidence = []
        status = "open"; unread = !message.read; attachments = message.attachments; self.composeId = composeId
        inReplyTo = message.headers.inReplyTo; references = message.headers.references
    }

    public var snapshot: JSONValue {
        var fields: [String: JSONValue] = [
            "message_id": .string(messageId), "direction": .string(direction), "sender": .string(sender),
            "to": .string(to), "cc": .string(cc), "reply_to": .string(replyTo), "subject": .string(subject),
            "body": .string(String(body.prefix(64000))), "mailbox": .string(mailbox), "account": .string(account ?? ""), "sent_at": .number(sentAt),
            "unread": .bool(unread), "flagged": .bool(flagged == true), "attachments": .array(attachments.map { .string($0) }),
            "in_reply_to": .string(inReplyTo), "references": .array(references.map { .string($0) })
        ]
        if let composeId { fields["compose_id"] = .string(composeId) }
        return .object(fields)
    }
}

public struct EmailReminder: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var messageId: String
    public var kind: String
    public var due: Double
    public var announced: Int
    public var subject: String
    public var sender: String
    public var to: String
    public var ready: Bool
    public var muted: Bool
    enum CodingKeys: String, CodingKey {
        case id, kind, due, announced, subject, sender, to, ready, muted
        case messageId = "message_id"
    }
}

public struct EmailPreferences: Codable, Sendable, Equatable {
    public var vip: [String] = []
    public var signature: String = ""
    public var style: String = "concise"
    public var archiveAll: Bool?
    public init() {}
    enum CodingKeys: String, CodingKey { case vip, signature, style; case archiveAll = "archive_all" }
}

public struct EmailOutput: Codable, Sendable, Equatable {
    public var operation: String
    public var text: String
    public var resultKind: String
    public var messageId: String?
    public var composeId: String?
    public var to: String?
    public var subject: String?
    public var unsupported: [String]?
    public var error: String?
    public var cancelled: Bool?
    public var latencyMs: Double?
    public var firstTokenMs: Double?
    public var emailSources: [EmailSourceRef]?
    public var reviewNotes: [String]?
    enum CodingKeys: String, CodingKey {
        case operation, text, to, subject, unsupported, error, cancelled
        case resultKind = "result_kind", messageId = "message_id", composeId = "compose_id", latencyMs = "latency_ms", firstTokenMs = "first_token_ms", emailSources = "email_sources", reviewNotes = "review_notes"
    }
}

public struct EmailSourceRef: Codable, Sendable, Equatable, Identifiable {
    public var n: Int
    public var messageId: String
    public var subject: String
    public var sender: String
    public var id: String { messageId }
    enum CodingKeys: String, CodingKey { case n, subject, sender; case messageId = "message_id" }
}

public struct EmailStateFrame: Codable, Sendable, Equatable {
    public var requestId: String?
    public var items: [EmailItem]
    public var reminders: [EmailReminder]
    public var counts: [String: Int]
    public var preferences: EmailPreferences
    public var result: EmailOutput?
    public var offset: Int?
    public var total: Int?
    public var hasMore: Bool?
    public var mailboxes: [String]?
    public var accounts: [String]?
    enum CodingKeys: String, CodingKey {
        case items, reminders, counts, preferences, result, offset, total, mailboxes, accounts
        case requestId = "request_id", hasMore = "has_more"
    }
}

public struct EmailDeltaFrame: Codable, Sendable, Equatable {
    public var requestId: String
    public var text: String
    enum CodingKeys: String, CodingKey { case text; case requestId = "request_id" }
}

public struct EmailWritingSession: Sendable, Equatable {
    public var requestId: String
    public var operation: String
    public var text = ""
    public var streaming = true
    public var result: EmailOutput?
    public init(requestId: String, operation: String) { self.requestId = requestId; self.operation = operation }
}
