import Observation
import LeonardCore

/// Holds `AuditView`'s query state. An `@Observable` view-model rather than
/// `@State` properties on the view — see `MindUIState`'s doc comment for
/// why (`SwiftUIMacros` is not available in this build environment).
@MainActor
@Observable
final class AuditViewModel {
    let auditPath: String
    private(set) var store: AuditStore?
    var records: [AuditRecord] = []
    var searchText: String = ""
    var selectedID: String?
    private(set) var errorMessage: String?

    init(auditPath: String) {
        self.auditPath = auditPath
    }

    var selectedRecord: AuditRecord? {
        records.first { $0.id == selectedID }
    }

    func openAndPoll() async {
        do {
            store = try AuditStore(path: auditPath)
            errorMessage = nil
        } catch {
            errorMessage = "Audit store non disponibile: \(error)"
            return
        }
        load()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { break }
            load()
        }
    }

    func load() {
        guard let store else { return }
        do {
            records = try store.search(searchText, limit: 500)
            errorMessage = nil
        } catch {
            errorMessage = "Query fallita: \(error)"
        }
    }
}
