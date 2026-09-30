import Foundation

/// One shared desktop, including foreground requests and background jobs.
@MainActor
final class ScreenLease {
    static let shared = ScreenLease()
    private(set) var owner: String?
    func acquire(_ id: String) -> Bool {
        guard owner == nil || owner == id else { return false }
        owner = id; return true
    }
    func release(_ id: String) { if owner == id { owner = nil } }
}
