import Foundation

/// How much Bobb may do on its own while carrying out a task.
public enum ActingApproval: String, Codable, Sendable, Equatable, CaseIterable {
    /// Ask before anything that sends, pays, deletes or can't be taken back.
    case important
    /// Ask before every single step.
    case everyStep
}

/// "Always allow this in this app", remembered from a permission prompt.
public struct ActionAllowRule: Codable, Sendable, Equatable, Hashable {
    public var app: String
    public var operation: String
    public var label: String

    public init(app: String, operation: String, label: String) {
        self.app = app
        self.operation = operation
        self.label = label.lowercased()
    }
}

/// The permission engine: every step is `allow`, `ask` or `deny` before it
/// runs. It judges the action the app is about to perform on a real
/// element, never the model's intent, so it holds whatever the model says.
///
/// Deny: anything in a protected app (password managers, Keychain, anything
/// the user added), any secure field, and the panes of System Settings that
/// guard the Mac itself (privacy, security, users, passwords). Ask: every
/// step elsewhere in System Settings; steps whose words mean sending,
/// paying, deleting, publishing, signing or running a command; opening a
/// program or an installer; pressing Return where it sends a message, runs
/// a command or presses a consequential default button; closing a window.
/// Everything else is allowed, because it can be undone or only moves focus.
public struct ActionPolicy: Sendable {
    public enum Verdict: Sendable, Equatable {
        case allow
        case ask(reason: String)
        case deny(reason: String)
    }

    public enum Reason: String, Sendable {
        case sends, pays, deletes, publishes, signs, runsCommand, sendsMessage, closesWithoutSaving, everyStep
        case closes, settings
    }

    public var approval: ActingApproval
    public var allowRules: Set<ActionAllowRule>
    public var protectedApps: ScreenMemoryPolicy
    public var boundaries: BoundaryConfiguration?

    public init(approval: ActingApproval = .important, allowRules: [ActionAllowRule] = [], extraProtected: [String] = [],
                boundaries: BoundaryConfiguration? = nil) {
        self.approval = approval
        self.allowRules = Set(allowRules)
        self.protectedApps = ScreenMemoryPolicy(extraProtected: extraProtected)
        self.boundaries = boundaries
    }

    /// Apps where pressing Return in a text box sends something to someone.
    public static let messagingApps: Set<String> = [
        "com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "desktop.WhatsApp",
        "com.microsoft.teams", "com.microsoft.teams2", "ru.keepcoder.Telegram", "org.telegram.desktop",
        "com.hnc.Discord", "org.whispersystems.signal-desktop", "com.facebook.archon", "com.apple.mail",
        "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.electron", "com.linkedin.LinkedIn",
    ]

    /// Apps Bobb may use only one approved step at a time, never with an
    /// "always": System Settings changes the Mac for every app at once.
    public static let askEveryStepApps: Set<String> = ["com.apple.systempreferences"]

    /// System Settings panes that are never operated, by window title: the
    /// ones that guard the Mac, its accounts and what other apps may do.
    public static let deniedPanes: [String] = [
        "privacy", "privacy e sicurezza", "security", "sicurezza", "users & groups", "utenti e gruppi",
        "passwords", "password", "touch id", "login password", "login items", "elementi login", "filevault",
        "firewall", "profiles", "profili", "device management", "gestione dispositivi", "screen time",
        "tempo di utilizzo", "sharing", "condivisione", "internet accounts", "account internet", "wallet",
        "apple account", "apple id", "family", "in famiglia",
    ]

    /// File names that are programs or installers: opening one runs code.
    static let executableSuffixes = [
        ".app", ".pkg", ".mpkg", ".dmg", ".command", ".sh", ".tool", ".workflow", ".terminal", ".scpt",
        ".applescript", ".jar", ".py", ".rb", ".pl", ".bash", ".zsh",
    ]

