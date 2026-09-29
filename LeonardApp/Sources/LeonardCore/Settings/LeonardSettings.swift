import Foundation

/// Everything the user can change, persisted as one JSON file in the
/// Application Support directory. The app owns these; the part the daemon
/// enforces is sent to it as a `settings` frame after every `hello`.
///
/// Decoding is lenient field by field: a settings file written by a newer
/// version, or damaged by hand, loses only the fields it cannot read.
public struct LeonardSettings: Codable, Sendable, Equatable {
    public var language: AppLanguage = .system
    public var floor: Double = 0.60
    public var adaptive: Bool = true
    public var mailProactive: Bool = true
    /// Conversations in chat apps (Slack, WhatsApp, Messages, Teams…).
    public var chatProactive: Bool = true
    /// A brief before meetings with other people (Calendar).
    public var meetingPrep: Bool = true
    /// Keep track of what the user promises in the mail they send.
    public var trackPromises: Bool = true
    public var toneCheck: Bool = true
    public var quietHoursEnabled: Bool = false
    public var quietFrom: Int = 20
    public var quietTo: Int = 8
    public var overlaySeconds: Int = 14
    public var memoryEnabled: Bool = true
    /// Read the words in windows that expose no text (needs Screen Recording).
    public var readImages: Bool = false
    public var memoryRetentionDays: Int = 30
    public var historyRetentionDays: Int = 90
    public var extraProtectedApps: [String] = []
    public var hotkey: Hotkey = .default
    /// Opens the command bar already listening.
    public var talkHotkey: Hotkey = .talk
    public var launchAtLogin: Bool = true
    public var onboardingCompleted: Bool = false
    public var watching: Bool = true
    /// Whether Leonard may operate applications to carry out requests.
    public var actingEnabled: Bool = true
    public var actingApproval: ActingApproval = .important
    public var actionAllowRules: [ActionAllowRule] = []

    public init() {}

    public static let retentionChoices = [7, 14, 30, 90, 180, 365]

    public var quietHours: [Int]? {
        quietHoursEnabled && quietFrom != quietTo ? [quietFrom, quietTo] : nil
    }

    /// The event kinds the daemon may interrupt for.
    public var proactiveKinds: [String] {
        var kinds: [String] = []
        if mailProactive { kinds.append(EventKind.mailOpened.rawValue) }
        if chatProactive { kinds.append(EventKind.messageOpened.rawValue) }
        if meetingPrep { kinds.append(EventKind.calendarUpcoming.rawValue) }
        if toneCheck { kinds.append(EventKind.mailComposing.rawValue) }
        return kinds
    }

    public func daemonFrame() -> DaemonSettingsFrame {
        DaemonSettingsFrame(
            floor: floor,
            locale: language.code,
            proactiveKinds: proactiveKinds,
            quietHours: quietHours,
            adaptive: adaptive,
            memoryEnabled: memoryEnabled,
            memoryRetentionDays: memoryRetentionDays,
            historyRetentionDays: historyRetentionDays,
            extraProtectedApps: extraProtectedApps
        )
    }

    enum CodingKeys: String, CodingKey {
        case language, floor, adaptive, mailProactive, chatProactive, meetingPrep, trackPromises, toneCheck, quietHoursEnabled, quietFrom, quietTo,
             overlaySeconds, memoryEnabled, readImages, memoryRetentionDays, historyRetentionDays, extraProtectedApps,
             hotkey, talkHotkey, launchAtLogin, onboardingCompleted, watching, actingEnabled, actingApproval, actionAllowRules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var s = LeonardSettings()
        func read<T: Decodable>(_ key: CodingKeys, _ type: T.Type) -> T? {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil
        }
        if let v = read(.language, AppLanguage.self) { s.language = v }
        if let v = read(.floor, Double.self), (0...1).contains(v) { s.floor = v }
        if let v = read(.adaptive, Bool.self) { s.adaptive = v }
        if let v = read(.mailProactive, Bool.self) { s.mailProactive = v }
        if let v = read(.chatProactive, Bool.self) { s.chatProactive = v }
        if let v = read(.meetingPrep, Bool.self) { s.meetingPrep = v }
        if let v = read(.trackPromises, Bool.self) { s.trackPromises = v }
        if let v = read(.toneCheck, Bool.self) { s.toneCheck = v }
        if let v = read(.quietHoursEnabled, Bool.self) { s.quietHoursEnabled = v }
        if let v = read(.quietFrom, Int.self), (0...23).contains(v) { s.quietFrom = v }
        if let v = read(.quietTo, Int.self), (0...23).contains(v) { s.quietTo = v }
        if let v = read(.overlaySeconds, Int.self), (4...120).contains(v) { s.overlaySeconds = v }
        if let v = read(.memoryEnabled, Bool.self) { s.memoryEnabled = v }
        if let v = read(.readImages, Bool.self) { s.readImages = v }
        if let v = read(.memoryRetentionDays, Int.self), (1...3650).contains(v) { s.memoryRetentionDays = v }
        if let v = read(.historyRetentionDays, Int.self), (1...3650).contains(v) { s.historyRetentionDays = v }
        if let v = read(.extraProtectedApps, [String].self) { s.extraProtectedApps = v }
        if let v = read(.hotkey, Hotkey.self) { s.hotkey = v }
        if let v = read(.talkHotkey, Hotkey.self) { s.talkHotkey = v }
        if let v = read(.launchAtLogin, Bool.self) { s.launchAtLogin = v }
        if let v = read(.onboardingCompleted, Bool.self) { s.onboardingCompleted = v }
        if let v = read(.watching, Bool.self) { s.watching = v }
        if let v = read(.actingEnabled, Bool.self) { s.actingEnabled = v }
        if let v = read(.actingApproval, ActingApproval.self) { s.actingApproval = v }
        if let v = read(.actionAllowRules, [ActionAllowRule].self) { s.actionAllowRules = v }
        self = s
    }
}

/// A global shortcut: a virtual key code and Carbon-style modifier flags.
/// Default ⌥Space, the same muscle memory as Spotlight's neighbour.
public struct Hotkey: Codable, Sendable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // Carbon modifier bits (Events.h): cmdKey 1<<8, shiftKey 1<<9,
    // optionKey 1<<11, controlKey 1<<12. kVK_Space is 49.
    public static let command: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12

    public static let `default` = Hotkey(keyCode: 49, modifiers: option)
    /// ⌥⇧Space: the same key, with Shift, to talk instead of type.
    public static let talk = Hotkey(keyCode: 49, modifiers: option | shift)

    public var display: String {
        var out = ""
        if modifiers & Hotkey.control != 0 { out += "⌃" }
        if modifiers & Hotkey.option != 0 { out += "⌥" }
        if modifiers & Hotkey.shift != 0 { out += "⇧" }
        if modifiers & Hotkey.command != 0 { out += "⌘" }
        return out + Hotkey.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [
            49: "Space", 36: "↩", 48: "⇥", 53: "⎋", 0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G",
            4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R",
            1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        ]
        return names[code] ?? "#\(code)"
    }
}

/// Reads and writes `LeonardSettings` atomically, owner-only.
public struct SettingsStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> LeonardSettings {
        guard let data = try? Data(contentsOf: url) else { return LeonardSettings() }
        return (try? JSONDecoder().decode(LeonardSettings.self, from: data)) ?? LeonardSettings()
    }

    public func save(_ settings: LeonardSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
