import Foundation
import Observation

/// What the menu bar icon shows. The menu bar item is Bobb's only
/// always-visible surface, so this is not decorative: a glance at it must
/// answer "is it working, and is it doing anything right now."
public enum ActivityState: Sendable, Equatable {
    case disconnected
    case starting
    case setupNeeded
    case paused
    case watching
    case thinking
    case suggesting
    /// Something is waiting in "For you" — prepared quietly, not interrupting.
    case waitingForYou
}

/// A draft being written after the user pressed "Prepare": streamed piece by
/// piece, then final, then possibly rewritten with an instruction.
public struct DraftSession: Sendable, Equatable {
    public var decision: DecisionFrame
    public var text: String = ""
    public var streaming: Bool = true
    public var result: PreparedFrame?
    public var error: String?
    public var instruction: String = ""

    public init(decision: DecisionFrame) {
        self.decision = decision
    }

    public var title: String { decision.suggestion?.title ?? "" }
    public var actionId: String { decision.suggestion?.actionId ?? "" }
    public var isReply: Bool { result?.resultKind == "reply" || actionId == "draft_reply" }
}

/// The command bar: what the user typed, over what selection, and the
/// answer as it arrives.
public struct AskSession: Sendable, Equatable {
    public var requestId: String?
    public var prompt: String = ""
    public var mode: AskMode = .ask
    public var selection: String = ""
    public var selectionApp: String = ""
    public var window: String = ""
    public var text: String = ""
    public var streaming: Bool = false
    public var sources: [SourceRef] = []
    public var unsupported: [String] = []
    public var error: String?
    public var resultKind: String?
    /// Set when the daemon decided the request is something to do, not to
    /// answer: the command bar hands this goal to a task.
    public var taskGoal: String?

    public init() {}

    public var hasAnswer: Bool { !text.isEmpty || error != nil }
}

/// The single source of truth the whole UI reads from: connection health,
/// the user's settings, the Mind event log, the quiet "For you" list, the
/// draft and command-bar sessions, and the running tally that makes
/// silence visible.
@MainActor
@Observable
public final class AppState {
    public var connection: IPCClient.ConnectionState = .disconnected
    public var daemonStatus: StatusFrame?
    public var settings = BobbSettings()
    public var entitlement: Entitlement = .trial(daysLeft: Entitlement.trialDays)
    public var modelInstalled: Bool = true

    public var watching: Bool {
        get { settings.watching }
        set { settings.watching = newValue }
    }

    public var floor: Double {
        get { settings.floor }
        set { settings.floor = newValue }
    }

    /// Set by the overlay controller for exactly as long as the overlay is
    /// on screen. `pendingOverlay` is a one-shot signal consumed the moment
    /// the overlay controller reads it, so it cannot answer "is a
    /// suggestion showing right now" — this can.
    public var overlayVisible: Bool = false

    /// The decision currently on screen in the overlay, mirrored here so
    /// the menu bar's popover can show the same suggestion.
    public var activeSuggestion: DecisionFrame?

    /// Suggestions and quietly prepared items the user has not answered,
    /// newest first. The overlay shows one `suggest` for a few seconds;
    /// this is where it and every `prepare` wait afterwards.
    public private(set) var forYou: [DecisionFrame] = []
    public var maxForYou: Int = 8

    public var draft: DraftSession?
    public var ask = AskSession()
    /// The task Bobb is carrying out, or the last one, until dismissed.
    public var task: TaskRunState?
    /// Past tasks, for Mind; loaded on demand.
    public var recentTasks: [TaskRecord] = []
    /// Open promises the user made, from the mail they sent.
    public var commitments: [Commitment] = []
    /// Ways of doing things Bobb learned, for Settings.
    public var procedures: [LearnedProcedure] = []

    /// The promises worth a line under "For you".
    public func promisesDue(now: Date = Date()) -> [Commitment] {
        commitments.filter { $0.isDueSoon(now: now) }
            .sorted { ($0.dueTs ?? .infinity, -$0.ts) < ($1.dueTs ?? .infinity, -$1.ts) }
    }
    public var stats: StatsFrame?

