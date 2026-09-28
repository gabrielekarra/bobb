import Foundation

/// Daemon → app `ready`: handshake ack, carries the loaded model and
/// warm-up latency.
public struct ReadyFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var model: String
    public var primeMs: Double
    public var decideMs: Double
    public var floor: Double

    enum CodingKeys: String, CodingKey {
        case ts, model, floor
        case primeMs = "prime_ms"
        case decideMs = "decide_ms"
    }

    public init(ts: Double, model: String, primeMs: Double, decideMs: Double, floor: Double) {
        self.ts = ts
        self.model = model
        self.primeMs = primeMs
        self.decideMs = decideMs
        self.floor = floor
    }
}

/// One `stage` of `leonardd`'s reasoning pipeline, for the Mind panel.
public enum TraceStage: String, Codable, Sendable {
    case gate, context, intent, attention, prepare
}

/// Daemon → app `trace`: a step of reasoning. Fire-and-forget, no reply
/// expected. `stage` is decoded leniently (an unrecognized value still
/// round-trips as raw text) so a future stage the app has not shipped yet
/// never breaks the connection.
public struct TraceFrame: Sendable, Equatable {
    public var ts: Double
    public var eventId: String
    public var stage: TraceStage?
    public var rawStage: String
    public var detail: String
    public var ms: Double

    public init(ts: Double, eventId: String, stage: TraceStage?, rawStage: String, detail: String, ms: Double) {
        self.ts = ts
        self.eventId = eventId
        self.stage = stage
        self.rawStage = rawStage
        self.detail = detail
        self.ms = ms
    }
}

extension TraceFrame: Codable {
    enum CodingKeys: String, CodingKey {
        case ts, stage, detail, ms
        case eventId = "event_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ts = try container.decode(Double.self, forKey: .ts)
        eventId = try container.decodeIfPresent(String.self, forKey: .eventId) ?? ""
        rawStage = try container.decode(String.self, forKey: .stage)
        stage = TraceStage(rawValue: rawStage)
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        ms = try container.decode(Double.self, forKey: .ms)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ts, forKey: .ts)
        try container.encode(eventId, forKey: .eventId)
        try container.encode(rawStage, forKey: .stage)
        try container.encode(detail, forKey: .detail)
        try container.encode(ms, forKey: .ms)
    }
}

/// The `action` a `decision` resolves to. `App behaviour` per the contract:
/// only `.suggest` shows the overlay.
public enum DecisionAction: String, Codable, Sendable, Equatable {
    case ignore
    case wait
    case prepare
    case suggest
}

public struct Hypothesis: Codable, Sendable, Equatable {
    public var intent: String
    public var p: Double

    public init(intent: String, p: Double) {
        self.intent = intent
        self.p = p
    }
}

/// One answered question. `p` is the model's confidence in `value` alone and
/// is what the UI shows as the headline number; `probabilities` is its full
/// distribution over every option the question could have resolved to,
/// keyed by that option's label (e.g. `"false"/"true"` for a `Bool`,
/// `"0"..."4"` for a `Score`). A 0.51/0.49 split and a 0.95/0.05 split can
/// carry the same `p` for the winning option and are not the same reading —
/// `probabilities` is what tells them apart. Decoded leniently as `[:]`
/// when absent, since not every daemon build emits it yet.
public struct Readout: Sendable, Equatable {
    public var q: String
    public var value: JSONValue
    public var p: Double
    public var schemaMass: Double
    public var probabilities: [String: Double]
    /// The model's own softmax before any calibrator; identical to
    /// `probabilities` while no calibrator is wired in. Kept distinct
    /// because it is what a future calibrator is fit and audited against.
    public var rawProbabilities: [String: Double]

    public init(q: String, value: JSONValue, p: Double, schemaMass: Double, probabilities: [String: Double] = [:], rawProbabilities: [String: Double] = [:]) {
        self.q = q
        self.value = value
        self.p = p
        self.schemaMass = schemaMass
        self.probabilities = probabilities
        self.rawProbabilities = rawProbabilities
    }
}

