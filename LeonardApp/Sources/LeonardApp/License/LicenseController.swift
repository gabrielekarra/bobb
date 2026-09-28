import Foundation
import Observation
import Security
import LeonardCore

/// Owns the license key and the trial clock, and turns them into an
/// `Entitlement`. Entirely offline: the key is verified against the public
/// key in Info.plist and never sent anywhere.
///
/// The trial start is written to both the Keychain and the settings
/// directory, and the earlier of the two wins, so deleting one does not
/// restart the trial. That is a speed bump, not DRM, and it is meant to be:
/// people who pay for software they can trust are the market; people who
/// work hard to avoid paying are not.
@MainActor
@Observable
final class LicenseController {
    private(set) var entitlement: Entitlement = .trial(daysLeft: Entitlement.trialDays)
    private(set) var license: LicensePayload?
    private(set) var lastError: String?

    private let verifier: LicenseSignatureVerifier?
    private let licenseFile: URL
    private let trialFile: URL
    private static let keychainService = "app.leonard.trial"

    init(licenseFile: URL, trialFile: URL, publicKey: String) {
        self.licenseFile = licenseFile
        self.trialFile = trialFile
        self.verifier = Ed25519Verifier(publicKeyBase64: publicKey)
        if let text = (try? String(contentsOf: licenseFile, encoding: .utf8)) ?? Self.managedKey, let verifier,
           let payload = try? LicenseKey.verify(text, with: verifier) {
            license = payload
        }
        evaluate()
    }

    /// A key deployed by an administrator in a configuration profile
    /// (managed preferences for the app's bundle id, key `LicenseKey`), used
    /// when the user has not activated one themselves. docs/DEPLOYMENT.md.
    static var managedKey: String? {
        UserDefaults.standard.string(forKey: "LicenseKey")
    }

    var trialStart: Date {
        let candidates = [Self.readKeychainDate(), Self.readFileDate(trialFile)].compactMap { $0 }
        if let earliest = candidates.min() { return earliest }
        let now = Date()
        Self.writeKeychainDate(now)
        Self.writeFileDate(now, to: trialFile)
        return now
    }

    func evaluate(now: Date = Date()) {
        entitlement = Entitlement.evaluate(license: license, trialStart: trialStart, buildDate: BuildInfo.buildDate, now: now)
    }

    /// Verifies and stores a pasted key. Returns true on success.
    @discardableResult
    func activate(_ text: String) -> Bool {
        guard let verifier else {
            lastError = "no public key"
            return false
        }
        do {
            let payload = try LicenseKey.verify(text, with: verifier)
            let compact = text.components(separatedBy: .whitespacesAndNewlines).joined()
            try compact.write(to: licenseFile, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: licenseFile.path)
            license = payload
            lastError = nil
            evaluate()
            return true
        } catch {
            lastError = L10n.t(.licenseInvalid)
            return false
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: licenseFile)
        license = nil
        evaluate()
    }

    // MARK: Trial clock storage

    private static func readFileDate(_ url: URL) -> Date? {
        guard let text = try? String(contentsOf: url, encoding: .utf8), let seconds = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func writeFileDate(_ date: Date, to url: URL) {
        try? String(date.timeIntervalSince1970).write(to: url, atomically: true, encoding: .utf8)
    }

    private static func readKeychainDate() -> Date? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "trial-start",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let text = String(data: data, encoding: .utf8), let seconds = Double(text)
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func writeKeychainDate(_ date: Date) {
        let data = Data(String(date.timeIntervalSince1970).utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "trial-start",
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