    public var activityState: ActivityState {
        if connection.isReady == false {
            if let status = daemonStatus, connection != .disconnected {
                return status.isModelMissing || status.isError ? .setupNeeded : .starting
            }
            return modelInstalled ? .disconnected : .setupNeeded
        }
        if !watching || !entitlement.allowsAssistance { return .paused }
        if overlayVisible { return .suggesting }
        if let mostRecent = entries.first, mostRecent.decision == nil, mostRecent.event.kind.isDecidable { return .thinking }
        if draft?.streaming == true || ask.streaming { return .thinking }
        if !forYou.isEmpty { return .waitingForYou }
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
        if !decision.readouts.isEmpty {
            latenciesMs.append(decision.latencyMs)
            if latenciesMs.count > 500 { latenciesMs.removeFirst(latenciesMs.count - 500) }
        }
        let shouldShow = OverlayPolicy.shouldShowOverlay(for: decision)
        if !shouldShow {
            staySilentCount += 1
        }
        if let index = entries.firstIndex(where: { $0.id == decision.eventId }) {
            entries[index].decision = decision
        }
        if OverlayPolicy.belongsInForYou(decision) {
            forYou.removeAll { $0.id == decision.id }
            forYou.insert(decision, at: 0)
            if forYou.count > maxForYou { forYou.removeLast(forYou.count - maxForYou) }
        }
        if shouldShow {
            pendingOverlay = decision
        }
    }

    /// The user answered this decision, from wherever it was shown.
    public func resolve(_ decisionId: String) {
        forYou.removeAll { $0.id == decisionId }
        if activeSuggestion?.id == decisionId { activeSuggestion = nil }
    }

    /// Items older than `maxAge` stop waiting: yesterday's "Marco is waiting"
    /// is noise today, and the audit trail still has it.
    public func expireForYou(now: Double = Date().timeIntervalSince1970, maxAge: Double = 12 * 3600) {
        forYou.removeAll { now - $0.ts > maxAge }
    }

    // MARK: Drafts

    public func beginDraft(for decision: DecisionFrame, instruction: String = "") {
        var session = DraftSession(decision: decision)
        session.instruction = instruction
        draft = session
    }

    public func applyPreparedDelta(_ delta: PreparedDeltaFrame) {
        guard var session = draft, session.decision.id == delta.decisionId else { return }
        session.text += delta.text
        session.streaming = true
        draft = session
    }

    public func applyPrepared(_ prepared: PreparedFrame) {
        guard var session = draft, session.decision.id == prepared.decisionId else { return }
        session.streaming = false
        session.result = prepared
        if prepared.isError {
            session.error = prepared.body
        } else {
            session.text = prepared.body
        }
        draft = session
    }

    // MARK: Command bar

    public func beginAsk(_ frame: AskFrame, mode: AskMode) {
        ask.requestId = frame.id
        ask.prompt = frame.prompt
        ask.mode = mode
        ask.text = ""
        ask.sources = []
        ask.unsupported = []
        ask.error = nil
        ask.resultKind = nil
        ask.streaming = true
    }

    public func applyAnswerDelta(_ delta: AnswerDeltaFrame) {
        guard ask.requestId == delta.requestId else { return }
        ask.text += delta.text
    }

    public func applyAnswer(_ answer: AnswerFrame) {
        guard ask.requestId == answer.requestId else { return }
        ask.streaming = false
        ask.resultKind = answer.resultKind
        if answer.resultKind == "task" {
            ask.taskGoal = answer.text
            return
        }
        ask.sources = answer.sources
        ask.unsupported = answer.unsupported
        if answer.ok {
            ask.text = answer.text
        } else {
            ask.error = answer.error ?? "error"
        }
    }

    public func applyError(_ error: ErrorFrame) {
        guard let requestId = error.requestId, requestId == ask.requestId else { return }
        ask.streaming = false
        ask.error = error.detail
    }

    public func reset() {
        entries.removeAll()
        eventsSeen = 0
        decisionsMade = 0
        staySilentCount = 0
        learningSignalCount = 0
        latenciesMs.removeAll()
        pendingOverlay = nil
        forYou.removeAll()
    }
}

extension EventKind {
    /// Kinds the daemon may run the model on. Everything else is answered
    /// with an instant `ignore`, so it never shows as "thinking".
    public var isDecidable: Bool {
        switch self {
        case .mailOpened, .mailComposing, .textSelected, .appActivated, .windowChanged: true
        default: false
        }
    }
}
