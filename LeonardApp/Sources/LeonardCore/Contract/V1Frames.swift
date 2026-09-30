import Foundation

// MARK: - Daemon → app

/// `status`: the daemon is up but not ready — loading the model, missing
/// it, or failed to load it. `ready` follows the moment it is.
public struct StatusFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var state: String
    public var detail: String
    public var model: String
    public var protocolVersion: Int?
    public var version: String?

    enum CodingKeys: String, CodingKey {
        case ts, state, detail, model, version
        case protocolVersion = "protocol"
    }

    public init(ts: Double, state: String, detail: String = "", model: String = "", protocolVersion: Int? = nil, version: String? = nil) {
        self.ts = ts
        self.state = state
        self.detail = detail
        self.model = model
        self.protocolVersion = protocolVersion
        self.version = version
    }

    public var isModelMissing: Bool { state == "model_missing" }
    public var isLoading: Bool { state == "loading" }
    public var isError: Bool { state == "error" }
}

/// A piece of memory an answer or draft drew on, numbered as the model saw
/// it, so `[2]` in the text points at `n == 2`.
public struct SourceRef: Codable, Sendable, Equatable, Identifiable {
    public var n: Int
    public var id: Int
    public var app: String
    public var window: String
    public var ts: Double
    public var lastSeen: Double
    public var url: String?

    enum CodingKeys: String, CodingKey {
        case n, id, app, window, ts, url
        case lastSeen = "last_seen"
    }

    public init(n: Int, id: Int, app: String, window: String, ts: Double, lastSeen: Double, url: String? = nil) {
        self.n = n
        self.id = id
        self.app = app
        self.window = window
        self.ts = ts
        self.lastSeen = lastSeen
        self.url = url
    }

    init?(json: JSONValue) {
        guard
            let n = json["n"]?.numberValue, let id = json["id"]?.numberValue,
            let app = json["app"]?.stringValue
        else { return nil }
        self.init(
            n: Int(n), id: Int(id), app: app, window: json["window"]?.stringValue ?? "",
            ts: json["ts"]?.numberValue ?? 0, lastSeen: json["last_seen"]?.numberValue ?? 0,
            url: json["url"]?.stringValue
        )
    }
}

/// `prepared.delta`: the next piece of a draft being written after "Prepare".
public struct PreparedDeltaFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var decisionId: String
    public var text: String

    enum CodingKeys: String, CodingKey {
        case ts, text
        case decisionId = "decision_id"
    }

    public init(ts: Double, decisionId: String, text: String) {
        self.ts = ts
        self.decisionId = decisionId
        self.text = text
    }
}

/// `answer.delta`: the next piece of a command-bar answer.
public struct AnswerDeltaFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var requestId: String
    public var text: String

    enum CodingKeys: String, CodingKey {
        case ts, text
        case requestId = "request_id"
    }

    public init(ts: Double, requestId: String, text: String) {
        self.ts = ts
        self.requestId = requestId
        self.text = text
    }
}

