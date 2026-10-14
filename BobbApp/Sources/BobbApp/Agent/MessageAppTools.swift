import Foundation
import SQLite3
import BobbCore

/// Requested conversations only. The self-chat command listener remains
/// separate and still rejects groups and SMS as command sources.
@MainActor
final class MessageAppTools {
    private struct Chat: Equatable { var service: String; var members: [String] }
    private let databaseURL: URL
    init(databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")) { self.databaseURL = databaseURL }
    private var observed: [String: Chat] = [:]
    private var attachments: [String: (chat: String, path: String)] = [:]
    private func database() throws -> OpaquePointer {
        let path = databaseURL.path
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw NativeAppTools.Failure.unavailable("Allow Full Disk Access for Bobb to read Messages.")
        }
        sqlite3_busy_timeout(database, 100); return database
    }
    private func query(_ db: OpaquePointer, _ sql: String, strings: [String] = [], integers: [Int64] = []) throws -> [[JSONValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw NativeAppTools.Failure.unavailable("This Messages database format is unsupported.") }
        defer { sqlite3_finalize(statement) }
        for (index, string) in strings.enumerated() {
            _ = string.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        for (index, integer) in integers.enumerated() { sqlite3_bind_int64(statement, Int32(strings.count + index + 1), integer) }
        var rows: [[JSONValue]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, rows.count < 1000 else { throw NativeAppTools.Failure.unavailable("Messages is busy or access was revoked.") }
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: return .number(Double(sqlite3_column_int64(statement, column)))
                case SQLITE_NULL: return .null
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    guard count > 0, count <= 65536, let bytes = sqlite3_column_blob(statement, column) else { return .null }
                    return .string(Data(bytes: bytes, count: count).base64EncodedString())
                default: return sqlite3_column_text(statement, column).map { .string(String(cString: $0)) } ?? .null
                }
            })
        }
        return rows
    }
    private func chat(_ db: OpaquePointer, id: String) throws -> Chat? {
        let rows = try query(db, "SELECT c.service_name,h.id FROM chat c JOIN chat_handle_join ch ON ch.chat_id=c.ROWID JOIN handle h ON h.ROWID=ch.handle_id WHERE c.guid=? ORDER BY h.id", strings: [id])
        guard !rows.isEmpty, rows.count <= 100, let service = rows[0][0].stringValue, ["iMessage", "SMS"].contains(service),
              rows.allSatisfy({ $0[0].stringValue == service && $0[1].stringValue != nil }) else { return nil }
        return Chat(service: service, members: rows.compactMap { $0[1].stringValue }.sorted())
    }
    private func text(_ plain: JSONValue, archive: JSONValue) -> String? {
        if let value = plain.stringValue { return value }
        guard let raw = archive.stringValue, let data = Data(base64Encoded: raw) else { return nil }
        if data.starts(with: Data("bplist".utf8)) {
            return (try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSAttributedString.self, NSMutableAttributedString.self, NSString.self,
                NSMutableString.self, NSDictionary.self, NSArray.self, NSNumber.self], from: data) as? NSAttributedString)?.string
        }
        let values = Set(MessagesCommandDecoder.archivedStrings(data))
        return values.count == 1 ? values.first : nil
    }
    func execute(_ tool: AppTool, _ args: JSONValue) throws -> JSONValue {
        let db = try database(); defer { sqlite3_close(db) }
        let limit = Int64(args["limit"]?.numberValue ?? 25)
        if tool.id == "messages.list" {
            let offset = Int64(args["offset"]?.numberValue ?? 0)
            let rows = try query(db, "SELECT c.guid,COALESCE(c.display_name,'') FROM chat c WHERE c.service_name IN ('iMessage','SMS') ORDER BY c.ROWID DESC LIMIT ? OFFSET ?", integers: [limit + 1, offset])
            var items: [JSONValue] = []
            for row in rows.prefix(Int(limit)) {
                guard let id = row[0].stringValue, let live = try chat(db, id: id) else { continue }
                observed[id] = live
                items.append(["chat_id": .string(id), "name": row[1], "service": .string(live.service),
                    "members": .array(live.members.map(JSONValue.string)), "group": .bool(live.members.count > 1),
                    "address": live.members.count == 1 ? .string(live.members[0]) : .null])
            }
            return ["items": .array(items), "offset": .number(Double(offset)), "next_offset": .number(Double(offset + limit)), "has_more": .bool(rows.count > limit)]
        }
        let id = args["chat_id"]?.stringValue ?? ""
        guard let previous = observed[id], let live = try chat(db, id: id), live == previous else { throw NativeAppTools.Failure.unavailable("List conversations first; the exact chat or its recipients changed.") }
        if tool.id == "messages.send" {
            let members = args["members"]?.arrayValue?.compactMap(\.stringValue).sorted()
            guard members == live.members || (live.members.count == 1 && args["address"]?.stringValue == live.members.first) else { throw NativeAppTools.Failure.unavailable("Provide the complete exact observed recipient list; never guess a group.") }
            let script = """
            on send_exact(chat_identifier, message_text)
                with timeout of 15 seconds
                    tell application "Messages"
                        set matches to every chat whose id is chat_identifier
                        if (count of matches) is not 1 then error "Exact conversation unavailable"
                        send message_text to item 1 of matches
                    end tell
                end timeout
                return "submitted"
            end send_exact
            """
            _ = try AppleScriptRunner.shared.call(script, handler: "send_exact", arguments: [id, args["body"]!.stringValue!])
            return ["status": "submitted", "chat_id": .string(id), "members": .array(live.members.map(JSONValue.string)), "delivery_verified": false,
                    "verification": "Messages accepted the send request; delivery and receipt are not verified. SMS requires the user's configured relay."]
        }
        if tool.id == "messages.attachment" {
            guard let guid = args["attachment_id"]?.stringValue, let previous = attachments[guid], previous.chat == id else { throw NativeAppTools.Failure.unavailable("Read the conversation first and choose an exact attachment id.") }
            let rows = try attachmentRows(db, chatID: id, attachmentID: guid)
            guard rows.count == 1, rows[0][1].stringValue == previous.path else { throw NativeAppTools.Failure.unavailable("The attachment changed or is unavailable.") }
            let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/Attachments").resolvingSymlinksInPath()
            let expanded = (previous.path as NSString).expandingTildeInPath
            guard expanded.hasPrefix(root.path + "/"), let url = FileScope.resolve(String(expanded.dropFirst(root.path.count + 1)), root: root) else { throw NativeAppTools.Failure.unavailable("The attachment is outside the Messages attachment store.") }
            let content = try FileAppTools.text(url), offset = Int(args["offset"]?.numberValue ?? 0)
            return ["attachment_id": .string(guid), "text": .string(String(content.dropFirst(offset).prefix(4000))),
                "next_offset": .number(Double(min(content.count, offset + 4000))), "has_more": .bool(offset + 4000 < content.count), "total_characters": .number(Double(content.count))]
        }
        let before = Int64(args["before_row"]?.numberValue ?? 9007199254740991)
        let rows = try query(db, """
        SELECT m.ROWID,m.text,m.is_from_me,m.date,m.cache_has_attachments,m.attributedBody,COALESCE(h.id,'')
        FROM message m JOIN chat_message_join cm ON cm.message_id=m.ROWID JOIN chat c ON c.ROWID=cm.chat_id LEFT JOIN handle h ON h.ROWID=m.handle_id
        WHERE c.guid=? AND m.ROWID<? ORDER BY m.ROWID DESC LIMIT ?
        """, strings: [id], integers: [before, limit + 1])
        let page = Array(rows.prefix(Int(limit)))
        var items: [JSONValue] = []
        for row in page.reversed() {
            let content = text(row[1], archive: row[5])
            let files = try attachmentRows(db, chatID: id, messageRow: Int64(row[0].numberValue ?? 0)).map { file -> JSONValue in
                let guid = file[0].stringValue ?? ""
                if let path = file[1].stringValue { attachments[guid] = (id, path) }
                return ["attachment_id": .string(guid), "name": file[2], "mime_type": file[3], "bytes": file[4]]
            }
            items.append(["row": row[0], "text": content.map(JSONValue.string) ?? .null, "from_me": .bool(row[2].numberValue == 1),
                "sender": row[6], "apple_timestamp": row[3], "attachments": .array(files), "unsupported_text": .bool(content == nil)])
        }
        return ["chat_id": .string(id), "members": .array(live.members.map(JSONValue.string)), "has_more": .bool(rows.count > limit),
            "next_before_row": page.last?.first ?? .null, "items": .array(items)]
    }
    private func attachmentRows(_ db: OpaquePointer, chatID: String, attachmentID: String? = nil, messageRow: Int64? = nil) throws -> [[JSONValue]] {
        let suffix = attachmentID != nil ? " AND a.guid=?" : " AND m.ROWID=?"
        return try query(db, """
        SELECT DISTINCT a.guid,a.filename,COALESCE(a.transfer_name,''),COALESCE(a.mime_type,''),a.total_bytes
        FROM attachment a JOIN message_attachment_join ma ON ma.attachment_id=a.ROWID JOIN message m ON m.ROWID=ma.message_id
        JOIN chat_message_join cm ON cm.message_id=m.ROWID JOIN chat c ON c.ROWID=cm.chat_id WHERE c.guid=?
        """ + suffix + " LIMIT 100", strings: [chatID] + (attachmentID.map { [$0] } ?? []), integers: messageRow.map { [$0] } ?? [])
    }
}
