import Foundation

/// How much Leonard may do on its own while carrying out a task.
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
/// Deny: anything in a protected app (password managers, Keychain, System
/// Settings, anything the user added) and any secure field. Ask: steps whose
/// words mean sending, paying, deleting, publishing, signing or running a
/// command, and pressing Return in a message box — the moment a chat
/// message leaves. Everything else is allowed, because it can be undone or
/// only moves focus.
public struct ActionPolicy: Sendable {
    public enum Verdict: Sendable, Equatable {
        case allow
        case ask(reason: String)
        case deny(reason: String)
    }

    public enum Reason: String, Sendable {
        case sends, pays, deletes, publishes, signs, runsCommand, sendsMessage, closesWithoutSaving, everyStep
    }

    public var approval: ActingApproval
    public var allowRules: Set<ActionAllowRule>
    public var protectedApps: ScreenMemoryPolicy

    public init(approval: ActingApproval = .important, allowRules: [ActionAllowRule] = [], extraProtected: [String] = []) {
        self.approval = approval
        self.allowRules = Set(allowRules)
        self.protectedApps = ScreenMemoryPolicy(extraProtected: extraProtected)
    }

    /// Apps where pressing Return in a text box sends something to someone.
    public static let messagingApps: Set<String> = [
        "com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "desktop.WhatsApp",
        "com.microsoft.teams", "com.microsoft.teams2", "ru.keepcoder.Telegram", "org.telegram.desktop",
        "com.hnc.Discord", "org.whispersystems.signal-desktop", "com.facebook.archon", "com.apple.mail",
        "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.electron", "com.linkedin.LinkedIn",
    ]

    /// Where typed text can be run as a command.
    public static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "io.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
    ]

    static let rules: [(Reason, [String])] = [
        (.sends, ["send", "invia", "inoltra", "forward", "reply all", "rispondi a tutti", "submit", "conferma e invia", "spedisci"]),
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

    public func evaluate(operation: ActOperation, label: String, role: String, appBundleId: String?, appName: String,
                         secure: Bool = false, submit: Bool = false, multiline: Bool = false) -> Verdict {
        if protectedApps.isProtected(bundleId: appBundleId, appName: appName) {
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
        let app = appBundleId ?? appName
        if allowRules.contains(ActionAllowRule(app: app, operation: operation.rawValue, label: label)) {
            return .allow
        }
        if approval == .everyStep {
            return .ask(reason: Reason.everyStep.rawValue)
        }
        switch operation {
        case .click:
            if let reason = Self.consequence(of: label) { return .ask(reason: reason.rawValue) }
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

    /// The consequence a label's words announce, if any. Whole words only:
    /// "Sender" is not "send", "Reset zoom" still asks (it says reset).
    public static func consequence(of label: String) -> Reason? {
        let lowered = " " + label.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "…", with: " ")
            .map { $0.isLetter || $0 == "'" ? String($0) : " " }.joined() + " "
        for (reason, words) in rules {
            for word in words where lowered.contains(" \(word) ") {
                return reason
            }
        }
        return nil
    }
}