/// `answer`: the finished command-bar answer, with what it cited.
public struct AnswerFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var requestId: String
    public var ok: Bool
    public var text: String
    public var error: String?
    public var mode: String?
    public var resultKind: String?
    public var sources: [SourceRef]
    public var unsupported: [String]
    public var latencyMs: Double?
    public var firstTokenMs: Double?
    public var cancelled: Bool?

    enum CodingKeys: String, CodingKey {
        case ts, ok, text, error, mode, sources, cancelled, unsupported
        case requestId = "request_id"
        case resultKind = "result_kind"
        case latencyMs = "latency_ms"
        case firstTokenMs = "first_token_ms"
    }

    public init(
        ts: Double, requestId: String, ok: Bool, text: String, error: String? = nil, mode: String? = nil,
        resultKind: String? = nil, sources: [SourceRef] = [], unsupported: [String] = [], latencyMs: Double? = nil,
        firstTokenMs: Double? = nil, cancelled: Bool? = nil
    ) {
        self.ts = ts
        self.requestId = requestId
        self.ok = ok
        self.text = text
        self.error = error
        self.mode = mode
        self.resultKind = resultKind
        self.sources = sources
        self.unsupported = unsupported
        self.latencyMs = latencyMs
        self.firstTokenMs = firstTokenMs
        self.cancelled = cancelled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ts = try c.decodeIfPresent(Double.self, forKey: .ts) ?? 0
        requestId = try c.decode(String.self, forKey: .requestId)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        error = try c.decodeIfPresent(String.self, forKey: .error)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        resultKind = try c.decodeIfPresent(String.self, forKey: .resultKind)
        sources = try c.decodeIfPresent([SourceRef].self, forKey: .sources) ?? []
        unsupported = try c.decodeIfPresent([String].self, forKey: .unsupported) ?? []
        latencyMs = try c.decodeIfPresent(Double.self, forKey: .latencyMs)
        firstTokenMs = try c.decodeIfPresent(Double.self, forKey: .firstTokenMs)
        cancelled = try c.decodeIfPresent(Bool.self, forKey: .cancelled)
    }
}

/// One remembered screen, as a search result.
public struct MemoryHit: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var ts: Double
    public var lastSeen: Double
    public var app: String
    public var window: String
    public var url: String?
    public var source: String
    public var snippet: String

    enum CodingKeys: String, CodingKey {
        case id, ts, app, window, url, source, snippet
        case lastSeen = "last_seen"
    }

    public init(id: Int, ts: Double, lastSeen: Double, app: String, window: String, url: String? = nil, source: String = "screen", snippet: String) {
        self.id = id
        self.ts = ts
        self.lastSeen = lastSeen
        self.app = app
        self.window = window
        self.url = url
        self.source = source
        self.snippet = snippet
    }
}

public struct MemoryResultsFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var requestId: String?
    public var terms: [String]
    public var results: [MemoryHit]

    enum CodingKeys: String, CodingKey {
        case ts, terms, results
        case requestId = "request_id"
    }

    public init(ts: Double, requestId: String?, terms: [String] = [], results: [MemoryHit]) {
        self.ts = ts
        self.requestId = requestId
        self.terms = terms
        self.results = results
    }
}

/// `memory.deleted` and `history.deleted`: how many rows are gone.
public struct CountFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var requestId: String?
    public var count: Int

    enum CodingKeys: String, CodingKey {
        case ts, count
        case requestId = "request_id"
    }

    public init(ts: Double, requestId: String?, count: Int) {
        self.ts = ts
        self.requestId = requestId
        self.count = count
    }
}

public struct AppMemoryCount: Codable, Sendable, Equatable, Identifiable {
    public var app: String
    public var rows: Int
    public var lastSeen: Double?

    public var id: String { app }

    enum CodingKeys: String, CodingKey {
        case app, rows
        case lastSeen = "last_seen"
    }

    public init(app: String, rows: Int, lastSeen: Double? = nil) {
        self.app = app
        self.rows = rows
        self.lastSeen = lastSeen
    }
}

public struct MemoryStatsFrame: Codable, Sendable, Equatable {
    public var ts: Double?
    public var requestId: String?
    public var rows: Int
    public var chars: Int?
    public var bytes: Int?
    public var oldestTs: Double?
    public var newestTs: Double?
    public var apps: [AppMemoryCount]

    enum CodingKeys: String, CodingKey {
        case ts, rows, chars, bytes, apps
        case requestId = "request_id"
        case oldestTs = "oldest_ts"
        case newestTs = "newest_ts"
    }

