import Foundation

/// App → daemon `hello`: the opening handshake, acked by `ready`.
public struct HelloFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var client: String
    public var version: String
    /// The UI language, so the daemon writes suggestion titles and
    /// explanations in it. Omitted by v0.1 clients.
    public var locale: String?

    public init(ts: Double = Date().timeIntervalSince1970, client: String = "LeonardApp", version: String = "1.0", locale: String? = nil) {
        self.ts = ts
        self.client = client
        self.version = version
        self.locale = locale
    }
}

/// App → daemon `approve` / `dismiss`: the user's verdict on a `suggest`
/// decision. Shared shape; `OutgoingFrame` supplies the distinct `t`.
public struct DecisionResponseFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var decisionId: String
    /// `user` for a click, `timeout` for an overlay nobody answered. The
    /// daemon learns from the first and barely from the second.
    public var reason: DismissReason?

    enum CodingKeys: String, CodingKey {
        case ts, reason
        case decisionId = "decision_id"
    }

    public init(ts: Double = Date().timeIntervalSince1970, decisionId: String, reason: DismissReason? = nil) {
        self.ts = ts
        self.decisionId = decisionId
        self.reason = reason
    }
}

public enum DismissReason: String, Codable, Sendable, Equatable {
    case user
    case timeout
}

/// App → daemon `policy`: changes the interruption floor at runtime.
public struct PolicyFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var floor: Double

    public init(ts: Double = Date().timeIntervalSince1970, floor: Double) {
        self.ts = ts
        self.floor = floor
    }
}

/// App → daemon `frame`: a screen capture offered to the frame gate. Not
/// emitted by either shipped `EventSource`; defined so the type is ready
/// for the screen-sensing seam and so the contract's wire shape round-trips
/// under test like every other frame.
public struct CaptureFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var id: String
    public var data: String

    public init(ts: Double = Date().timeIntervalSince1970, id: String, data: String) {
        self.ts = ts
        self.id = id
        self.data = data
    }
}

/// Every frame `LeonardApp` may send, tagged with its `t`.
public enum OutgoingFrame: Sendable, Equatable {
    case hello(HelloFrame)
    case event(EventFrame)
    case approve(DecisionResponseFrame)
    case dismiss(DecisionResponseFrame)
    case policy(PolicyFrame)
    case frame(CaptureFrame)
    /// Not emitted by anything in this target yet — the action loop's
    /// candidate enumeration is the `driver/` workstream's job. Modeled
    /// here so the wire shape exists and round-trips under test.
    case observe(ObserveFrame)
    case settings(DaemonSettingsFrame)
    case ask(AskFrame)
    case cancel(CancelFrame)
    case regenerate(RegenerateFrame)
    case memoryObserve(MemoryObserveFrame)
    case memorySearch(MemorySearchFrame)
    case memoryRecent(MemoryRecentFrame)
    case memoryDelete(MemoryDeleteFrame)
    case memoryStats(RequestFrame)
    case stats(RequestFrame)
    case historyDelete(RequestFrame)
    case reload(RequestFrame)
    case learningForget(LearningForgetFrame)
    case learningMute(LearningMuteFrame)
    case taskStart(TaskStartFrame)
    case taskObserve(TaskObserveFrame)
    case taskStep(TaskStepFrame)
    case taskEnd(TaskEndFrame)
    case tasksRecent(TasksRecentFrame)
    case commitmentsList(CommitmentsListFrame)
    case commitmentUpdate(CommitmentUpdateFrame)
    case procedureRecord(ProcedureRecordFrame)

    public func encoded() throws -> Data {
        switch self {
        case .hello(let frame): try FrameCodec.data(type: "hello", payload: frame)
        case .event(let frame): try FrameCodec.data(type: "event", payload: frame)
        case .approve(let frame): try FrameCodec.data(type: "approve", payload: frame)
        case .dismiss(let frame): try FrameCodec.data(type: "dismiss", payload: frame)
        case .policy(let frame): try FrameCodec.data(type: "policy", payload: frame)
        case .frame(let frame): try FrameCodec.data(type: "frame", payload: frame)
        case .observe(let frame): try FrameCodec.data(type: "observe", payload: frame)
        case .settings(let frame): try FrameCodec.data(type: "settings", payload: frame)
        case .ask(let frame): try FrameCodec.data(type: "ask", payload: frame)
        case .cancel(let frame): try FrameCodec.data(type: "cancel", payload: frame)
        case .regenerate(let frame): try FrameCodec.data(type: "regenerate", payload: frame)
        case .memoryObserve(let frame): try FrameCodec.data(type: "memory.observe", payload: frame)
        case .memorySearch(let frame): try FrameCodec.data(type: "memory.search", payload: frame)
        case .memoryRecent(let frame): try FrameCodec.data(type: "memory.recent", payload: frame)
        case .memoryDelete(let frame): try FrameCodec.data(type: "memory.delete", payload: frame)
        case .memoryStats(let frame): try FrameCodec.data(type: "memory.stats", payload: frame)
        case .stats(let frame): try FrameCodec.data(type: "stats", payload: frame)
        case .historyDelete(let frame): try FrameCodec.data(type: "history.delete", payload: frame)
        case .reload(let frame): try FrameCodec.data(type: "reload", payload: frame)
        case .learningForget(let frame): try FrameCodec.data(type: "learning.forget", payload: frame)
        case .learningMute(let frame): try FrameCodec.data(type: "learning.mute", payload: frame)
        case .taskStart(let frame): try FrameCodec.data(type: "task.start", payload: frame)
        case .taskObserve(let frame): try FrameCodec.data(type: "observe", payload: frame)
        case .taskStep(let frame): try FrameCodec.data(type: "task.step", payload: frame)
        case .taskEnd(let frame): try FrameCodec.data(type: "task.end", payload: frame)
        case .tasksRecent(let frame): try FrameCodec.data(type: "tasks.recent", payload: frame)
        case .commitmentsList(let frame): try FrameCodec.data(type: "commitments.list", payload: frame)
        case .commitmentUpdate(let frame): try FrameCodec.data(type: "commitment.update", payload: frame)
        case .procedureRecord(let frame): try FrameCodec.data(type: "procedure.record", payload: frame)
        }
    }
}
