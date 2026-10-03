import Foundation

/// Browser candidates come from macOS URL handlers, rather than a fixed app list.
public struct UserApplication: Equatable, Sendable {
    public var bundleId: String
    public var name: String
    public var aliases: [String]
    public init(bundleId: String, name: String, aliases: [String] = []) {
        self.bundleId = bundleId; self.name = name; self.aliases = aliases
    }
}

public enum UserApplicationSelection {
    /// Explicit app, current browser, default browser. Ambiguity stays unresolved.
    public static func browser(goal: String, active: String?, defaultBrowser: String?, candidates: [UserApplication]) -> UserApplication? {
        let request = " " + words(goal).joined(separator: " ") + " "
        let named = candidates.filter { app in
            ([app.name] + app.aliases).contains { alias in
                let phrase = words(alias).joined(separator: " ")
                return !phrase.isEmpty && request.contains(" " + phrase + " ")
            }
        }
        if named.count == 1 { return named[0] }
        if named.count > 1 { return nil }
        if let app = candidates.first(where: { $0.bundleId == active }) { return app }
        if let app = candidates.first(where: { $0.bundleId == defaultBrowser }) { return app }
        return candidates.count == 1 ? candidates[0] : nil
    }
    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}
