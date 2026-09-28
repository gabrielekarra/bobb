import Observation

/// Which Mind rows are expanded. A tiny `@Observable` model rather than
/// per-row `@State`: `SwiftUIMacros` (the plugin `@State` needs) does not
/// ship with Command Line Tools on this machine, only `ObservationMacros`
/// does (see `LeonardApp/README.md`), so local view state here is modeled
/// the same way `AppState` already is.
@MainActor
@Observable
final class MindUIState {
    private(set) var expandedIDs: Set<String>

    init(expandedIDs: Set<String> = []) {
        self.expandedIDs = expandedIDs
    }

    func isExpanded(_ id: String) -> Bool {
        expandedIDs.contains(id)
    }

    func toggle(_ id: String) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
        }
    }
}
