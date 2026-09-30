import Foundation

/// What the screen sensor is allowed to read and when it is worth sending.
///
/// The daemon refuses protected apps too; this is the first line, and the
/// important one, because an app that is never read cannot leak. The rules
/// here run before the accessibility tree is touched at all.
public struct ScreenMemoryPolicy: Sendable {
    /// Always protected, whatever the user adds. Mirrors
    /// `bobbd.settings.DEFAULT_PROTECTED_APPS`.
    public static let builtInProtected: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
        "org.keepassxc.keepassxc", "in.sinew.Enpass-Desktop", "com.apple.keychainaccess",
        "com.apple.Passwords", "com.apple.systempreferences", "com.apple.SecurityAgent",
        "com.apple.loginwindow", "com.apple.ScreenSaver.Engine",
    ]

    /// Window titles that mean "private": a browser's private window, or
    /// the like. Matched case-insensitively as substrings.
    public static let privateTitleMarkers: [String] = [
        "private browsing", "navigazione privata", "incognito", "inprivate", "anonimo",
        "private window", "finestra privata",
    ]

    /// Bobb's own windows are never remembered.
    public static let ownBundleId = "com.bobb.app"

    public var extraProtected: Set<String>
    public var minimumCharacters: Int
    public var maximumCharacters: Int
    /// A window whose text has not changed is not re-sent more often than this.
    public var resendAfter: TimeInterval

    private var lastSent: [String: (hash: Int, at: Date)] = [:]

    public init(extraProtected: [String] = [], minimumCharacters: Int = 40, maximumCharacters: Int = 20_000, resendAfter: TimeInterval = 600) {
        self.extraProtected = Set(extraProtected)
        self.minimumCharacters = minimumCharacters
        self.maximumCharacters = maximumCharacters
        self.resendAfter = resendAfter
    }

    public func isProtected(bundleId: String?, appName: String) -> Bool {
        if let bundleId {
            if bundleId == Self.ownBundleId || Self.builtInProtected.contains(bundleId) || extraProtected.contains(bundleId) {
                return true
            }
        }
        return extraProtected.contains(appName)
    }

    public func isPrivateWindow(title: String) -> Bool {
        let lowered = title.lowercased()
        return Self.privateTitleMarkers.contains { lowered.contains($0) }
    }

    /// May the sensor read this window at all?
    public func mayRead(bundleId: String?, appName: String, windowTitle: String) -> Bool {
        !isProtected(bundleId: bundleId, appName: appName) && !isPrivateWindow(title: windowTitle)
    }

    /// The frame to send for text read from a window, or nil when it is too
    /// short or identical to what was sent for the same window recently.
    public mutating func frame(
        app: String, bundleId: String?, window: String, text: String, url: String? = nil, now: Date = Date()
    ) -> MemoryObserveFrame? {
        guard mayRead(bundleId: bundleId, appName: app, windowTitle: window) else { return nil }
        let cleaned = Self.normalize(text, limit: maximumCharacters)
        guard cleaned.count >= minimumCharacters else { return nil }
        let key = "\(bundleId ?? app)\u{1F}\(window)"
        let hash = cleaned.hashValue
        if let last = lastSent[key], last.hash == hash, now.timeIntervalSince(last.at) < resendAfter {
            return nil
        }
        lastSent[key] = (hash, now)
        if lastSent.count > 500 {
            lastSent = lastSent.filter { now.timeIntervalSince($0.value.at) < resendAfter }
        }
        return MemoryObserveFrame(
            ts: now.timeIntervalSince1970, app: app, bundleId: bundleId, window: window, text: cleaned, url: url
        )
    }

    /// Collapse whitespace per line, drop blank and duplicate adjacent
    /// lines, cap the length.
    public static func normalize(_ text: String, limit: Int) -> String {
        var lines: [String] = []
        var previous = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            guard !line.isEmpty, line != previous else { continue }
            lines.append(line)
            previous = line
        }
        let joined = lines.joined(separator: "\n")
        return joined.count > limit ? String(joined.prefix(limit)) : joined
    }
}