    public init(ts: Double? = nil, requestId: String? = nil, rows: Int, chars: Int? = nil, bytes: Int? = nil, oldestTs: Double? = nil, newestTs: Double? = nil, apps: [AppMemoryCount] = []) {
        self.ts = ts
        self.requestId = requestId
        self.rows = rows
        self.chars = chars
        self.bytes = bytes
        self.oldestTs = oldestTs
        self.newestTs = newestTs
        self.apps = apps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ts = try c.decodeIfPresent(Double.self, forKey: .ts)
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
        rows = try c.decodeIfPresent(Int.self, forKey: .rows) ?? 0
        chars = try c.decodeIfPresent(Int.self, forKey: .chars)
        bytes = try c.decodeIfPresent(Int.self, forKey: .bytes)
        oldestTs = try c.decodeIfPresent(Double.self, forKey: .oldestTs)
        newestTs = try c.decodeIfPresent(Double.self, forKey: .newestTs)
        apps = try c.decodeIfPresent([AppMemoryCount].self, forKey: .apps) ?? []
    }
}

/// What Leonard did over a period, for Mind's header.
public struct DecisionSummary: Codable, Sendable, Equatable {
    public var decisions: Int
    public var suggested: Int
    public var prepared: Int
    public var abstained: Int
    public var approved: Int
    public var dismissed: Int
    public var expired: Int
    public var silent: Int
    public var meanDecisionMs: Double?

    enum CodingKeys: String, CodingKey {
        case decisions, suggested, prepared, abstained, approved, dismissed, expired, silent
        case meanDecisionMs = "mean_decision_ms"
    }

    public init(decisions: Int = 0, suggested: Int = 0, prepared: Int = 0, abstained: Int = 0, approved: Int = 0, dismissed: Int = 0, expired: Int = 0, silent: Int = 0, meanDecisionMs: Double? = nil) {
        self.decisions = decisions
        self.suggested = suggested
        self.prepared = prepared
        self.abstained = abstained
        self.approved = approved
        self.dismissed = dismissed
        self.expired = expired
        self.silent = silent
        self.meanDecisionMs = meanDecisionMs
    }

    /// The share of suggestions the user took, among those they answered.
    public var acceptance: Double? {
        let answered = approved + dismissed
        return answered > 0 ? Double(approved) / Double(answered) : nil
    }
}

public struct LearnedKind: Codable, Sendable, Equatable, Identifiable {
    public var kind: String
    public var approved: Int
    public var dismissed: Int
    public var expired: Int
    public var approvalRate: Double
    public var floor: Double
    public var learning: Bool

    public var id: String { kind }

    enum CodingKeys: String, CodingKey {
        case kind, approved, dismissed, expired, floor, learning
        case approvalRate = "approval_rate"
    }

    public init(kind: String, approved: Int, dismissed: Int, expired: Int, approvalRate: Double, floor: Double, learning: Bool) {
        self.kind = kind
        self.approved = approved
        self.dismissed = dismissed
        self.expired = expired
        self.approvalRate = approvalRate
        self.floor = floor
        self.learning = learning
    }
}

public struct MutedSender: Codable, Sendable, Equatable, Identifiable {
    public var ruleId: String
    public var sender: String
    public var dismissed: Int
    public var since: Double
    public var manual: Bool

    public var id: String { ruleId }

    enum CodingKeys: String, CodingKey {
        case sender, dismissed, since, manual
        case ruleId = "rule_id"
    }

    public init(ruleId: String, sender: String, dismissed: Int, since: Double, manual: Bool) {
        self.ruleId = ruleId
        self.sender = sender
        self.dismissed = dismissed
        self.since = since
        self.manual = manual
    }
}

public struct LearningSnapshot: Codable, Sendable, Equatable {
    public var baseFloor: Double
    public var kinds: [LearnedKind]
    public var mutedSenders: [MutedSender]

    enum CodingKeys: String, CodingKey {
        case kinds
        case baseFloor = "base_floor"
        case mutedSenders = "muted_senders"
    }

    public init(baseFloor: Double = 0.6, kinds: [LearnedKind] = [], mutedSenders: [MutedSender] = []) {
        self.baseFloor = baseFloor
        self.kinds = kinds
        self.mutedSenders = mutedSenders
    }
}

