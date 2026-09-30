import Foundation

/// One opaque, scoreable possibility in an `observe` frame: a button, a
/// field, or one of the two ids every observation always carries, `done`
/// and `escalate`. The decision layer sees only this — an id and a human
/// label — never a coordinate, a path or a tool name.
public struct Candidate: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var role: String
    public var enabled: Bool

    public init(id: String, label: String, role: String, enabled: Bool) {
        self.id = id
        self.label = label
        self.role = role
        self.enabled = enabled
    }
}

/// App → daemon `observe`: what can be done right now, enumerated from the
/// accessibility tree by the (not-yet-built) driver workstream. Capped at
/// 20 candidates including `done` and `escalate`, which are always present.
public struct ObserveFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var id: String
    public var goal: String
    public var app: String
    public var window: String
    public var step: Int
    public var candidates: [Candidate]
    public var digest: String

    enum CodingKeys: String, CodingKey {
        case ts, id, goal, app, window, step, candidates, digest
    }

    public init(
        ts: Double = Date().timeIntervalSince1970, id: String, goal: String, app: String,
        window: String, step: Int, candidates: [Candidate], digest: String
    ) {
        self.ts = ts
        self.id = id
        self.goal = goal
        self.app = app
        self.window = window
        self.step = step
        self.candidates = candidates
        self.digest = digest
    }
}

/// The eight things an `act` frame can tell the app to do. `DONE` and
/// `BLOCKED` end the loop rather than touch anything.
public enum ActOperation: String, Codable, Sendable, Equatable {
    case click = "CLICK"
    /// Open an item as a double-click would: a file, a folder, a song.
    case open = "OPEN"
    /// Press one key from `KeyChord`, named by the act's `candidate_id`.
    case key = "KEY"
    /// Tasks type with `TYPE`; `TYPE_TEXT` is the v0.1 single-step form.
    case type = "TYPE"
    case typeText = "TYPE_TEXT"
    case openApp = "OPEN_APP"
    case select = "SELECT"
    case scrollUp = "SCROLL_UP"
    case scrollDown = "SCROLL_DOWN"
    case wait = "WAIT"
    case done = "DONE"
    case blocked = "BLOCKED"
}

/// Daemon → app `act`: two readouts off one forward pass — which
/// `operation`, and on which `candidate_id` — plus generated `text` when
/// (and only when) the operation is `TYPE_TEXT`.
///
/// This frame is scored by the daemon and carried by the app; **actuation
/// itself is out of scope here** (a separate `driver/` workstream owns
/// executing it against the live accessibility tree). What matters for this
/// type: the app re-resolves `candidate_id` against the *current* tree
/// before acting on it, never trusts a stale one, and never turns any field
/// here into a shell command, a path or a coordinate — the contract's
/// invariant is that nothing in this frame's output space can express one.
public struct ActFrame: Sendable, Equatable {
    public var ts: Double
    public var observationId: String
    public var operation: ActOperation
    public var candidateId: String
    public var confidence: Double
    public var schemaMass: Double
    public var operationProbabilities: [String: Double]
    public var probabilities: [String: Double]
    public var text: String?
    public var latencyMs: Double
    public var abstained: Bool
    public var why: String
    /// Set on steps of a task.
    public var taskId: String?
    public var targetLabel: String?
    /// Press Return after typing.
    public var submit: Bool

    public init(
        ts: Double, observationId: String, operation: ActOperation, candidateId: String,
        confidence: Double, schemaMass: Double, operationProbabilities: [String: Double] = [:],
        probabilities: [String: Double] = [:], text: String? = nil, latencyMs: Double,
        abstained: Bool = false, why: String = "", taskId: String? = nil, targetLabel: String? = nil, submit: Bool = false
    ) {
        self.ts = ts
        self.observationId = observationId
        self.operation = operation
        self.candidateId = candidateId
        self.confidence = confidence
        self.schemaMass = schemaMass
        self.operationProbabilities = operationProbabilities
        self.probabilities = probabilities
        self.text = text
        self.latencyMs = latencyMs
        self.abstained = abstained
        self.why = why
        self.taskId = taskId
        self.targetLabel = targetLabel
        self.submit = submit
    }
}

extension ActFrame: Codable {
    enum CodingKeys: String, CodingKey {
        case ts, operation, confidence, probabilities, text, abstained, why, submit
        case observationId = "observation_id"
        case taskId = "task_id"
        case targetLabel = "target_label"
        case candidateId = "candidate_id"
        case schemaMass = "schema_mass"
        case operationProbabilities = "operation_probabilities"
        case latencyMs = "latency_ms"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ts = try container.decode(Double.self, forKey: .ts)
        observationId = try container.decodeIfPresent(String.self, forKey: .observationId) ?? ""
        operation = try container.decode(ActOperation.self, forKey: .operation)
        candidateId = try container.decode(String.self, forKey: .candidateId)
        confidence = try container.decode(Double.self, forKey: .confidence)
        schemaMass = try container.decode(Double.self, forKey: .schemaMass)
        operationProbabilities = try container.decodeIfPresent([String: Double].self, forKey: .operationProbabilities) ?? [:]
        probabilities = try container.decodeIfPresent([String: Double].self, forKey: .probabilities) ?? [:]
        text = try container.decodeIfPresent(String.self, forKey: .text)
        latencyMs = try container.decode(Double.self, forKey: .latencyMs)
        abstained = try container.decodeIfPresent(Bool.self, forKey: .abstained) ?? false
        why = try container.decodeIfPresent(String.self, forKey: .why) ?? ""
        taskId = try container.decodeIfPresent(String.self, forKey: .taskId)
        targetLabel = try container.decodeIfPresent(String.self, forKey: .targetLabel)
        submit = try container.decodeIfPresent(Bool.self, forKey: .submit) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ts, forKey: .ts)
        try container.encode(observationId, forKey: .observationId)
        try container.encode(operation, forKey: .operation)
        try container.encode(candidateId, forKey: .candidateId)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(schemaMass, forKey: .schemaMass)
        try container.encode(operationProbabilities, forKey: .operationProbabilities)
        try container.encode(probabilities, forKey: .probabilities)
        try container.encode(text, forKey: .text)
        if abstained {
            try container.encode(abstained, forKey: .abstained)
        }
        try container.encode(why, forKey: .why)
        try container.encodeIfPresent(taskId, forKey: .taskId)
        try container.encodeIfPresent(targetLabel, forKey: .targetLabel)
        if submit {
            try container.encode(submit, forKey: .submit)
        }
    }
}
