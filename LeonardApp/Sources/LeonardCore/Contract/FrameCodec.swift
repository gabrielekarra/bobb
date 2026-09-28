import Foundation

/// A `CodingKey` that accepts any JSON object key, used where a frame's
/// fields are merged with a synthesized `"t"` discriminator or a free-form
/// field set rather than a fixed, closed key list.
struct DynamicKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

enum FrameCodecError: Error {
    case missingType
    case notAnObject
}

/// Every line on the wire, in either direction, is a JSON object carrying
/// `t` alongside the type-specific fields. `FrameCodec` is the single place
/// that stitches `t` onto an otherwise plain `Encodable` payload, and the
/// single place that reads it back off before dispatching to a concrete
/// frame type — so every frame struct in `OutgoingFrame`/`IncomingFrame` can
/// stay a plain, ordinary `Codable` with no knowledge of its own `t`.
public enum FrameCodec {
    static let encoder: JSONEncoder = JSONEncoder()
    static let decoder: JSONDecoder = JSONDecoder()

    static func data<T: Encodable>(type: String, payload: T) throws -> Data {
        let payloadValue = try decoder.decode(JSONValue.self, from: encoder.encode(payload))
        guard case .object(var fields) = payloadValue else { throw FrameCodecError.notAnObject }
        fields["t"] = .string(type)
        return try encoder.encode(JSONValue.object(fields))
    }

    static func readType(from data: Data) throws -> String {
        let value = try decoder.decode(JSONValue.self, from: data)
        guard case .object(let fields) = value else { throw FrameCodecError.notAnObject }
        guard case .string(let type)? = fields["t"] else { throw FrameCodecError.missingType }
        return type
    }

    static func payload<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(T.self, from: data)
    }
}