extension Readout: Codable {
    enum CodingKeys: String, CodingKey {
        case q, value, p, probabilities
        case schemaMass = "schema_mass"
        case rawProbabilities = "raw_probabilities"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        q = try container.decode(String.self, forKey: .q)
        value = try container.decode(JSONValue.self, forKey: .value)
        p = try container.decode(Double.self, forKey: .p)
        schemaMass = try container.decode(Double.self, forKey: .schemaMass)
        probabilities = try container.decodeIfPresent([String: Double].self, forKey: .probabilities) ?? [:]
        rawProbabilities = try container.decodeIfPresent([String: Double].self, forKey: .rawProbabilities) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(q, forKey: .q)
        try container.encode(value, forKey: .value)
        try container.encode(p, forKey: .p)
        try container.encode(schemaMass, forKey: .schemaMass)
        if !probabilities.isEmpty {
            try container.encode(probabilities, forKey: .probabilities)
        }
        if !rawProbabilities.isEmpty {
            try container.encode(rawProbabilities, forKey: .rawProbabilities)
        }
    }
}

extension Readout {
    /// `probabilities`, ordered for a stacked-bar readout: numeric labels
    /// (a `Score`'s `"0"..."4"`) sort low to high; `"false"/"true"` sorts
    /// false-then-true; anything else (a `Choice`'s option names) sorts by
    /// probability, most likely first.
    public var orderedProbabilities: [(label: String, p: Double)] {
        let entries = Array(probabilities)
        let sorted: [(key: String, value: Double)]
        if entries.allSatisfy({ Int($0.key) != nil }) {
            sorted = entries.sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }
        } else if Set(entries.map(\.key)) == ["false", "true"] {
            sorted = entries.sorted { ($0.key == "true" ? 1 : 0) < ($1.key == "true" ? 1 : 0) }
        } else {
            sorted = entries.sorted { $0.value > $1.value }
        }
        return sorted.map { (label: $0.key, p: $0.value) }
    }
}

public struct Suggestion: Codable, Sendable, Equatable {
    public var title: String
    public var actionId: String
    public var detail: String

    enum CodingKeys: String, CodingKey {
        case title, detail
        case actionId = "action_id"
    }

    public init(title: String, actionId: String, detail: String) {
        self.title = title
        self.actionId = actionId
        self.detail = detail
    }
}

/// Daemon → app `decision`: the attention verdict for one event. Always
/// sent, even for `ignore` (contract invariant 1).
///
/// `abstained` is present on the wire only when true — the daemon omits it
/// entirely otherwise — so it is decoded with a `false` default and encoded
/// only when set, matching `leonardd`'s own encoding exactly rather than
/// merely being compatible with it.
public struct DecisionFrame: Sendable, Equatable {
    public var ts: Double
    public var id: String
    public var eventId: String
    public var action: DecisionAction
    public var confidence: Double
    public var schemaMass: Double
    public var latencyMs: Double
    public var hypotheses: [Hypothesis]
    public var readouts: [Readout]
    public var suggestion: Suggestion?
    public var why: String
    public var abstained: Bool

    public init(
        ts: Double, id: String, eventId: String, action: DecisionAction, confidence: Double,
        schemaMass: Double, latencyMs: Double, hypotheses: [Hypothesis] = [], readouts: [Readout] = [],
        suggestion: Suggestion? = nil, why: String = "", abstained: Bool = false
    ) {
        self.ts = ts
        self.id = id
        self.eventId = eventId
        self.action = action
        self.confidence = confidence
        self.schemaMass = schemaMass
        self.latencyMs = latencyMs
        self.hypotheses = hypotheses
        self.readouts = readouts
        self.suggestion = suggestion
        self.why = why
        self.abstained = abstained
    }
}

