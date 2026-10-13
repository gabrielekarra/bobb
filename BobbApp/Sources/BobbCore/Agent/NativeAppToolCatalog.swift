import Foundation

public enum NativeAppToolCatalog {
    public static let applicationName = "Mac tools: Calendario Promemoria Contatti Comandi Rapidi Musica Mail Messaggi / Calendar Reminders Contacts Shortcuts Music Messages"
    public static let bundleId = "com.bobb.integrations"
    private static func text(_ description: String, max: Int = 8000) -> JSONValue {
        ["type": "string", "description": .string(description), "maxLength": .number(Double(max))]
    }
    private static func requiredText(_ description: String) -> JSONValue {
        var value = text(description).objectValue!; value["minLength"] = 1; return .object(value)
    }
    private static let identifier = requiredText("Exact id returned by a previous list/search call; never a guessed name.")
    private static let date = requiredText("ISO 8601 date and time with UTC offset, e.g. 2026-10-13T10:00:00+02:00.")
    private static let limit: JSONValue = ["type": "integer", "minimum": 1, "maximum": 100]
    private static let offset: JSONValue = ["type": "integer", "minimum": 0, "maximum": 100000]
    private static func tool(_ id: String, _ name: String, _ summary: String, _ app: String, _ bundle: String,
                             _ category: ActionCategory = .navigate, _ properties: [String: JSONValue] = [:], _ required: [String] = []) -> AppTool {
        AppTool(id: id, name: name, summary: summary, bundleId: bundle, app: app, category: category,
            schema: ["type": "object", "properties": .object(properties), "required": .array(required.map(JSONValue.string)), "additionalProperties": false],
            deduplicatesCalls: ["calendar.create", "reminders.create", "mail.draft"].contains(id))
    }
    public static let tools: [AppTool] = [
        tool("calendar.list", "Calendar / Calendario: list events", "Read a bounded date range; use returned event ids and start dates for changes.", "Calendar", "com.apple.iCal", .navigate,
             ["from": date, "to": date, "limit": limit, "offset": offset], ["from", "to"]),
        tool("calendar.calendars", "Calendar / Calendario: list calendars", "Read calendar ids and writable status.", "Calendar", "com.apple.iCal"),
        tool("calendar.create", "Calendar / Calendario: create event", "Create an event without invitations. Use an exact writable calendar id or the default.", "Calendar", "com.apple.iCal", .write,
             ["title": requiredText("Event title"), "start": date, "end": date, "calendar_id": identifier,
              "location": text("Location"), "notes": text("Notes")], ["title", "start", "end"]),
        tool("calendar.update", "Calendar / Calendario: update event", "Change only the exact occurrence returned by list. Requires its original start time. Events with attendees require the Calendar UI.", "Calendar", "com.apple.iCal", .write,
             ["event_id": identifier, "expected_start": date, "title": requiredText("New title"), "start": date, "end": date,
              "location": text("New location"), "notes": text("New notes")], ["event_id", "expected_start"]),
        tool("calendar.delete", "Calendar / Calendario: delete event", "Delete only an exact occurrence. Invitations and recurring series require the Calendar UI.", "Calendar", "com.apple.iCal", .delete,
             ["event_id": identifier, "expected_start": date], ["event_id", "expected_start"]),
        tool("reminders.lists", "Reminders / Promemoria: list lists", "Read reminder list ids and writable status.", "Reminders", "com.apple.reminders"),
        tool("reminders.list", "Reminders / Promemoria: list reminders", "Read reminders, optionally in one exact list. Results are paginated.", "Reminders", "com.apple.reminders", .navigate,
             ["list_id": identifier, "include_completed": ["type": "boolean"], "limit": limit, "offset": offset]),
        tool("reminders.create", "Reminders / Promemoria: create reminder", "Create a reminder in one exact writable list or the default.", "Reminders", "com.apple.reminders", .write,
             ["title": requiredText("Reminder title"), "notes": text("Notes"), "due": date, "list_id": identifier,
              "priority": ["type": "integer", "minimum": 0, "maximum": 9]], ["title"]),
        tool("reminders.complete", "Reminders / Promemoria: complete reminder", "Complete or reopen an exact reminder returned by list.", "Reminders", "com.apple.reminders", .write,
             ["reminder_id": identifier, "completed": ["type": "boolean"]], ["reminder_id", "completed"]),
        tool("reminders.delete", "Reminders / Promemoria: delete reminder", "Delete one exact reminder returned by list.", "Reminders", "com.apple.reminders", .delete,
             ["reminder_id": identifier], ["reminder_id"]),
        tool("contacts.search", "Contacts / Contatti: search contacts", "Search names. Return all matches with exact addresses; never silently choose between people.", "Contacts", "com.apple.AddressBook", .navigate,
             ["query": requiredText("Name to search"), "limit": limit, "offset": offset], ["query"]),
        tool("shortcuts.list", "Shortcuts / Comandi Rapidi: list shortcuts", "Discover installed shortcuts. Any installed app exposing Shortcuts can be reached through them.", "Shortcuts", "com.apple.shortcuts", .navigate,
             ["limit": limit, "offset": offset]),
        tool("shortcuts.run", "Shortcuts / Comandi Rapidi: run shortcut", "Run an exact name from the current list, following the Shortcuts execute boundary. The shortcut can act in other apps.", "Shortcuts", "com.apple.shortcuts", .execute,
             ["name": requiredText("Exact name returned by shortcuts.list"), "input": text("Optional plain text input", max: 32000)], ["name"]),
        tool("music.status", "Music / Musica: now playing", "Read current track, playback state and volume.", "Music", "com.apple.Music"),
        tool("music.search", "Music / Musica: search library", "Search the user's local Music library. Returns exact track ids.", "Music", "com.apple.Music", .navigate,
             ["query": requiredText("Track title"), "limit": limit], ["query"]),
        tool("music.play", "Music / Musica: play", "Resume playback or play one exact track id returned by search.", "Music", "com.apple.Music", .write,
             ["track_id": identifier]),
        tool("music.pause", "Music / Musica: pause", "Pause playback.", "Music", "com.apple.Music", .write),
        tool("music.next", "Music / Musica: next track", "Skip to the next track.", "Music", "com.apple.Music", .write),
        tool("music.previous", "Music / Musica: previous track", "Go to the previous track.", "Music", "com.apple.Music", .write),
        tool("music.volume", "Music / Musica: set volume", "Set Music's volume, from 0 to 100.", "Music", "com.apple.Music", .write,
             ["level": ["type": "integer", "minimum": 0, "maximum": 100]], ["level"]),
        tool("mail.selected", "Mail / Posta: read selected email", "Read the email selected in Apple Mail, with its exact Message-ID.", "Mail", "com.apple.mail"),
        tool("mail.inbox", "Mail / Posta: read recent inbox", "Read up to 100 recent inbox messages. For the full archive use Bobb Email.", "Mail", "com.apple.mail", .navigate,
             ["limit": limit]),
        tool("mail.draft", "Mail / Posta: create draft", "Open an editable new draft in the user's Apple Mail. Does not send.", "Mail", "com.apple.mail", .write,
             ["to": ["type": "array", "maxItems": 20, "items": requiredText("Exact email address")], "subject": text("Subject"), "body": requiredText("Body")], ["to", "subject", "body"]),
        tool("mail.mark", "Mail / Posta: mark email", "Change read/unread or flag status for an exact Message-ID.", "Mail", "com.apple.mail", .write,
             ["message_id": identifier, "operation": ["type": "string", "enum": ["read", "unread", "flag", "unflag"]]], ["message_id", "operation"]),
        tool("messages.list", "Messages / Messaggi: list conversations", "Read individual iMessage chats on request. Requires Full Disk Access; returns exact chat ids and recipient addresses.", "Messages", "com.apple.MobileSMS", .navigate,
             ["limit": limit, "offset": offset]),
        tool("messages.read", "Messages / Messaggi: read conversation", "Read a page of an exact previously listed individual chat. Attachment contents and unsupported text archives are not read.", "Messages", "com.apple.MobileSMS", .navigate,
             ["chat_id": identifier, "limit": limit, "before_row": ["type": "integer", "minimum": 1, "maximum": 9007199254740991]], ["chat_id"]),
        tool("messages.send", "Messages / Messaggi: send message", "Submit an iMessage to the exact address of a previously listed individual chat. A submission receipt does not prove delivery.", "Messages", "com.apple.MobileSMS", .send,
             ["chat_id": identifier, "address": requiredText("Exact recipient address returned by messages.list"), "body": requiredText("Message body")], ["chat_id", "address", "body"]),
    ]
}
