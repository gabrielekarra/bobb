import Foundation

public enum BoundaryMode: String, Codable, CaseIterable, Sendable {
    case allow, ask, deny
}

public enum ActionCategory: String, Codable, CaseIterable, Sendable {
    case navigate, write, send, pay, delete, publish, settings, execute
}

public struct AppBoundary: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var actions: [String: BoundaryMode]
    public init(id: String, name: String, actions: [String: BoundaryMode] = [:]) {
        self.id = id; self.name = name; self.actions = actions
    }
    public func mode(_ category: ActionCategory) -> BoundaryMode {
        actions[category.rawValue] ?? ([.navigate, .write].contains(category) ? .allow : .ask)
    }
}

public struct BoundaryConfiguration: Codable, Equatable, Sendable {
    /// Per-app overrides. Installed Mac apps use the default modes automatically.
    public var apps: [AppBoundary] = []
    /// Opt out of reading and acting, by bundle identifier or app name.
    public var excludedApps: [String] = []
    public var rules: [String] = []
    /// Aliases used in rules, e.g. "capo": ["Marco Rossi", "marco@firm.it"].
    public var people: [String: [String]] = [:]
    public var hoursEnabled = false
    public var fromHour = 8
    public var toHour = 20
    public init() {}

    enum CodingKeys: String, CodingKey {
        case apps, excludedApps, rules, people, hoursEnabled, fromHour, toHour
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apps = try c.decodeIfPresent([AppBoundary].self, forKey: .apps) ?? []
        excludedApps = try c.decodeIfPresent([String].self, forKey: .excludedApps) ?? []
        rules = try c.decodeIfPresent([String].self, forKey: .rules) ?? []
        people = try c.decodeIfPresent([String: [String]].self, forKey: .people) ?? [:]
        hoursEnabled = try c.decodeIfPresent(Bool.self, forKey: .hoursEnabled) ?? false
        fromHour = try c.decodeIfPresent(Int.self, forKey: .fromHour) ?? 8
        toHour = try c.decodeIfPresent(Int.self, forKey: .toHour) ?? 20
    }

    public func canWork(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard hoursEnabled else { return true }
        let hour = calendar.component(.hour, from: date)
        if fromHour == toHour { return false }
        return fromHour < toHour ? (fromHour..<toHour).contains(hour) : hour >= fromHour || hour < toHour
    }

    public func isExcluded(bundleId: String?, name: String) -> Bool {
        excludedApps.contains(name) || (bundleId.map { excludedApps.contains($0) } ?? false)
    }

    public func app(bundleId: String?, name: String) -> AppBoundary? {
        guard !isExcluded(bundleId: bundleId, name: name) else { return nil }
        if let configured = apps.first(where: { $0.id == bundleId || $0.id == name || $0.name == name }) { return configured }
        // Optional external tools still need explicit configuration. Website
        // overrides fall back to Bobb Browser in the browser driver.
        if let bundleId, bundleId.hasPrefix("mcp:") || bundleId.hasPrefix("web:") { return nil }
        guard let id = bundleId ?? (name.isEmpty ? nil : name) else { return nil }
        return AppBoundary(id: id, name: name)
    }

    public func webApp(host: String, browserBundleId: String = "bobb.browser", browserName: String = "Bobb Browser") -> AppBoundary? {
        guard !isExcluded(bundleId: "web:\(host)", name: host),
              !isExcluded(bundleId: browserBundleId, name: browserName) else { return nil }
        return app(bundleId: "web:\(host)", name: host) ?? app(bundleId: browserBundleId, name: browserName)
    }

    public func evaluateWebsite(category: ActionCategory, url: String, browserBundleId: String?, browserName: String, context: String) -> ActionPolicy.Verdict {
        guard let value = URL(string: url), ["http", "https"].contains(value.scheme ?? ""),
              let host = value.host, value.user == nil, value.password == nil,
              let boundary = webApp(host: host, browserBundleId: browserBundleId ?? browserName, browserName: browserName) else {
            return .deny(reason: "unavailableWebsite")
        }
        return evaluate(category: category, bundleId: boundary.id, name: boundary.name, context: context)
    }

    /// Natural language is a constraint, never a way to grant silent powers.
    /// Unknown language asks for review instead of silently ignoring a rule.
    public func evaluate(category: ActionCategory, bundleId: String?, name: String, context: String,
                         at date: Date = Date()) -> ActionPolicy.Verdict {
        guard canWork(at: date) else { return .deny(reason: "outsideWorkingHours") }
        guard let app = app(bundleId: bundleId, name: name) else { return .deny(reason: "unavailableApp") }
        var mode = app.mode(category)
        let normalized = Self.normalize(context)
        for phrase in rules where !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let rule = Self.normalize(phrase)
            let categories = Self.categories(in: rule)
            guard !categories.isEmpty else { if mode != .deny { mode = .ask }; continue }
            guard categories.contains(category) else { continue }
            let mentions = people.filter { rule.contains(Self.normalize($0.key)) }
            if !mentions.isEmpty {
                // Without an actual recipient in the observation, ask. With
                // aliases present, apply only to that person.
                let aliases = mentions.flatMap { $0.value }.filter { !$0.isEmpty }
                if !aliases.isEmpty && !aliases.contains(where: { normalized.contains(Self.normalize($0)) }) {
                    // The screen may omit the recipient or show a nickname.
                    // Missing evidence cannot grant permission to send.
                    if mode != .deny { mode = .ask }
                    continue
                }
            }
            let asks = ["chied", "ask", "permesso", "approval", "confirm"].contains { rule.contains($0) }
            let denies = ["mai", "never", "viet", "non ", "don't", "do not"].contains { rule.contains($0) }
            if denies && !asks { mode = .deny }
            else if mode != .deny { mode = .ask }
        }
        switch mode {
        case .allow: return .allow
        case .ask: return .ask(reason: "boundary:\(category.rawValue)")
        case .deny: return .deny(reason: "boundary:\(category.rawValue)")
        }
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func categories(in text: String) -> Set<ActionCategory> {
        let words: [(ActionCategory, [String])] = [
            (.send, ["invia", "scriv", "send", "messagg", "mail", "message"]),
            (.pay, ["paga", "acquist", "pay", "buy", "purchase"]),
            (.delete, ["cancell", "elimin", "delete", "remove"]),
            (.publish, ["pubblic", "publish", "post", "condiv", "share"]),
            (.settings, ["impostaz", "settings", "configur"]),
            (.execute, ["comand", "command", "terminal", "esegui", "execute"]),
            (.navigate, ["apri", "open", "navig"]),
        ]
        return Set(words.compactMap { category, needles in needles.contains(where: text.contains) ? category : nil })
    }
}
