import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// A Leonard license, verified entirely offline.
///
/// Leonard never phones home, so a license cannot be checked against a
/// server either. A key is a JSON payload and an Ed25519 signature over its
/// exact bytes, both base64url, joined by a dot and prefixed `LEONARD-`. The
/// app holds only the public key; the private key never leaves the machine
/// that issues licenses (`tools/license/issue.py`).
///
/// The model is the one Sketch made familiar: a license works forever for
/// every version released before its `updates_until` date. A newer build
/// shows who it is licensed to and that updates have lapsed, and keeps
/// every existing capability of the version the user paid for — which is
/// why the check compares against the *build* date, never today's date.
public struct LicensePayload: Codable, Sendable, Equatable {
    public var v: Int
    public var id: String
    public var name: String
    public var email: String
    public var edition: String
    public var seats: Int
    public var issued: String
    public var updatesUntil: String

    enum CodingKeys: String, CodingKey {
        case v, id, name, email, edition, seats, issued
        case updatesUntil = "updates_until"
    }

    public init(v: Int = 1, id: String, name: String, email: String, edition: String, seats: Int, issued: String, updatesUntil: String) {
        self.v = v
        self.id = id
        self.name = name
        self.email = email
        self.edition = edition
        self.seats = seats
        self.issued = issued
        self.updatesUntil = updatesUntil
    }

    public var updatesUntilDate: Date? { LicenseDates.parse(updatesUntil) }

    public var editionDisplay: String {
        switch edition {
        case "personal": "Personal"
        case "pro": "Pro"
        case "team": L10n.code == "it" ? "Studio" : "Firm"
        default: edition.capitalized
        }
    }
}

public enum LicenseError: Error, Equatable {
    case malformed
    case badSignature
    case unsupportedVersion
}

public protocol LicenseSignatureVerifier: Sendable {
    func isValidSignature(_ signature: Data, for message: Data) -> Bool
}

#if canImport(CryptoKit)
/// Ed25519 over the payload bytes, with a raw 32-byte public key.
public struct Ed25519Verifier: LicenseSignatureVerifier {
    private let key: Curve25519.Signing.PublicKey

    public init?(publicKeyBase64: String) {
        guard
            let raw = Base64URL.decode(publicKeyBase64) ?? Data(base64Encoded: publicKeyBase64),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else { return nil }
        self.key = key
    }

    public func isValidSignature(_ signature: Data, for message: Data) -> Bool {
        key.isValidSignature(signature, for: message)
    }
}
#endif

public enum LicenseKey {
    public static let prefix = "LEONARD-"

    /// The payload of a well-formed, correctly signed key.
    public static func verify(_ text: String, with verifier: LicenseSignatureVerifier) throws -> LicensePayload {
        let compact = text.components(separatedBy: .whitespacesAndNewlines).joined()
        guard compact.hasPrefix(prefix) else { throw LicenseError.malformed }
        let body = compact.dropFirst(prefix.count)
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard
            parts.count == 2,
            let payloadData = Base64URL.decode(String(parts[0])),
            let signature = Base64URL.decode(String(parts[1]))
        else { throw LicenseError.malformed }
        guard verifier.isValidSignature(signature, for: payloadData) else { throw LicenseError.badSignature }
        guard let payload = try? JSONDecoder().decode(LicensePayload.self, from: payloadData) else {
            throw LicenseError.malformed
        }
        guard payload.v == 1 else { throw LicenseError.unsupportedVersion }
        return payload
    }
}

public enum Base64URL {
    public static func decode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }

    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum LicenseDates {
    public static func parse(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = 23
        components.minute = 59
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)
    }

    public static func display(_ text: String) -> String {
        guard let date = parse(text) else { return text }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: L10n.code == "it" ? "it_IT" : "en_US")
        return formatter.string(from: date)
    }
}

/// What the user may do right now.
public enum Entitlement: Sendable, Equatable {
    case community
    case trial(daysLeft: Int)
    case trialExpired
    case licensed(LicensePayload)
    /// A valid license whose updates ended before this build was made.
    case updatesExpired(LicensePayload)

    public static let trialDays = 14

    /// Proactive suggestions and the command bar. Memory, Mind, settings and
    /// deletion always work: the user's own data is never held hostage.
    public var allowsAssistance: Bool {
        switch self {
        case .community, .trial, .licensed: true
        case .trialExpired, .updatesExpired: false
        }
    }

    public static func evaluate(license: LicensePayload?, trialStart: Date, buildDate: Date, now: Date) -> Entitlement {
        if let license {
            if let until = license.updatesUntilDate, buildDate > until {
                return .updatesExpired(license)
            }
            return .licensed(license)
        }
        let elapsed = max(0, now.timeIntervalSince(trialStart))
        let daysUsed = Int(elapsed / 86400)
        let left = trialDays - daysUsed
        return left > 0 ? .trial(daysLeft: left) : .trialExpired
    }
}
