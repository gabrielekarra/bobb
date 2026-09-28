import Foundation

/// A rectangle in screen points. Its own type so this module stays free of
/// CoreGraphics and builds and tests on Linux.
public struct ScreenRect: Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool { width < 1 || height < 1 }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public func intersects(_ other: ScreenRect) -> Bool {
        x < other.x + other.width && other.x < x + width && y < other.y + other.height && other.y < y + height
    }
}

/// What the accessibility tree says about one element, captured once per
/// observation. Plain values only: the live element reference stays in the
/// app, keyed by `key`, so this can be ranked, labelled and tested anywhere.
public struct UIElementSnapshot: Sendable, Equatable {
    /// The app's key for re-resolving the live element; opaque here.
    public var key: Int
    public var role: String
    public var subrole: String
    public var roleDescription: String
    public var title: String
    public var description: String
    public var value: String
    public var placeholder: String
    public var help: String
    public var identifier: String
    public var enabled: Bool
    public var focused: Bool
    public var selected: Bool
    public var frame: ScreenRect?
    public var actions: [String]
    public var valueSettable: Bool
    /// Labels of meaningful ancestors, outermost first: ["Sidebar", "Playlists"].
    public var context: [String]
    /// For menu items: the menu titles above it, outermost first: ["File", "New"].
    public var menuPath: [String]

    public init(key: Int, role: String, subrole: String = "", roleDescription: String = "", title: String = "",
                description: String = "", value: String = "", placeholder: String = "", help: String = "",
                identifier: String = "", enabled: Bool = true, focused: Bool = false, selected: Bool = false,
                frame: ScreenRect? = nil, actions: [String] = [], valueSettable: Bool = false, context: [String] = [],
                menuPath: [String] = []) {
        self.key = key
        self.role = role
        self.subrole = subrole
        self.roleDescription = roleDescription
        self.title = title
        self.description = description
        self.value = value
        self.placeholder = placeholder
        self.help = help
        self.identifier = identifier
        self.enabled = enabled
        self.focused = focused
        self.selected = selected
        self.frame = frame
        self.actions = actions
        self.valueSettable = valueSettable
        self.context = context
        self.menuPath = menuPath
    }

    public var isSecure: Bool { role == "AXSecureTextField" || subrole == "AXSecureTextField" }
    public var isMenuItem: Bool { role == "AXMenuItem" || role == "AXMenuBarItem" }
}

public enum ElementClassifier {
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    static let pressRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXLink",
        "AXDisclosureTriangle", "AXTab", "AXCell", "AXRow", "AXOutlineRow", "AXSegment", "AXDockItem",
        "AXIncrementor", "AXColorWell", "AXSwitch", "AXToggle",
    ]
    static let scrollRoles: Set<String> = ["AXScrollArea"]

    /// What an element can be used for, or nil when it is not something to
    /// act on. Secure fields are never offered, for anything.
    public static func kind(of element: UIElementSnapshot) -> CandidateKind? {
        if element.isSecure { return nil }
        if textRoles.contains(element.role) || element.subrole == "AXSearchField" {
            return .text
        }
        if element.role == "AXWebArea", element.valueSettable { return .text }
        if scrollRoles.contains(element.role) { return .scroll }
        if pressRoles.contains(element.role) { return .press }
        if element.actions.contains("AXPress") || element.actions.contains("AXPick") { return .press }
        return nil
    }

    /// The words a person would use for the element's type.
    public static func roleName(_ element: UIElementSnapshot) -> String {
        if element.subrole == "AXSearchField" { return "search field" }
        switch element.role {
        case "AXButton": return element.subrole == "AXCloseButton" ? "close button" : "button"
        case "AXMenuItem", "AXMenuBarItem": return "menu item"
        case "AXMenuButton", "AXPopUpButton": return "pop-up menu"
        case "AXCheckBox": return element.subrole == "AXSwitch" ? "switch" : "checkbox"
        case "AXRadioButton": return element.subrole == "AXTabButton" ? "tab" : "option"
        case "AXTab": return "tab"
        case "AXLink": return "link"
        case "AXTextField": return "text field"
        case "AXTextArea": return "text area"
        case "AXComboBox": return "combo box"
        case "AXScrollArea": return "scroll area"
        case "AXRow", "AXOutlineRow": return "row"
        case "AXCell": return "cell"
        case "AXDisclosureTriangle": return "disclosure"
        case "AXDockItem": return "Dock item"
        case "AXWebArea": return "editable page"
        default:
            let described = element.roleDescription.trimmingCharacters(in: .whitespaces)
            return described.isEmpty ? element.role.replacingOccurrences(of: "AX", with: "").lowercased() : described
        }
    }

    /// The element's name: its title, then its description, then (for
    /// fields) its placeholder, then its help, then what it shows.
    public static func label(of element: UIElementSnapshot) -> String {
        if element.isMenuItem, !element.title.isEmpty {
            return (element.menuPath + [element.title]).joined(separator: " › ")
        }
        let candidates: [String]
        if kind(of: element) == .text {
            candidates = [element.title, element.description, element.placeholder, element.help, element.identifier]
        } else {
            candidates = [element.title, element.description, element.help, shown(element), element.placeholder, element.identifier]
        }
        for text in candidates {
            let cleaned = clean(text)
            if !cleaned.isEmpty { return cleaned }
        }
        return ""
    }

    /// Where the element is, in a few words: the nearest labelled ancestor.
    public static func place(of element: UIElementSnapshot) -> String {
        if element.isMenuItem { return "menu bar" }
        return element.context.last.map { clean($0) } ?? ""
    }

    static func shown(_ element: UIElementSnapshot) -> String {
        // Rows, cells and links often carry their text as a value.
        switch element.role {
        case "AXRow", "AXOutlineRow", "AXCell", "AXLink", "AXStaticText", "AXRadioButton", "AXCheckBox", "AXButton":
            return element.value
        default:
            return ""
        }
    }

    static func clean(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.count > 80 ? String(collapsed.prefix(79)) + "…" : collapsed
    }
}

/// Lowercased, accent-free word tokens, without the words that carry no
/// meaning in a request ("the", "il", "please", "per favore").
public enum Tokens {
    static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "my", "me", "please", "at", "by", "it",
        "is", "this", "that", "from", "into", "up", "can", "you", "i", "be",
        "il", "lo", "la", "i", "gli", "le", "un", "uno", "una", "e", "o", "di", "da", "del", "della", "dei", "delle",
        "al", "alla", "ai", "alle", "nel", "nella", "per", "con", "su", "sul", "sulla", "mi", "mia", "mio", "miei",
        "mie", "che", "si", "favore", "puoi", "questo", "questa", "quello", "quella", "ti",
    ]

    public static func words(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var out: [String] = []
        var current = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out.filter { $0.count > 1 && !stopwords.contains($0) }
    }
}