public struct StatsFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var requestId: String?
    public var decisions: DecisionSummary
    public var learning: LearningSnapshot
    public var memory: MemoryStatsFrame?
    public var tasks: TaskSummary?
    public var specialist: SpecialistSnapshot?
    public var state: String?
    public var model: String?

    enum CodingKeys: String, CodingKey {
        case ts, decisions, learning, memory, tasks, specialist, state, model
        case requestId = "request_id"
    }

    public init(ts: Double, requestId: String? = nil, decisions: DecisionSummary, learning: LearningSnapshot, memory: MemoryStatsFrame? = nil,
                tasks: TaskSummary? = nil, specialist: SpecialistSnapshot? = nil, state: String? = nil, model: String? = nil) {
        self.ts = ts
        self.requestId = requestId
        self.decisions = decisions
        self.learning = learning
        self.memory = memory
        self.tasks = tasks
        self.specialist = specialist
        self.state = state
        self.model = model
    }
}

// MARK: - App → daemon

/// `settings`: the user's choices, sent after every `hello`. The daemon
/// validates each field on its own and persists what it enforces.
public struct DaemonSettingsFrame: Sendable, Equatable {
    public var timezone: String?
    public var floor: Double
    public var locale: String
    public var proactiveKinds: [String]
    public var quietHours: [Int]?
    public var adaptive: Bool
    public var memoryEnabled: Bool
    public var memoryRetentionDays: Int
    public var historyRetentionDays: Int
    public var extraProtectedApps: [String]

    public init(
        floor: Double, locale: String, proactiveKinds: [String], quietHours: [Int]?, adaptive: Bool,
        memoryEnabled: Bool, memoryRetentionDays: Int, historyRetentionDays: Int, extraProtectedApps: [String], timezone: String? = nil
    ) {
        self.floor = floor
        self.locale = locale
        self.proactiveKinds = proactiveKinds
        self.quietHours = quietHours
        self.adaptive = adaptive
        self.memoryEnabled = memoryEnabled
        self.memoryRetentionDays = memoryRetentionDays
        self.historyRetentionDays = historyRetentionDays
        self.extraProtectedApps = extraProtectedApps
        self.timezone = timezone
    }
}

extension DaemonSettingsFrame: Codable {
    enum CodingKeys: String, CodingKey {
        case floor, locale, adaptive, timezone
        case proactiveKinds = "proactive_kinds"
        case quietHours = "quiet_hours"
        case memoryEnabled = "memory_enabled"
        case memoryRetentionDays = "memory_retention_days"
        case historyRetentionDays = "history_retention_days"
        case extraProtectedApps = "extra_protected_apps"
    }

    /// `quiet_hours` is written as an explicit `null` when off: absent means
    /// "leave it as it is", `null` means "turn it off".
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(floor, forKey: .floor)
        try c.encode(locale, forKey: .locale)
        try c.encode(proactiveKinds, forKey: .proactiveKinds)
        if let quietHours {
            try c.encode(quietHours, forKey: .quietHours)
        } else {
            try c.encodeNil(forKey: .quietHours)
        }
        try c.encode(adaptive, forKey: .adaptive)
        try c.encode(memoryEnabled, forKey: .memoryEnabled)
        try c.encode(memoryRetentionDays, forKey: .memoryRetentionDays)
        try c.encode(historyRetentionDays, forKey: .historyRetentionDays)
        try c.encode(extraProtectedApps, forKey: .extraProtectedApps)
        try c.encodeIfPresent(timezone, forKey: .timezone)
    }
}

/// `ask`: something typed into the command bar, with the selection it was
/// typed over when there was one.
public struct AskFrame: Codable, Sendable, Equatable {
    public var id: String
    public var prompt: String
    public var mode: String
    public var selection: String
    public var app: String
    public var window: String
    /// Let the daemon decide whether this is to answer or to do; a confident
    /// "do" comes back as an `answer` with `result_kind: "task"`.
    public var route: Bool

