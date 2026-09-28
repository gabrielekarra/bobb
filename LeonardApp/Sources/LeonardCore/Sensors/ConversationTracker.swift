import Foundation

/// Notices conversations in chat apps from the text the screen sensor
/// already reads — no plugin, no API, no account (VISION rule 1), and not
/// only email (rule 6). Two moments count: a conversation the user opens,
/// and new lines arriving in the one they are looking at. Either becomes a
/// `message.opened` event carrying the latest lines, which the daemon
/// judges exactly like an email: who is it, do they ask for something, how
/// soon.
///
/// It cannot tell the user's own lines from the other person's in general;
/// it does not try. The model reads the lines as a person would.
public struct ConversationTracker: Sendable {
    /// Chat apps, by bundle id. Mail clients are left to the Mail sensor.
    public static let chatApps: Set<String> = [
        "com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "desktop.WhatsApp",
        "com.microsoft.teams", "com.microsoft.teams2", "ru.keepcoder.Telegram", "org.telegram.desktop",
        "com.hnc.Discord", "org.whispersystems.signal-desktop", "com.facebook.archon", "com.linkedin.LinkedIn",
    ]

    public var maxLines = 14
    public var maxCharacters = 1600
    /// The same conversation is not re-judged on reopening within this.
    public var reopenAfter: TimeInterval = 600
    /// New lines within this of the last event are held until the next read.
    public var minimumGap: TimeInterval = 20

    private struct Seen: Sendable {
        var lines: [String]
        var emitted: Date
    }
    private var seen: [String: Seen] = [:]
    private var current: String?

    public init() {}

    public static func isChatApp(_ bundleId: String?) -> Bool {
        bundleId.map { chatApps.contains($0) } ?? false
    }

    /// Feeds one read of the window in front. Returns an event when a
    /// conversation was just opened or new lines arrived in it.
    public mutating func observe(app: String, bundleId: String?, window: String, text: String,
                                 typing: Bool = false, idle: Bool = false, now: Date = Date()) -> EventFrame? {
        guard Self.isChatApp(bundleId) else {
            current = nil
            return nil
        }
        let lines = Self.lines(text)
        guard !lines.isEmpty else { return nil }
        let key = "\(bundleId ?? app)\u{1F}\(window)"
        defer { current = key }

        guard let previous = seen[key] else {
            seen[key] = Seen(lines: lines, emitted: now)
            trim()
            return event(app: app, bundleId: bundleId, window: window, lines: Array(lines.suffix(maxLines)), new: false,
                         typing: typing, idle: idle, now: now)
        }

        let known = Set(previous.lines)
        let fresh = lines.filter { !known.contains($0) }
        let switchedBack = current != key && now.timeIntervalSince(previous.emitted) >= reopenAfter
        if switchedBack {
            seen[key] = Seen(lines: lines, emitted: now)
            return event(app: app, bundleId: bundleId, window: window, lines: Array(lines.suffix(maxLines)), new: !fresh.isEmpty,
                         typing: typing, idle: idle, now: now)
        }
        guard !fresh.isEmpty, fresh.joined().count >= 6, now.timeIntervalSince(previous.emitted) >= minimumGap, !typing else {
            // Keep what was known; new lines stay "new" until they are sent.
            return nil
        }
        seen[key] = Seen(lines: lines, emitted: now)
        return event(app: app, bundleId: bundleId, window: window, lines: Array(fresh.suffix(maxLines)), new: true,
                     typing: typing, idle: idle, now: now)
    }

    /// The conversation's name: the window title without the app's own name
    /// ("Giulia Bianchi (DM) - Studio Rossi - Slack" → "Giulia Bianchi (DM)").
    public static func conversationName(window: String, app: String) -> String {
        var parts = window.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
        parts.removeAll { $0.isEmpty || $0.caseInsensitiveCompare(app) == .orderedSame }
        guard let first = parts.first else { return "" }
        return first.caseInsensitiveCompare(app) == .orderedSame ? "" : first
    }

    static func lines(_ text: String) -> [String] {
        var out: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count > 1, out.last != line else { continue }
            out.append(line)
        }
        return out
    }

    private func event(app: String, bundleId: String?, window: String, lines: [String], new: Bool,
                       typing: Bool, idle: Bool, now: Date) -> EventFrame? {
        var body = lines.joined(separator: "\n")
        if body.count > maxCharacters { body = String(body.suffix(maxCharacters)) }
        guard body.count >= 6 else { return nil }
        let name = Self.conversationName(window: window, app: app)
        return EventFrame(
            ts: now.timeIntervalSince1970,
            kind: .messageOpened,
            app: app,
            payload: EventPayload(typing: typing, idle: idle, fields: [
                "sender": .string(name),
                "subject": .string(name.isEmpty ? app : "\(app): \(name)"),
                "body": .string(body),
                "new": .bool(new),
                "window": .string(window),
                "bundle_id": .string(bundleId ?? ""),
            ])
        )
    }

    private mutating func trim() {
        guard seen.count > 200 else { return }
        let oldest = seen.sorted { $0.value.emitted < $1.value.emitted }.prefix(seen.count - 150)
        for (key, _) in oldest { seen.removeValue(forKey: key) }
    }
}
