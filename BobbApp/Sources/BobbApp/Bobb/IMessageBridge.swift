import Foundation
import SQLite3
import Observation
import BobbCore

/// Opt-in, read-only access to Messages' local database. Exact self chat,
/// explicit /bobb prefix, durable high-water mark, no group or SMS commands.
@MainActor
@Observable
final class IMessageBridge {
    var status = "Disabled"
    var onCommand: ((String, String) -> Void)?
    private var timer: Timer?
    private var lastRow: Int64 = 0
    private var address = ""
    private var needsBaseline = true
    private let cursorURL = AppPaths.dataDirectory.appendingPathComponent("imessage-cursor.json")

    func configure(enabled: Bool, address: String) {
        if enabled, !address.isEmpty, self.address == address, timer != nil { return }
        stop()
        guard enabled, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        self.address = address
        if let data = try? Data(contentsOf: cursorURL), let cursor = try? JSONDecoder().decode(Cursor.self, from: data), cursor.address == address {
            lastRow = cursor.row
            needsBaseline = false
        } else {
            // Start at the newest message, never turn old notes into requests.
            needsBaseline = true
            if let newest = newestRow() { lastRow = newest; needsBaseline = false; saveCursor() }
        }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil; address = ""; needsBaseline = true; status = "Disabled" }
    private struct Cursor: Codable { var address: String; var row: Int64 }
    private func saveCursor() {
        if let data = try? JSONEncoder().encode(Cursor(address: address, row: lastRow)) {
            try? data.write(to: cursorURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cursorURL.path)
        }
    }
    private func database() -> OpaquePointer? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db").path
        var db: OpaquePointer?
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) != SQLITE_OK {
            if let db { sqlite3_close(db) }; status = "Allow Full Disk Access for Bobb to read Messages."; return nil
        }
        sqlite3_busy_timeout(db, 100)
        return db
    }
    private func newestRow() -> Int64? {
        guard let db = database() else { return nil }; defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(ROWID),0) FROM message", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : nil
    }
    private func poll() {
        guard !address.isEmpty else { return }
        if needsBaseline {
            guard let newest = newestRow() else { return }
            lastRow = newest; needsBaseline = false; saveCursor()
        }
        guard let db = database() else { return }; defer { sqlite3_close(db) }
        let sql = """
        SELECT m.ROWID,m.text,m.attributedBody FROM message m
        JOIN chat_message_join cm ON cm.message_id=m.ROWID
        JOIN chat c ON c.ROWID=cm.chat_id
        WHERE m.ROWID>? AND m.service='iMessage' AND c.style=45 AND c.chat_identifier=?
        AND (SELECT COUNT(*) FROM chat_handle_join ch WHERE ch.chat_id=c.ROWID)=1
        ORDER BY m.ROWID LIMIT 100
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { status = "Messages database format is not supported."; return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, lastRow)
        address.withCString { pointer in
            _ = sqlite3_bind_text(statement, 2, pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            lastRow = max(lastRow, sqlite3_column_int64(statement, 0))
            // Commit before dispatch; a crash cannot duplicate a remote send.
            saveCursor()
            var plain = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let count = Int(sqlite3_column_bytes(statement, 2))
            let body = count > 0 && count <= 65536 ? sqlite3_column_blob(statement, 2).map { Data(bytes: $0, count: count) } : nil
            if plain == nil, let body, body.starts(with: Data("bplist".utf8)),
               let value = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSAttributedString.self, NSMutableAttributedString.self, NSString.self,
                  NSMutableString.self, NSDictionary.self, NSArray.self, NSNumber.self], from: body) as? NSAttributedString {
                plain = value.string
            }
            guard let command = MessagesCommandDecoder.decode(plain: plain, attributedBody: body) else { continue }
            onCommand?(command, address)
        }
        status = "Listening to your self chat. Start commands with /bobb."
    }
    func reply(_ text: String, to exactAddress: String) throws {
        guard !address.isEmpty, exactAddress == address else { throw CloudError.configuration }
        let source = """
        on reply_to_self(recipient_address, reply_text)
            tell application "Messages"
                set channel to first service whose service type is iMessage
                set recipient to buddy recipient_address of channel
                send reply_text to recipient
            end tell
            return "ok"
        end reply_to_self
        """
        _ = try AppleScriptRunner.shared.call(source, handler: "reply_to_self", arguments: [exactAddress, "[Bobb] " + String(text.prefix(6000))])
    }
}