    public init(id: String = AskFrame.newID(), prompt: String, mode: AskMode = .ask, selection: String = "", app: String = "",
                window: String = "", route: Bool = false) {
        self.id = id
        self.prompt = prompt
        self.mode = mode == .act ? AskMode.ask.rawValue : mode.rawValue
        self.selection = selection
        self.app = app
        self.window = window
        self.route = route
    }

    public static func newID() -> String {
        "ask_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
    }
}

public enum AskMode: String, Codable, Sendable, CaseIterable {
    case ask, write, reply, rewrite, translate, summarize, explain, compute
    /// Do it: operate the Mac's applications to carry out the request.
    case act = "do"

    /// Modes that operate on a selection, and so offer to replace it.
    public var needsSelection: Bool {
        switch self {
        case .reply, .rewrite, .translate, .summarize, .explain, .compute: true
        case .ask, .write, .act: false
        }
    }
}

public struct CancelFrame: Codable, Sendable, Equatable {
    public var requestId: String

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
    }

    public init(requestId: String) {
        self.requestId = requestId
    }
}

public struct RegenerateFrame: Codable, Sendable, Equatable {
    public var decisionId: String
    public var instruction: String

    enum CodingKeys: String, CodingKey {
        case instruction
        case decisionId = "decision_id"
    }

    public init(decisionId: String, instruction: String = "") {
        self.decisionId = decisionId
        self.instruction = instruction
    }
}

/// `memory.observe`: text read from the accessibility tree of the window in
/// front of the user. Never sent for a protected app.
public struct MemoryObserveFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var app: String
    public var bundleId: String?
    public var window: String
    public var text: String
    public var url: String?
    public var source: String

    enum CodingKeys: String, CodingKey {
        case ts, app, window, text, url, source
        case bundleId = "bundle_id"
    }

    public init(ts: Double = Date().timeIntervalSince1970, app: String, bundleId: String?, window: String, text: String, url: String? = nil, source: String = "screen") {
        self.ts = ts
        self.app = app
        self.bundleId = bundleId
        self.window = window
        self.text = text
        self.url = url
        self.source = source
    }
}

public struct MemorySearchFrame: Codable, Sendable, Equatable {
    public var id: String
    public var query: String
    public var limit: Int
    public var app: String?

    public init(id: String, query: String, limit: Int = 30, app: String? = nil) {
        self.id = id
        self.query = query
        self.limit = limit
        self.app = app
    }
}

public struct MemoryRecentFrame: Codable, Sendable, Equatable {
    public var id: String
    public var limit: Int
    public var app: String?

    public init(id: String, limit: Int = 60, app: String? = nil) {
        self.id = id
        self.limit = limit
        self.app = app
    }
}

public struct MemoryDeleteFrame: Codable, Sendable, Equatable {
    public enum Scope: String, Codable, Sendable {
        case row, app, range, query, all
    }

    public var id: String
    public var scope: Scope
    public var rowId: Int?
    public var app: String?
    public var since: Double?
    public var until: Double?
    public var query: String?

    enum CodingKeys: String, CodingKey {
        case id, scope, app, since, until, query
        case rowId = "row_id"
    }

    public init(id: String, scope: Scope, rowId: Int? = nil, app: String? = nil, since: Double? = nil, until: Double? = nil, query: String? = nil) {
        self.id = id
        self.scope = scope
        self.rowId = rowId
        self.app = app
        self.since = since
        self.until = until
        self.query = query
    }
}

/// Any request that carries nothing but its id: `memory.stats`, `stats`,
/// `history.delete`, `reload`.
public struct RequestFrame: Codable, Sendable, Equatable {
    public var id: String

    public init(id: String = RequestFrame.newID()) {
        self.id = id
    }

    public static func newID() -> String {
        "req_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
    }
}

public struct LearningForgetFrame: Codable, Sendable, Equatable {
    public var id: String
    public var ruleId: String

    enum CodingKeys: String, CodingKey {
        case id
        case ruleId = "rule_id"
    }