    /// Where typed text can be run as a command.
    public static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "io.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
    ]

    static let rules: [(Reason, [String])] = [
        (.sends, ["send", "invia", "inoltra", "forward", "reply all", "rispondi a tutti", "submit", "conferma e invia", "spedisci",
                  "book", "reserve", "prenota", "confirm", "conferma"]),
        (.runsCommand, ["execute", "esegui", "run command", "esegui comando"]),
        (.pays, ["pay", "paga", "pagamento", "buy", "acquista", "compra", "purchase", "order", "ordina", "checkout",
                 "subscribe", "abbonati", "donate", "dona", "transfer", "bonifico", "trasferisci", "place order"]),
        (.deletes, ["delete", "elimina", "cancella", "remove", "rimuovi", "trash", "cestino", "erase", "svuota", "empty",
                    "overwrite", "sovrascrivi", "replace all", "sostituisci tutto", "discard", "scarta", "uninstall",
                    "disinstalla", "format", "inizializza", "reset", "ripristina"]),
        (.publishes, ["post", "pubblica", "publish", "share", "condividi", "tweet", "upload", "carica", "invite", "invita",
                      "accept", "accetta", "decline", "rifiuta", "approve", "approva", "merge"]),
        (.signs, ["sign", "firma", "sign out", "log out", "logout", "esci dall", "disconnetti", "revoke", "revoca",
                  "change password", "cambia password"]),
        (.closesWithoutSaving, ["don't save", "non salvare", "close without saving", "chiudi senza salvare", "quit", "esci"]),
    ]

    /// Protected from acting: the apps protected from memory, except the ones
    /// operated one approved step at a time (unless the user protected them).
    public func isProtected(bundleId: String?, appName: String) -> Bool {
        if let bundleId, Self.askEveryStepApps.contains(bundleId), !protectedApps.extraProtected.contains(bundleId),
           !protectedApps.extraProtected.contains(appName) {
            return false
        }
        return protectedApps.isProtected(bundleId: bundleId, appName: appName)
    }

    public static func isDeniedPane(_ window: String) -> Bool {
        let lowered = window.lowercased()
        return deniedPanes.contains { lowered.contains($0) }
    }

    public func evaluate(operation: ActOperation, label: String, role: String, appBundleId: String?, appName: String,
                         secure: Bool = false, submit: Bool = false, multiline: Bool = false, window: String = "",
                         key: KeyChord? = nil, defaultButton: String = "", context: String = "", typedText: String = "") -> Verdict {
        if isProtected(bundleId: appBundleId, appName: appName) {
            return .deny(reason: "protected")
        }
        if secure {
            return .deny(reason: "secure")
        }
        switch operation {
        case .done, .blocked, .wait:
            return .allow
        default:
            break
        }
        if let bundle = appBundleId, Self.askEveryStepApps.contains(bundle) {
            if window.isEmpty || Self.isDeniedPane(window) { return .deny(reason: "protected") }
            if let boundaries { return boundaries.evaluate(category: .settings, bundleId: bundle, name: appName, context: context) }
            return .ask(reason: Reason.settings.rawValue)
        }
        if let boundaries {
            // Explicit boundaries precede historical "always allow" rules.
            var review: Verdict = .allow
            for category in Self.categories(operation: operation, label: label, app: appBundleId, submit: submit,
                                             key: key, defaultButton: defaultButton) {
                let verdict = boundaries.evaluate(category: category, bundleId: appBundleId, name: appName,
                                                   context: context + " " + label + " " + typedText)
                if case .deny = verdict { return verdict }
                if case .ask = verdict { review = verdict }
            }
            if review != .allow { return review }
            if role == UIElementSnapshot.visualTextRole { return .ask(reason: "visualTarget") }
            if approval == .everyStep { return .ask(reason: Reason.everyStep.rawValue) }
            return .allow
        }
        let app = appBundleId ?? appName
        if role == UIElementSnapshot.visualTextRole { return .ask(reason: "visualTarget") }
        if allowRules.contains(ActionAllowRule(app: app, operation: operation.rawValue, label: label)) {
            return .allow
        }
        if approval == .everyStep {
            return .ask(reason: Reason.everyStep.rawValue)
        }
        let messaging = appBundleId.map { Self.messagingApps.contains($0) } ?? false
        let terminal = appBundleId.map { Self.terminals.contains($0) } ?? false
        switch operation {
        case .click, .select:
            if let reason = Self.consequence(of: label) { return .ask(reason: reason.rawValue) }
        case .open:
            if let reason = Self.consequence(of: label) { return .ask(reason: reason.rawValue) }
            let lowered = label.lowercased().trimmingCharacters(in: .whitespaces)
            if Self.executableSuffixes.contains(where: { lowered.hasSuffix($0) }) {
                return .ask(reason: Reason.runsCommand.rawValue)
            }
        case .key:
            switch key {
            case .returnKey?, .cmdReturn?:
                if terminal { return .ask(reason: Reason.runsCommand.rawValue) }
                if messaging { return .ask(reason: Reason.sendsMessage.rawValue) }
                // Return presses the window's default button.
                if let reason = Self.consequence(of: defaultButton) { return .ask(reason: reason.rawValue) }
            case .cmdW?:
                return .ask(reason: Reason.closes.rawValue)
            case nil:
                return .deny(reason: "unknown key")
            default:
                break
            }
        case .type, .typeText:
            if let bundle = appBundleId, Self.terminals.contains(bundle) {
                return .ask(reason: Reason.runsCommand.rawValue)
            }
            if submit, multiline || (appBundleId.map { Self.messagingApps.contains($0) } ?? false) {
                return .ask(reason: Reason.sendsMessage.rawValue)
            }
        default:
            break
        }
        return .allow
    }

    public static func category(operation: ActOperation, label: String, app: String?, submit: Bool,
                                key: KeyChord?, defaultButton: String) -> ActionCategory {
        if app?.hasPrefix("mcp:") == true, [.click, .select, .open].contains(operation) { return .execute }
        if let app, terminals.contains(app), [.type, .typeText, .key].contains(operation) { return .execute }
        if operation == .key, key == .returnKey || key == .cmdReturn, let app, messagingApps.contains(app) { return .send }
        if [.type, .typeText].contains(operation), submit { return .send }
        if let reason = consequence(of: operation == .key ? defaultButton : label) {
            switch reason {
            case .sends, .sendsMessage: return .send
            case .pays: return .pay
            case .deletes, .closesWithoutSaving: return .delete
            case .publishes: return .publish
            case .settings, .signs: return .settings
            case .runsCommand: return .execute
            default: break
            }
        }
        if operation == .open, executableSuffixes.contains(where: { label.lowercased().hasSuffix($0) }) { return .execute }
        if operation == .key, key == .cmdReturn { return .send }
        if operation == .key, key == .returnKey, app == "bobb.browser" || app?.hasPrefix("web:") == true { return .send }
        if operation == .key, key == .cmdW { return .delete }
        if [.type, .typeText].contains(operation) { return .write }
        return .navigate
    }

    /// One button can send a payment or publish and delete. Every matching
    /// boundary must permit it; a generic "Confirm" never masks "purchase".
    public static func categories(operation: ActOperation, label: String, app: String?, submit: Bool,
                                  key: KeyChord?, defaultButton: String) -> [ActionCategory] {
        var result = [category(operation: operation, label: label, app: app, submit: submit,
                               key: key, defaultButton: defaultButton)]
        if [.click, .select, .open, .key].contains(operation) || submit {
            let words = operation == .key ? defaultButton : label
            for (reason, _) in rules where consequenceWords(words, matching: reason) {
                let additional: ActionCategory
                switch reason {
                case .sends, .sendsMessage: additional = .send
                case .pays: additional = .pay
                case .deletes, .closesWithoutSaving: additional = .delete
                case .publishes: additional = .publish
                case .signs, .settings: additional = .settings
                case .runsCommand: additional = .execute
                default: continue
                }
                if !result.contains(additional) { result.append(additional) }
            }
        }
        return result
    }

    private static func consequenceWords(_ label: String, matching reason: Reason) -> Bool {
        let normalized = normalizedLabel(label)
        return rules.first(where: { $0.0 == reason })?.1.contains(where: { normalized.contains(" \($0) ") }) ?? false
    }

    private static func normalizedLabel(_ label: String) -> String {
        " " + label.lowercased().replacingOccurrences(of: "’", with: "'")
            .map { $0.isLetter || $0 == "'" ? String($0) : " " }.joined() + " "
    }

    /// The consequence a label's words announce, if any. Whole words only:
    /// "Sender" is not "send", "Reset zoom" still asks (it says reset).
    public static func consequence(of label: String) -> Reason? {
        let lowered = normalizedLabel(label)
        for (reason, words) in rules {
            for word in words where lowered.contains(" \(word) ") {
                return reason
            }
        }
        return nil
    }
}
