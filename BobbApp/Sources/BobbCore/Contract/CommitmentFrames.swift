import Foundation

/// A promise the user made, found in a message they sent.
public struct Commitment: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var ts: Double
    public var person: String
    public var address: String?
    public var what: String
    public var dueTs: Double?
    public var source: String
    public var subject: String?
    public var status: String

    enum CodingKeys: String, CodingKey {
        case id, ts, person, address, what, source, subject, status
        case dueTs = "due_ts"
    }

    public init(id: String, ts: Double, person: String, address: String? = nil, what: String, dueTs: Double? = nil,
                source: String = "mail.sent", subject: String? = nil, status: String = "open") {
        self.id = id
        self.ts = ts
        self.person = person
        self.address = address
        self.what = what
        self.dueTs = dueTs
        self.source = source
        self.subject = subject
        self.status = status
    }

    /// Worth showing under "For you": due within two days, overdue, or
    /// undated and made in the last three days.
    public func isDueSoon(now: Date = Date()) -> Bool {
        guard status == "open" else { return false }
        let t = now.timeIntervalSince1970
        if let dueTs { return dueTs - t < 2 * 86400 }
        return t - ts < 3 * 86400
    }

    public func isOverdue(now: Date = Date()) -> Bool {
        guard let dueTs else { return false }
        return dueTs < now.timeIntervalSince1970
    }
}

/// Daemon → app `commitment`: a promise just found.
public struct CommitmentFoundFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var item: Commitment

    public init(ts: Double, item: Commitment) {
        self.ts = ts
        self.item = item
    }
}

/// Daemon → app `commitments`: the open promises.
public struct CommitmentsFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var requestId: String?
    public var items: [Commitment]

    enum CodingKeys: String, CodingKey {
        case ts, items
        case requestId = "request_id"
    }

    public init(ts: Double, requestId: String?, items: [Commitment]) {
        self.ts = ts
        self.requestId = requestId
        self.items = items
    }
}

public struct CommitmentsListFrame: Codable, Sendable, Equatable {
    public var id: String
    public var status: String

    public init(id: String = RequestFrame.newID(), status: String = "open") {
        self.id = id
        self.status = status
    }
}

public struct CommitmentUpdateFrame: Codable, Sendable, Equatable {
    public var id: String
    public var commitmentId: String
    public var status: String?
    public var dueTs: Double?

    enum CodingKeys: String, CodingKey {
        case id, status
        case commitmentId = "commitment_id"
        case dueTs = "due_ts"
    }

    public init(id: String = RequestFrame.newID(), commitmentId: String, status: String? = nil, dueTs: Double? = nil) {
        self.id = id
        self.commitmentId = commitmentId
        self.status = status
        self.dueTs = dueTs
    }
}