    public init(id: String = RequestFrame.newID(), ruleId: String) {
        self.id = id
        self.ruleId = ruleId
    }
}

public struct LearningMuteFrame: Codable, Sendable, Equatable {
    public var id: String
    public var sender: String

    public init(id: String = RequestFrame.newID(), sender: String) {
        self.id = id
        self.sender = sender
    }
}

extension IncomingFrame {
    /// The request this frame answers, when it answers one.
    public var requestId: String? {
        switch self {
        case .answer(let f): f.requestId
        case .memoryResults(let f): f.requestId
        case .memoryDeleted(let f): f.requestId
        case .memoryStats(let f): f.requestId
        case .historyDeleted(let f): f.requestId
        case .stats(let f): f.requestId
        case .error(let f): f.requestId
        case .act(let f): f.observationId
        case .taskPlan(let f): f.requestId
        case .tasksResults(let f): f.requestId
        case .commitments(let f): f.requestId
        case .procedures(let f): f.requestId
        case .workspace(let f): f.requestId
        default: nil
        }
    }
}

/// The personal specialist (tier 0), as `stats` reports it.
public struct SpecialistSnapshot: Codable, Sendable, Equatable {
    public struct Metrics: Codable, Sendable, Equatable {
        public var trainedAt: Double
        public var examples: Int
        public var personalLabels: Int
        public var validation: Int
        public var accuracy: Double?
        public var teacherAccuracy: Double?
        public var quietPrecision: Double?
        public var quietCoverage: Double?
        public var trainMs: Double
        public var enabled: Bool
        public var reason: String

        enum CodingKeys: String, CodingKey {
            case examples, validation, accuracy, enabled, reason
            case trainedAt = "trained_at"
            case personalLabels = "personal_labels"
            case teacherAccuracy = "teacher_accuracy"
            case quietPrecision = "quiet_precision"
            case quietCoverage = "quiet_coverage"
            case trainMs = "train_ms"
        }

        public init(trainedAt: Double = 0, examples: Int = 0, personalLabels: Int = 0, validation: Int = 0, accuracy: Double? = nil,
                    teacherAccuracy: Double? = nil, quietPrecision: Double? = nil, quietCoverage: Double? = nil, trainMs: Double = 0,
                    enabled: Bool = false, reason: String = "") {
            self.trainedAt = trainedAt
            self.examples = examples
            self.personalLabels = personalLabels
            self.validation = validation
            self.accuracy = accuracy
            self.teacherAccuracy = teacherAccuracy
            self.quietPrecision = quietPrecision
            self.quietCoverage = quietCoverage
            self.trainMs = trainMs
            self.enabled = enabled
            self.reason = reason
        }
    }

    public var state: String
    public var metrics: Metrics
    public var decisions: Int
    public var decidedAlone: Int
    public var aloneMs: Double?
    public var generalMs: Double?
    public var agreementWithGeneral: Double?
    public var compared: Int

    enum CodingKeys: String, CodingKey {
        case state, metrics, decisions, compared
        case decidedAlone = "decided_alone"
        case aloneMs = "alone_ms"
        case generalMs = "general_ms"
        case agreementWithGeneral = "agreement_with_general"
    }

    public init(state: String, metrics: Metrics, decisions: Int = 0, decidedAlone: Int = 0, aloneMs: Double? = nil,
                generalMs: Double? = nil, agreementWithGeneral: Double? = nil, compared: Int = 0) {
        self.state = state
        self.metrics = metrics
        self.decisions = decisions
        self.decidedAlone = decidedAlone
        self.aloneMs = aloneMs
        self.generalMs = generalMs
        self.agreementWithGeneral = agreementWithGeneral
        self.compared = compared
    }

    public var isActive: Bool { state == "active" }
    /// Answers still needed before it can be checked, from its own reason.
    public var answersNeeded: Int? {
        guard !isActive, metrics.reason.hasPrefix("needs ") else { return nil }
        return Int(metrics.reason.split(separator: " ")[1])
    }
}
