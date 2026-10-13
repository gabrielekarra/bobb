import Foundation
import SQLite3
import BobbCore

/// Requested pages only; no background import or automatic third-party replies.
@MainActor
final class MessageAppTools {
    private var observed: [String: String] = [:]
    private func database() throws -> OpaquePointer {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db").path
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw NativeAppTools.Failure.unavailable("Allow Full Disk Access for Bobb to read Messages.")
        }
        sqlite3_busy_timeout(database, 100); return database
    }
    private func query(_ db: OpaquePointer, _ sql: String, strings: [String] = [], integers: [Int64] = []) throws -> [[JSONValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NativeAppTools.Failure.unavailable("This Messages database format is unsupported.")
        }
        defer { sqlite3_finalize(statement) }
        for (index, string) in strings.enumerated() {
            _ = string.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        for (index, integer) in integers.enumerated() { sqlite3_bind_int64(statement, Int32(strings.count + index + 1), integer) }
        var rows: [[JSONValue]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw NativeAppTools.Failure.unavailable("Messages is busy or access was revoked.") }
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: return .number(Double(sqlite3_column_int64(statement, column)))
                case SQLITE_NULL: return .null
                default: return sqlite3_column_text(statement, column).map { .string(String(cString: $0)) } ?? .null
                }
            })
        }
        return rows
    }
    private static let individualChats = """
    FROM chat c JOIN chat_handle_join ch ON ch.chat_id=c.ROWID JOIN handle h ON h.ROWID=ch.handle_id
    WHERE c.style=45 AND c.service_name='iMessage' AND h.service='iMessage'
    AND (SELECT COUNT(*) FROM chat_handle_join members WHERE members.chat_id=c.ROWID)=1
    """
    func execute(_ tool: AppTool, _ args: JSONValue) throws -> JSONValue {
        let db = try database(); defer { sqlite3_close(db) }
        let limit = Int64(args["limit"]?.numberValue ?? 25)
        if tool.id == "messages.list" {
            let offset = Int64(args["offset"]?.numberValue ?? 0)
            let rows = try query(db, "SELECT c.guid,h.id,COALESCE(c.display_name,'') " + Self.individualChats
                + " ORDER BY c.ROWID DESC LIMIT ? OFFSET ?", integers: [limit + 1, offset])
            let items: [JSONValue] = rows.prefix(Int(limit)).map { row in
                let id = row[0].stringValue ?? "", address = row[1].stringValue ?? ""
                observed[id] = address
                return ["chat_id": .string(id), "address": .string(address), "name": row[2]]
            }
            return ["items": .array(items), "offset": .number(Double(offset)), "has_more": .bool(rows.count > limit)]
        }
        let id = args["chat_id"]?.stringValue ?? ""
        guard let address = observed[id] else { throw NativeAppTools.Failure.unavailable("List conversations first and choose an exact chat id.") }
        let live = try query(db, "SELECT h.id " + Self.individualChats + " AND c.guid=?", strings: [id])
        guard live.count == 1, live[0][0].stringValue == address else { throw NativeAppTools.Failure.unavailable("The chat changed or is no longer an individual iMessage chat.") }
        if tool.id == "messages.send" {
            guard args["address"]?.stringValue == address else { throw NativeAppTools.Failure.unavailable("The recipient does not match the observed exact chat address.") }
            let script = """
            on send_exact(recipient_address, message_text)
                with timeout of 15 seconds
                    tell application "Messages"
                        set channel to first service whose service type is iMessage
                        set recipient to buddy recipient_address of channel
                        send message_text to recipient
                    end tell
                end timeout
                return "submitted"
            end send_exact
            """
            _ = try AppleScriptRunner.shared.call(script, handler: "send_exact", arguments: [address, args["body"]!.stringValue!])
            return ["status": "submitted", "address": .string(address), "delivery_verified": false,
                    "verification": "Messages accepted the send request; delivery and receipt are not verified."]
        }
        let before = Int64(args["before_row"]?.numberValue ?? 9007199254740991)
        let rows = try query(db, """
        SELECT m.ROWID,m.text,m.is_from_me,m.date,m.cache_has_attachments
        FROM message m JOIN chat_message_join cm ON cm.message_id=m.ROWID JOIN chat c ON c.ROWID=cm.chat_id
        WHERE c.guid=? AND m.ROWID<? AND m.service='iMessage' ORDER BY m.ROWID DESC LIMIT ?
        """, strings: [id], integers: [before, limit + 1])
        let page = Array(rows.prefix(Int(limit)))
        return ["chat_id": .string(id), "address": .string(address), "has_more": .bool(rows.count > limit),
            "next_before_row": page.last?.first ?? .null, "items": .array(page.reversed().map { row in
                ["row": row[0], "text": row[1], "from_me": .bool(row[2].numberValue == 1), "apple_timestamp": row[3],
                 "has_attachments": .bool(row[4].numberValue == 1), "unsupported_text": .bool(row[1] == .null)]
            })]
    }
}
