import Foundation

/// The keys Leonard may press, by the name the daemon uses. A closed set:
/// the engine picks one of these names and the app maps it to a key code,
/// so nothing a model returns can spell a command. Anything an app binds
/// to a named menu command is reached through that menu item instead;
/// these are the keys with no menu item — confirming, moving between
/// fields and cells, closing a pop-up — and the shortcuts every Mac app
/// shares. Mirrors `leonardd.agent.KEYS`.
public enum KeyChord: String, CaseIterable, Sendable, Codable, Equatable {
    case returnKey = "return"
    case tab
    case shiftTab = "shift_tab"
    case escape
    case down, up, left, right
    case space
    case delete
    case cmdA = "cmd_a"
    case cmdC = "cmd_c"
    case cmdV = "cmd_v"
    case cmdX = "cmd_x"
    case cmdZ = "cmd_z"
    case cmdS = "cmd_s"
    case cmdN = "cmd_n"
    case cmdT = "cmd_t"
    case cmdF = "cmd_f"
    case cmdL = "cmd_l"
    case cmdW = "cmd_w"
    case cmdReturn = "cmd_return"

    /// The macOS virtual key code.
    public var keyCode: UInt16 {
        switch self {
        case .returnKey, .cmdReturn: 36
        case .tab, .shiftTab: 48
        case .escape: 53
        case .down: 125
        case .up: 126
        case .left: 123
        case .right: 124
        case .space: 49
        case .delete: 51
        case .cmdA: 0
        case .cmdC: 8
        case .cmdV: 9
        case .cmdX: 7
        case .cmdZ: 6
        case .cmdS: 1
        case .cmdN: 45
        case .cmdT: 17
        case .cmdF: 3
        case .cmdL: 37
        case .cmdW: 13
        }
    }

    public var command: Bool { rawValue.hasPrefix("cmd_") }
    public var shift: Bool { self == .shiftTab }

    /// How the key is written on a Mac keyboard and in the task panel.
    public var symbol: String {
        switch self {
        case .returnKey: "↩"
        case .tab: "⇥"
        case .shiftTab: "⇧⇥"
        case .escape: "esc"
        case .down: "↓"
        case .up: "↑"
        case .left: "←"
        case .right: "→"
        case .space: "␣"
        case .delete: "⌫"
        case .cmdReturn: "⌘↩"
        default: "⌘" + rawValue.dropFirst(4).uppercased()
        }
    }

    /// Browsers, where ⌘L means the address bar.
    public static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "org.mozilla.firefox",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.brave.Browser", "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi", "org.chromium.Chromium",
    ]

    /// The keys worth offering in an app: all of them, except the address
    /// bar outside a browser, where ⌘L means something else or nothing.
    public static func offered(bundleId: String?) -> [KeyChord] {
        let browser = bundleId.map { browsers.contains($0) } ?? false
        return allCases.filter { browser || $0 != .cmdL }
    }
}
