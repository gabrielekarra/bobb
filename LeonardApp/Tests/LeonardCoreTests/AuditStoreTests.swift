import Foundation
import Testing
@testable import LeonardCore

@Suite("AuditStore reads leonardd's schema read-only")
struct AuditStoreTests {
    /// Builds a fixture database with exactly `leonardd/leonardd/audit.py`'s
    /// schema, via the `sqlite3` CLI, so the test is pinned to the real
    /// on-disk shape rather than a Swift-side re-description of it.
    private func makeFixtureDatabase() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("leonard-audit-test-\(UUID().uuidString).db").path

        let sql = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE decisions (
            decision_id   TEXT PRIMARY KEY,
            event_id      TEXT NOT NULL,
            ts            REAL NOT NULL,
            kind          TEXT NOT NULL,
            app           TEXT,
            event_payload TEXT NOT NULL,
            model         TEXT NOT NULL,
            floor         REAL NOT NULL,
            action        TEXT NOT NULL,
            confidence    REAL NOT NULL,
            schema_mass   REAL NOT NULL,
            latency_ms    REAL NOT NULL,
            abstained     INTEGER NOT NULL DEFAULT 0,
            hypotheses    TEXT NOT NULL,
            readouts      TEXT NOT NULL,
            suggestion    TEXT,
            why           TEXT,
            response      TEXT,
            response_ts   REAL
        );
        INSERT INTO decisions VALUES (
            'dec_1', 'evt_1', 100.0, 'mail.opened', 'Mail',
            '{"sender":"marco@example.com","subject":"Ciao"}',
            'mlx-community/Llama-3.2-3B-Instruct-4bit', 0.6,
            'suggest', 0.83, 0.997, 142.1, 0,
            '[{"intent":"reply_to_email","p":0.88}]',
            '[{"q":"reply_needed","value":true,"p":0.91,"schema_mass":1.0}]',
            '{"title":"Vuoi rispondere?","action_id":"draft_reply","detail":"3 messaggi"}',
            'reply_needed true a 0.91', 'approve', 105.0
        );
        INSERT INTO decisions VALUES (
            'dec_2', 'evt_2', 200.0, 'app.activated', 'Safari',
            '{"previous_app":"Mail"}',
            'mlx-community/Llama-3.2-3B-Instruct-4bit', 0.6,
            'wait', 0.4, 0.99, 12.0, 1,
            '[]', '[{"q":"interrupt","value":"wait","p":0.4,"schema_mass":0.99}]',
            NULL, 'below floor', NULL, NULL
        );
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path, sql]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return path
    }

    @Test func opensReadOnlyAndReadsRecentRows() throws {
        let path = try makeFixtureDatabase()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try AuditStore(path: path)
        let rows = try store.recent(limit: 10)
        #expect(rows.count == 2)
        #expect(rows[0].id == "dec_2")
        #expect(rows[1].id == "dec_1")

        let suggestRow = rows[1]
        #expect(suggestRow.action == .suggest)
        #expect(suggestRow.abstained == false)
        #expect(suggestRow.hypotheses.first?.intent == "reply_to_email")
        #expect(suggestRow.readouts.first?.value == .bool(true))
        #expect(suggestRow.suggestion?.actionId == "draft_reply")
        #expect(suggestRow.response == "approve")
        #expect(suggestRow.responseTs == 105.0)
        #expect(suggestRow.eventPayload["sender"]?.stringValue == "marco@example.com")

        let waitRow = rows[0]
        #expect(waitRow.action == .wait)
        #expect(waitRow.abstained == true)
        #expect(waitRow.suggestion == nil)
        #expect(waitRow.response == nil)
    }

    @Test func searchMatchesKindAppAndWhy() throws {
        let path = try makeFixtureDatabase()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try AuditStore(path: path)

        #expect(try store.search("Safari").map(\.id) == ["dec_2"])
        #expect(try store.search("mail.opened").map(\.id) == ["dec_1"])
        #expect(try store.search("below floor").map(\.id) == ["dec_2"])
        #expect(try store.search("no-such-term").isEmpty)
    }

    @Test func openingMissingFileThrows() {
        #expect(throws: AuditStoreError.self) {
            _ = try AuditStore(path: "/nonexistent/leonard-audit-\(UUID().uuidString).db")
        }
    }
}
