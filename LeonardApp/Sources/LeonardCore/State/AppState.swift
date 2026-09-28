import Observation

/// What the menu bar icon shows. The menu bar item is Leonard's only
/// always-visible surface, so this is not decorative: a glance at it must
/// answer "is it working, and is it doing anything right now."
public enum ActivityState: Sendable, Equatable {
    case disconnected
    case watching
    case thinking
    case suggesting
}

/// The single source of truth the whole UI reads from: connection health,
/// the watching toggle, the interruption floor, the Mind event log, and the
/// running tally that makes silence visible (events seen, decisions made,
/// times Leonard stayed silent, median decision latency).
@MainActor
@Observable
public final class AppState {
    public var connection: IPCClient.ConnectionState = .disconnected
    public var watching: Bool = true
    public var floor: Double = 0.60

    /// Set by the overlay controller for exactly as long as the overlay is
    /// on screen. `pendingOverlay` is a one-shot signal consumed the moment
    /// the overlay controller reads it, so it cannot answer "is a
    /// suggestion showing right now" — this can.
    public var overlayVisible: Bool = false

    /// The decision currently on screen in the overlay, mirrored here so
    /// the menu bar's popover can show the same suggestion and offer the
    /// same Prepara/Ignora — "the front door" should not require the user
    /// to have seen the transient overlay to act on it.
    public var activeSuggestion: DecisionFrame?

    public var activityState: ActivityState {
        guard connection.isReady else { return .disconnected }
        if overlayVisible { return .suggesting }
        if let mostRecent = entries.first, mostRecent.decision == nil { return .thinking }
        return .watching
    }

    public var entries: [MindEntry] = []
    public var maxEntries: Int = 300

    public private(set) var eventsSeen: Int = 0
    public private(set) var decisionsMade: Int = 0
    public private(set) var staySilentCount: Int = 0
    public private(set) var learningSignalCount: Int = 0
    private var latenciesMs: [Double] = []

    /// `mail.arrived`/`closed`/`archived`/`deleted` exist for the implicit
    /// labeller and will vastly outnumber the decisions worth a human's
    /// attention. On by default so Mind's list stays readable; the tallies
    /// above and the audit trail always count everything regardless.
    public var hideLearningSignalsInMind: Bool = true

    public var visibleEntries: [MindEntry] {
        hideLearningSignalsInMind ? entries.filter { !$0.event.kind.isLearningSignal } : entries
    }

    /// The most recent decision that should surface the overlay. The overlay
    /// controller observes this and clears it once handled; it is not a
    /// queue, matching the fact that only one overlay is ever shown at a
    /// time.
    public var pendingOverlay: DecisionFrame?

    public init() {}

    public var medianDecisionLatencyMs: Double {
        guard !latenciesMs.isEmpty else { return 0 }
        let sorted = latenciesMs.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    public func recordEvent(_ event: EventFrame) {
        eventsSeen += 1
        if event.kind.isLearningSignal {
            learningSignalCount += 1
        }
        entries.insert(MindEntry(event: event), at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
    }

    public func recordTrace(_ trace: TraceFrame) {
        guard let index = entries.firstIndex(where: { $0.id == trace.eventId }) else { return }
        entries[index].traces.append(trace)
    }

    public func recordDecision(_ decision: DecisionFrame) {
        decisionsMade += 1
        latenciesMs.append(decision.latencyMs)
        let shouldShow = OverlayPolicy.shouldShowOverlay(for: decision)
        if !shouldShow {
            staySilentCount += 1
        }
        if let index = entries.firstIndex(where: { $0.id == decision.eventId }) {
            entries[index].decision = decision
        }
        if shouldShow {
            pendingOverlay = decision
        }
    }

    public func reset() {
        entries.removeAll()
        eventsSeen = 0
        decisionsMade = 0
        staySilentCount = 0
        learningSignalCount = 0
        latenciesMs.removeAll()
        pendingOverlay = nil
    }
}
