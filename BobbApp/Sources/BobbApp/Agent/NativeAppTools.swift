import AppKit
import Contacts
import EventKit
import Foundation
import BobbCore

/// Swift adapters inspired by Vox's integration inventory. They use public
/// macOS APIs and Bobb's existing Mail adapter, not Electron or a second AI.
@MainActor
final class NativeAppTools {
    private let events = EKEventStore()
    private let contacts = CNContactStore()
    private let messages = MessageAppTools()
    private let permitted: @MainActor (AppTool) -> Bool
    private var shortcutNames: Set<String> = []
    init(permitted: @escaping @MainActor (AppTool) -> Bool) { self.permitted = permitted }
    enum Failure: Error, CustomStringConvertible {
        case unavailable(String)
        var description: String { switch self { case .unavailable(let message): return message } }
    }
    private func check(_ tool: AppTool) throws {
        guard !Task.isCancelled, permitted(tool) else { throw Failure.unavailable("The app is excluded, acting is paused or the screen lease ended.") }
    }
    private func string(_ args: JSONValue, _ key: String) -> String { args[key]?.stringValue ?? "" }
    private func date(_ args: JSONValue, _ key: String) throws -> Date {
        let text = string(args, key)
        let format = ISO8601DateFormatter()
        if let value = format.date(from: text) { return value }
        format.formatOptions.insert(.withFractionalSeconds)
        guard let value = format.date(from: text) else { throw Failure.unavailable("\(key) requires an ISO 8601 timestamp with a UTC offset.") }
        return value
    }
    private func iso(_ date: Date) -> JSONValue { .string(ISO8601DateFormatter().string(from: date)) }
    private func page(_ items: [JSONValue], _ args: JSONValue) -> JSONValue {
        let offset = Int(args["offset"]?.numberValue ?? 0), limit = Int(args["limit"]?.numberValue ?? 25)
        return ["items": .array(Array(items.dropFirst(offset).prefix(limit))), "total": .number(Double(items.count)),
                "offset": .number(Double(offset)), "limit": .number(Double(limit)), "has_more": .bool(offset + limit < items.count)]
    }
    private func calendarAccess(_ tool: AppTool, reminder: Bool = false) async throws {
        let kind: EKEntityType = reminder ? .reminder : .event
        if EKEventStore.authorizationStatus(for: kind) == .notDetermined {
            let granted = reminder ? try await events.requestFullAccessToReminders() : try await events.requestFullAccessToEvents()
            guard granted else { throw Failure.unavailable("Allow \(reminder ? "Reminders" : "Calendars") access in System Settings.") }
        }
        try check(tool)
        guard EKEventStore.authorizationStatus(for: kind) == .fullAccess else { throw Failure.unavailable("Full \(reminder ? "Reminders" : "Calendars") access is unavailable.") }
    }
    private func calendar(_ args: JSONValue, reminders: Bool = false) throws -> EKCalendar {
        let id = string(args, reminders ? "list_id" : "calendar_id")
        let found = id.isEmpty ? (reminders ? events.defaultCalendarForNewReminders() : events.defaultCalendarForNewEvents) : events.calendar(withIdentifier: id)
        guard let found, found.allowedEntityTypes.contains(reminders ? .reminder : .event), found.allowsContentModifications else {
            throw Failure.unavailable("Choose an exact writable \(reminders ? "list" : "calendar") id from the list tool.")
        }
        return found
    }
    private func eventSnapshot(_ event: EKEvent) -> JSONValue {
        ["event_id": .string(event.eventIdentifier ?? ""), "title": .string(event.title ?? ""),
         "start": iso(event.startDate), "end": iso(event.endDate), "calendar_id": .string(event.calendar.calendarIdentifier),
         "calendar": .string(event.calendar.title), "location": .string(event.location ?? ""), "notes": .string(event.notes ?? ""),
         "has_attendees": .bool(!(event.attendees ?? []).isEmpty), "recurring": .bool(event.hasRecurrenceRules)]
    }
    private nonisolated static func reminderSnapshot(_ reminder: EKReminder) -> JSONValue {
        var result: [String: JSONValue] = ["reminder_id": .string(reminder.calendarItemIdentifier), "title": .string(reminder.title ?? ""),
            "list_id": .string(reminder.calendar.calendarIdentifier), "list": .string(reminder.calendar.title),
            "completed": .bool(reminder.isCompleted), "notes": .string(reminder.notes ?? ""), "priority": .number(Double(reminder.priority))]
        if let components = reminder.dueDateComponents, let due = Calendar.current.date(from: components) { result["due"] = .string(ISO8601DateFormatter().string(from: due)) }
        return .object(result)
    }
    func execute(_ tool: AppTool, _ args: JSONValue) async throws -> JSONValue {
        try check(tool)
        guard ToolArguments.matches(args, schema: tool.schema) else { throw Failure.unavailable("Invalid tool arguments.") }
        if tool.id.hasPrefix("messages.") { return try messages.execute(tool, args) }
        if tool.id.hasPrefix("calendar.") {
            try await calendarAccess(tool)
            switch tool.id {
            case "calendar.calendars":
                return .array(events.calendars(for: .event).map { ["id": .string($0.calendarIdentifier), "title": .string($0.title), "writable": .bool($0.allowsContentModifications)] })
            case "calendar.list":
                let from = try date(args, "from"), to = try date(args, "to")
                guard to > from, to.timeIntervalSince(from) <= 366 * 86400 else { throw Failure.unavailable("Choose a date range of at most one year.") }
                return page(events.events(matching: events.predicateForEvents(withStart: from, end: to, calendars: nil))
                    .sorted { $0.startDate < $1.startDate }.map(eventSnapshot), args)
            case "calendar.create":
                let event = EKEvent(eventStore: events); event.calendar = try calendar(args)
                event.title = string(args, "title"); event.startDate = try date(args, "start"); event.endDate = try date(args, "end")
                guard event.endDate > event.startDate else { throw Failure.unavailable("The event end must follow its start.") }
                event.location = string(args, "location"); event.notes = string(args, "notes")
                try check(tool); try events.save(event, span: .thisEvent, commit: true)
                guard let id = event.eventIdentifier, let saved = events.event(withIdentifier: id) else { throw Failure.unavailable("The event could not be read back.") }
                return ["status": "created", "event": eventSnapshot(saved)]
            default:
                guard let event = events.event(withIdentifier: string(args, "event_id")),
                      abs(event.startDate.timeIntervalSince(try date(args, "expected_start"))) < 1,
                      event.calendar.allowsContentModifications, (event.attendees ?? []).isEmpty else {
                    throw Failure.unavailable("The occurrence changed or has attendees. Use the Calendar app to review it.")
                }
                if tool.id == "calendar.delete" {
                    guard !event.hasRecurrenceRules else { throw Failure.unavailable("Review deletion of recurring events in Calendar.") }
                    let id = event.eventIdentifier!; try check(tool); try events.remove(event, span: .thisEvent, commit: true)
                    guard events.event(withIdentifier: id) == nil else { throw Failure.unavailable("Deletion could not be verified.") }
                    return ["status": "deleted", "event_id": .string(id)]
                }
                guard ["title", "start", "end", "location", "notes"].contains(where: { args[$0] != nil }) else { throw Failure.unavailable("Specify a field to update.") }
                if args["title"] != nil { event.title = string(args, "title") }
                if args["start"] != nil { event.startDate = try date(args, "start") }
                if args["end"] != nil { event.endDate = try date(args, "end") }
                if args["location"] != nil { event.location = string(args, "location") }
                if args["notes"] != nil { event.notes = string(args, "notes") }
                guard event.endDate > event.startDate else { throw Failure.unavailable("The event end must follow its start.") }
                try check(tool); try events.save(event, span: .thisEvent, commit: true)
                guard let saved = events.event(withIdentifier: event.eventIdentifier) else { throw Failure.unavailable("The updated event could not be read back.") }
                return ["status": "updated", "event": eventSnapshot(saved)]
            }
        }
        if tool.id.hasPrefix("reminders.") {
            try await calendarAccess(tool, reminder: true)
            switch tool.id {
            case "reminders.lists":
                return .array(events.calendars(for: .reminder).map { ["id": .string($0.calendarIdentifier), "title": .string($0.title), "writable": .bool($0.allowsContentModifications)] })
            case "reminders.list":
                let id = string(args, "list_id")
                let lists: [EKCalendar]?
                if id.isEmpty { lists = nil }
                else { guard let list = events.calendar(withIdentifier: id), list.allowedEntityTypes.contains(.reminder) else { throw Failure.unavailable("Reminder list not found.") }; lists = [list] }
                let predicate = events.predicateForReminders(in: lists)
                let includeCompleted = args["include_completed"]?.boolValue == true
                let reminders: [JSONValue] = await withCheckedContinuation { continuation in
                    events.fetchReminders(matching: predicate) { result in
                        // EventKit objects stay in their callback. Only plain
                        // Sendable snapshots cross the continuation boundary.
                        let snapshots = (result ?? []).filter { includeCompleted || !$0.isCompleted }
                            .sorted { $0.calendarItemIdentifier < $1.calendarItemIdentifier }.map(Self.reminderSnapshot)
                        continuation.resume(returning: snapshots)
                    }
                }
                try check(tool)
                guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { throw Failure.unavailable("Reminders access was revoked.") }
                return page(reminders, args)
            case "reminders.create":
                let reminder = EKReminder(eventStore: events); reminder.calendar = try calendar(args, reminders: true)
                reminder.title = string(args, "title"); reminder.notes = string(args, "notes"); reminder.priority = Int(args["priority"]?.numberValue ?? 0)
                if args["due"] != nil { reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second, .timeZone], from: try date(args, "due")) }
                try check(tool); try events.save(reminder, commit: true)
                guard let saved = events.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder else { throw Failure.unavailable("The reminder could not be read back.") }
                return ["status": "created", "reminder": Self.reminderSnapshot(saved)]
            default:
                let id = string(args, "reminder_id")
                guard let reminder = events.calendarItem(withIdentifier: id) as? EKReminder, reminder.calendar.allowsContentModifications else { throw Failure.unavailable("The exact reminder is unavailable or read-only.") }
                try check(tool)
                if tool.id == "reminders.delete" {
                    try events.remove(reminder, commit: true)
                    guard events.calendarItem(withIdentifier: id) == nil else { throw Failure.unavailable("Deletion could not be verified.") }
                    return ["status": "deleted", "reminder_id": .string(id)]
                }
                reminder.isCompleted = args["completed"]!.boolValue!; try events.save(reminder, commit: true)
                guard let saved = events.calendarItem(withIdentifier: id) as? EKReminder, saved.isCompleted == reminder.isCompleted else { throw Failure.unavailable("Completion could not be verified.") }
                return ["status": "updated", "reminder": Self.reminderSnapshot(saved)]
            }
        }
        switch tool.id {
        case "contacts.search":
            if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined { _ = try await contacts.requestAccess(for: .contacts) }
            try check(tool)
            let status = CNContactStore.authorizationStatus(for: .contacts)
            guard status == .authorized || status.rawValue == 4 else { throw Failure.unavailable("Allow Contacts access in System Settings.") }
            let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor, CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor]
            let matches = try contacts.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: string(args, "query")), keysToFetch: keys)
            return page(matches.sorted { $0.identifier < $1.identifier }.map { contact in
                ["id": .string(contact.identifier), "name": .string(contact.givenName + " " + contact.familyName),
                 "organization": .string(contact.organizationName), "emails": .array(contact.emailAddresses.map { .string($0.value as String) }),
                 "phones": .array(contact.phoneNumbers.map { .string($0.value.stringValue) })]
            }, args)
        case "shortcuts.list":
            let output = try await AppIntegrationProcess.run(executable: "/usr/bin/shortcuts", arguments: ["list"])
            try check(tool); let names = output.split(separator: "\n").map(String.init).sorted(); shortcutNames = Set(names)
            return page(names.map(JSONValue.string), args)
        case "shortcuts.run":
            let name = string(args, "name")
            guard shortcutNames.contains(name) else { throw Failure.unavailable("List shortcuts first and choose an exact returned name.") }
            // Effects of a shortcut cannot be inferred from its name. An
            // explicit review is required even when execute is set to allow.
            let output = try await AppIntegrationProcess.runShortcut(name: name, input: args["input"]?.stringValue)
            return ["status": "finished", "shortcut": .string(name), "output": .string(output),
                    "verification": "The shortcut process finished; verify its app effects on screen."]
        case "mail.selected":
            guard let message = try MailBridge.selected() else { throw Failure.unavailable("Select one email in Apple Mail.") }
            return MailBridge.snapshot(message)
        case "mail.inbox":
            return .array(try MailBridge.batch(sent: false, limit: Int(args["limit"]?.numberValue ?? 25)).map { MailBridge.snapshot($0) })
        case "mail.mark":
            guard let message = try MailBridge.change(string(args, "message_id"), operation: string(args, "operation")) else { throw Failure.unavailable("The exact email could not be changed and read back.") }
            return MailBridge.snapshot(message)
        case "mail.draft":
            let addresses = args["to"]!.arrayValue!.compactMap(\.stringValue)
            guard !addresses.isEmpty, addresses.allSatisfy({ $0.contains("@") && !$0.contains(where: { $0.isWhitespace }) }) else { throw Failure.unavailable("Use exact email addresses; resolve ambiguous recipients first.") }
            let result = MailComposer.newDraft(subject: string(args, "subject"), body: string(args, "body"), recipients: addresses)
            guard case .opened = result else { throw Failure.unavailable("Mail did not open the draft.") }
            return ["status": "draft_opened", "sent": false, "verification": "Review the editable draft in Apple Mail."]
        default:
            guard tool.id.hasPrefix("music.") else { throw Failure.unavailable("Unknown native tool.") }
            return try music(tool, args)
        }
    }
    private func music(_ tool: AppTool, _ args: JSONValue) throws -> JSONValue {
        if tool.id == "music.search" {
            let raw = try AppleScriptRunner.shared.call(Self.musicScript, handler: "searchtracks", arguments: [string(args, "query"), String(Int(args["limit"]?.numberValue ?? 25))])
            let tracks = raw.components(separatedBy: "\u{1e}").filter { !$0.isEmpty }.map { $0.components(separatedBy: "\u{1f}") }
            guard tracks.allSatisfy({ $0.count == 3 }) else { throw Failure.unavailable("Music returned an unsupported record.") }
            return .array(tracks.map { ["track_id": .string($0[0]), "title": .string($0[1]), "artist": .string($0[2])] })
        }
        let raw = try AppleScriptRunner.shared.call(Self.musicScript, handler: "musicaction", arguments: [tool.id, string(args, "track_id"), String(Int(args["level"]?.numberValue ?? 50))])
        let fields = raw.components(separatedBy: "\u{1f}")
        guard fields.count == 5 else { throw Failure.unavailable("Music returned an unsupported state.") }
        return ["state": .string(fields[0]), "volume": .string(fields[1]), "track_id": .string(fields[2]), "title": .string(fields[3]), "artist": .string(fields[4])]
    }
    private static let musicScript = """
    on searchtracks(query_text, max_count)
        tell application "Music"
            set found to every track of library playlist 1 whose name contains query_text
            set output to ""
            repeat with n from 1 to (count of found)
                if n > (max_count as integer) then exit repeat
                set t to item n of found
                set output to output & (persistent ID of t) & (character id 31) & (name of t) & (character id 31) & (artist of t) & (character id 30)
            end repeat
            return output
        end tell
    end searchtracks
    on musicaction(operation_name, track_id, volume_text)
        tell application "Music"
            if operation_name is "music.play" then
                if track_id is "" then
                    play
                else
                    set found to every track of library playlist 1 whose persistent ID is track_id
                    if (count of found) is not 1 then error "Exact track not found"
                    play item 1 of found
                end if
            else if operation_name is "music.pause" then
                pause
            else if operation_name is "music.next" then
                next track
            else if operation_name is "music.previous" then
                previous track
            else if operation_name is "music.volume" then
                set sound volume to volume_text as integer
            end if
            set details to "" & (character id 31) & "" & (character id 31) & ""
            try
                set t to current track
                set details to (persistent ID of t) & (character id 31) & (name of t) & (character id 31) & (artist of t)
            end try
            return (player state as string) & (character id 31) & (sound volume as string) & (character id 31) & details
        end tell
    end musicaction
    """
}
