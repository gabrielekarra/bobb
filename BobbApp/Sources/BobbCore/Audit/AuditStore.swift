import Foundation
import SQLite3

/// One row of `bobbd`'s `decisions` table: what it noticed, what it
/// decided, why, and — once it arrives — what the user did about it.
public struct AuditRecord: Identifiable, Sendable, Equatable {
    public var id: String
    public var eventId: String
    public var ts: Double
    public var kind: String
    public var app: String?
    public var eventPayload: JSONValue
    public var model: String
    public var floor: Double
    public var action: DecisionAction
    public var confidence: Double
    public var schemaMass: Double
    public var latencyMs: Double
    public var abstained: Bool
    public var hypotheses: [Hypothesis]
    public var readouts: [Readout]
    public var suggestion: Suggestion?
    public var why: String?
    public var response: String?
    public var responseTs: Double?
}

public enum AuditStoreError: Error, CustomStringConvertible {
    case openFailed(String)
    case queryFailed(String)

    public var description: String {
        switch self {
        case .openFailed(let message): "could not open audit store: \(message)"
        case .queryFailed(let message): "audit query failed: \(message)"
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Read-only access to `~/Library/Application Support/Bobb/audit.db`.
///
/// `bobbd` owns this database and keeps it in WAL mode while it runs;
/// this type never opens it for writing and never competes with the daemon
/// for the write lock. It is safe to construct and query concurrently with
/// the daemon appending rows.
public final class AuditStore: @unchecked Sendable {
    private let db: OpaquePointer
    public let path: String

    public init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 rc=\(rc)"
            if let handle { sqlite3_close(handle) }
            throw AuditStoreError.openFailed(message)
        }
        self.db = handle
    }

    deinit {
        sqlite3_close(db)
    }

    public func recent(limit: Int = 200) throws -> [AuditRecord] {
        try query(Self.selectSQL + " ORDER BY ts DESC LIMIT ?") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(limit))
        }
    }

    public func search(_ text: String, limit: Int = 200) throws -> [AuditRecord] {
        guard !text.isEmpty else { return try recent(limit: limit) }
        let like = "%\(text)%"
        return try query(
            Self.selectSQL + " WHERE kind LIKE ?1 OR app LIKE ?1 OR why LIKE ?1 OR event_payload LIKE ?1 OR suggestion LIKE ?1 ORDER BY ts DESC LIMIT ?2"
        ) { stmt in
            sqlite3_bind_text(stmt, 1, like, -1, sqliteTransient)
            sqlite3_bind_int(stmt, 2, Int32(limit))
        }
    }

    private static let selectSQL = """
        SELECT decision_id, event_id, ts, kind, app, event_payload, model, floor,
               action, confidence, schema_mass, latency_ms, abstained,
               hypotheses, readouts, suggestion, why, response, response_ts
        FROM decisions
        """

    private func query(_ sql: String, bind: (OpaquePointer) -> Void) throws -> [AuditRecord] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw AuditStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var records: [AuditRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            records.append(Self.record(from: stmt))
        }
        return records
    }

    private static func record(from stmt: OpaquePointer) -> AuditRecord {
        func text(_ index: Int32) -> String? {
            sqlite3_column_text(stmt, index).map { String(cString: $0) }
        }
        func real(_ index: Int32) -> Double { sqlite3_column_double(stmt, index) }
        func isNull(_ index: Int32) -> Bool { sqlite3_column_type(stmt, index) == SQLITE_NULL }

        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ index: Int32, as type: T.Type) -> T? {
            guard let raw = text(index), let data = raw.data(using: .utf8) else { return nil }
            return try? decoder.decode(T.self, from: data)
        }

        return AuditRecord(
            id: text(0) ?? "",
            eventId: text(1) ?? "",
            ts: real(2),
            kind: text(3) ?? "",
            app: text(4),
            eventPayload: decode(5, as: JSONValue.self) ?? .object([:]),
            model: text(6) ?? "",
            floor: real(7),
            action: DecisionAction(rawValue: text(8) ?? "") ?? .wait,
            confidence: real(9),
            schemaMass: real(10),
            latencyMs: real(11),
            abstained: sqlite3_column_int(stmt, 12) != 0,
            hypotheses: decode(13, as: [Hypothesis].self) ?? [],
            readouts: decode(14, as: [Readout].self) ?? [],
            suggestion: decode(15, as: Suggestion.self),
            why: text(16),
            response: text(17),
            responseTs: isNull(18) ? nil : real(18)
        )
    }
}