extension DecisionFrame: Codable {
    enum CodingKeys: String, CodingKey {
        case ts, id, action, confidence, hypotheses, readouts, suggestion, why, abstained
        case eventId = "event_id"
        case schemaMass = "schema_mass"
        case latencyMs = "latency_ms"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ts = try container.decode(Double.self, forKey: .ts)
        id = try container.decode(String.self, forKey: .id)
        eventId = try container.decodeIfPresent(String.self, forKey: .eventId) ?? ""
        action = try container.decode(DecisionAction.self, forKey: .action)
        confidence = try container.decode(Double.self, forKey: .confidence)
        schemaMass = try container.decode(Double.self, forKey: .schemaMass)
        latencyMs = try container.decode(Double.self, forKey: .latencyMs)
        hypotheses = try container.decodeIfPresent([Hypothesis].self, forKey: .hypotheses) ?? []
        readouts = try container.decodeIfPresent([Readout].self, forKey: .readouts) ?? []
        suggestion = try container.decodeIfPresent(Suggestion.self, forKey: .suggestion)
        why = try container.decodeIfPresent(String.self, forKey: .why) ?? ""
        abstained = try container.decodeIfPresent(Bool.self, forKey: .abstained) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ts, forKey: .ts)
        try container.encode(id, forKey: .id)
        try container.encode(eventId, forKey: .eventId)
        try container.encode(action, forKey: .action)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(schemaMass, forKey: .schemaMass)
        try container.encode(latencyMs, forKey: .latencyMs)
        try container.encode(hypotheses, forKey: .hypotheses)
        try container.encode(readouts, forKey: .readouts)
        try container.encodeIfPresent(suggestion, forKey: .suggestion)
        try container.encode(why, forKey: .why)
        if abstained {
            try container.encode(abstained, forKey: .abstained)
        }
    }
}

/// Daemon → app `prepared`: the result of background preparation after an
/// `approve`. `result` stays a free-form `JSONValue` — today it is always
/// `{"kind": "text", "body": ...}`, but the app should not need to change
/// when `leonardd` adds a new prepared-result kind.
public struct PreparedFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var decisionId: String
    public var actionId: String
    public var result: JSONValue
    public var latencyMs: Double

    enum CodingKeys: String, CodingKey {
        case ts, result
        case decisionId = "decision_id"
        case actionId = "action_id"
        case latencyMs = "latency_ms"
    }
}

/// Daemon → app `error`: something failed. Never fatal to the connection.
public struct ErrorFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var detail: String
}

/// Every frame `LeonardApp` may receive. `.unknown` is the contract's
/// "unknown frame types are ignored, never fatal" made concrete: decoding
/// never throws for an unrecognized `t`, it just produces this case.
public enum IncomingFrame: Sendable, Equatable {
    case ready(ReadyFrame)
    case trace(TraceFrame)
    case decision(DecisionFrame)
    case prepared(PreparedFrame)
    case error(ErrorFrame)
    /// The daemon's verdict for one `observe`. Not consumed by anything in
    /// this target yet — see `OutgoingFrame.observe`.
    case act(ActFrame)
    case unknown(type: String)

    public static func decode(from data: Data) throws -> IncomingFrame {
        let type = try FrameCodec.readType(from: data)
        switch type {
        case "ready": return .ready(try FrameCodec.payload(ReadyFrame.self, from: data))
        case "trace": return .trace(try FrameCodec.payload(TraceFrame.self, from: data))
        case "decision": return .decision(try FrameCodec.payload(DecisionFrame.self, from: data))
        case "prepared": return .prepared(try FrameCodec.payload(PreparedFrame.self, from: data))
        case "error": return .error(try FrameCodec.payload(ErrorFrame.self, from: data))
        case "act": return .act(try FrameCodec.payload(ActFrame.self, from: data))
        default: return .unknown(type: type)
        }
    }
}
