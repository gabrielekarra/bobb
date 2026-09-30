import Foundation

/// An `event.payload`. `typing` and `idle` are standard on every event kind
/// per the contract; everything else is free-form and kind-specific, so it
/// is kept as a flat bag of `JSONValue` rather than a closed struct.
public struct EventPayload: Sendable, Equatable {
    public var typing: Bool?
    public var idle: Bool?
    public var fields: [String: JSONValue]

    public init(typing: Bool?, idle: Bool?, fields: [String: JSONValue] = [:]) {
        self.typing = typing
        self.idle = idle
        self.fields = fields
    }

    public subscript(key: String) -> JSONValue? {
        get { fields[key] }
        set { fields[key] = newValue }
    }
}

extension EventPayload: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var fields: [String: JSONValue] = [:]
        var typing: Bool?
        var idle: Bool?
        for key in container.allKeys {
            switch key.stringValue {
            case "typing":
                typing = try container.decodeIfPresent(Bool.self, forKey: key)
            case "idle":
                idle = try container.decodeIfPresent(Bool.self, forKey: key)
            default:
                fields[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
            }
        }
        self.init(typing: typing, idle: idle, fields: fields)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        for (key, value) in fields {
            guard let codingKey = DynamicKey(stringValue: key) else { continue }
            try container.encode(value, forKey: codingKey)
        }
        if let typing, let key = DynamicKey(stringValue: "typing") {
            try container.encode(typing, forKey: key)
        }
        if let idle, let key = DynamicKey(stringValue: "idle") {
            try container.encode(idle, forKey: key)
        }
    }
}

/// App → daemon `event`: something happened on the desktop.
public struct EventFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var id: String
    public var kind: EventKind
    public var app: String
    public var payload: EventPayload

    public init(ts: Double = Date().timeIntervalSince1970, id: String = EventFrame.newID(), kind: EventKind, app: String, payload: EventPayload) {
        self.ts = ts
        self.id = id
        self.kind = kind
        self.app = app
        self.payload = payload
    }

    public static func newID() -> String {
        "evt_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20))
    }
}
