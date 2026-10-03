import Foundation

/// A message from Mail's Sent mailbox.
public struct SentMessage: Sendable, Equatable {
    public var messageId: String
    public var sent: Date
    public var to: String
    public var subject: String
    public var body: String
    public var sender: String
    public var cc: String
    public var headers: MailHeaders

    public init(messageId: String, sent: Date, to: String, subject: String, body: String,
                sender: String = "", cc: String = "", headers: MailHeaders = MailHeaders()) {
        self.messageId = messageId
        self.sent = sent
        self.to = to
        self.subject = subject
        self.body = body
        self.sender = sender; self.cc = cc; self.headers = headers
    }
}

extension MailScriptFormat {
    public static let record = "\u{1E}"

    /// Parses records of `message id␟ISO date␟recipient␟subject␟content`, separated by ␞.
    public static func parseSent(_ output: String) -> [SentMessage] {
        output.components(separatedBy: record).compactMap { chunk in
            let fields = chunk.components(separatedBy: unit)
            guard fields.count >= 5, !fields[0].isEmpty, let sent = isoDate(fields[1]) else { return nil }
            return SentMessage(messageId: fields[0], sent: sent, to: fields[2], subject: fields[3],
                               body: fields[4...].joined(separator: unit))
        }
    }

    /// AppleScript's «class isot» is local time without a zone: 2026-09-28T10:00:00.
    static func isoDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Which sent messages are new since Bobb last looked, so each is read
/// for promises exactly once. The first look goes back a week, not further:
/// old promises are not worth a wave of reminders.
public struct SentMailTracker: Sendable {
    public private(set) var seen: Set<String>
    public var firstLookBack: TimeInterval = 7 * 86400
    public var maxSeen = 500
    private var looked: Bool

    public init(seen: [String] = []) {
        self.seen = Set(seen)
        self.looked = !seen.isEmpty
    }

    public mutating func fresh(_ messages: [SentMessage], now: Date = Date()) -> [SentMessage] {
        let cutoff = now.addingTimeInterval(-firstLookBack)
        var out: [SentMessage] = []
        for message in messages.sorted(by: { $0.sent < $1.sent }) where !seen.contains(message.messageId) {
            seen.insert(message.messageId)
            if !looked && message.sent < cutoff { continue }
            if message.sent < now.addingTimeInterval(-30 * 86400) { continue }
            out.append(message)
        }
        looked = true
        if seen.count > maxSeen {
            seen = Set(messages.map(\.messageId))
        }
        return out
    }

    public static func event(for message: SentMessage) -> EventFrame {
        EventFrame(
            ts: message.sent.timeIntervalSince1970,
            kind: .mailSent,
            app: "Mail",
            payload: EventPayload(typing: nil, idle: nil, fields: [
                "to": .string(message.to),
                "subject": .string(message.subject),
                "body": .string(String(MailScriptFormat.newestPart(of: message.body).prefix(4000))),
                "message_id": .string(message.messageId),
                "sent_at": .number(message.sent.timeIntervalSince1970),
                "direction": .string("sent"), "sender": .string(message.sender), "cc": .string(message.cc),
                "in_reply_to": .string(message.headers.inReplyTo),
                "references": .array(message.headers.references.map { .string($0) }),
            ])
        )
    }
}

/// A calendar event as the calendar sensor reads it.
public struct CalendarItem: Sendable, Equatable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var location: String
    public var notes: String
    /// Other people invited, "Name <address>" where known.
    public var attendees: [String]
    public var calendar: String

    public init(id: String, title: String, start: Date, end: Date, allDay: Bool = false, location: String = "",
                notes: String = "", attendees: [String] = [], calendar: String = "") {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.location = location
        self.notes = notes
        self.attendees = attendees
        self.calendar = calendar
    }

    /// The event as screen memory keeps it, so "when is the call with
    /// Marco?" is answered from the calendar too.
    public func memoryText(locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .full
        formatter.timeStyle = allDay ? .none : .short
        var lines = ["\(title)", formatter.string(from: start)]
        if !location.isEmpty { lines.append(location) }
        if !attendees.isEmpty { lines.append(attendees.joined(separator: ", ")) }
        if !notes.isEmpty { lines.append(String(notes.prefix(1000))) }
        return lines.joined(separator: "\n")
    }
}

/// When to offer a brief: once per meeting, about ten minutes before it,
/// only for events with other people (or at least a place and a length
/// that make a meeting), never for all-day ones.
public struct MeetingScheduler: Sendable {
    public var lead: TimeInterval = 10 * 60
    public var window: TimeInterval = 4 * 60
    private var offered: [String: Date] = [:]

    public init() {}

    public mutating func due(_ items: [CalendarItem], now: Date = Date()) -> [CalendarItem] {
        var out: [CalendarItem] = []
        for item in items where !item.allDay && offered[item.id] == nil {
            let until = item.start.timeIntervalSince(now)
            guard until <= lead + window / 2, until >= lead - window else { continue }
            guard !item.attendees.isEmpty || (!item.location.isEmpty && item.end.timeIntervalSince(item.start) >= 15 * 60) else { continue }
            offered[item.id] = now
            out.append(item)
        }
        offered = offered.filter { now.timeIntervalSince($0.value) < 86400 }
        return out
    }

    public static func event(for item: CalendarItem, now: Date = Date()) -> EventFrame {
        EventFrame(
            ts: now.timeIntervalSince1970,
            kind: .calendarUpcoming,
            app: "Calendar",
            payload: EventPayload(typing: nil, idle: nil, fields: [
                "title": .string(item.title),
                "start_ts": .number(item.start.timeIntervalSince1970),
                "minutes_until": .number(max(0, (item.start.timeIntervalSince(now) / 60).rounded())),
                "attendees": .array(item.attendees.map { .string($0) }),
                "location": .string(item.location),
                "notes": .string(String(item.notes.prefix(800))),
                "calendar": .string(item.calendar),
            ])
        )
    }
}
