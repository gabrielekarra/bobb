import Foundation

// Tasks: Leonard doing a job in any application. See docs/CONTRACT.md,
// "Tasks", and leonardd/leonardd/agent.py. The app observes and acts; the
// daemon only ever sees opaque ids with human labels and answers with one.

/// What an element offered to the daemon can be used for.
public enum CandidateKind: String, Codable, Sendable, Equatable, CaseIterable {
    case press
    case text
    case scroll
}

/// One element on screen, offered to the daemon as an opaque id with the
/// words a person would use for it. Never a coordinate, never a path.
public struct AgentCandidate: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var role: String
    public var kind: CandidateKind
    public var enabled: Bool
    public var focused: Bool
    /// The current text, for fields only.
    public var value: String
    /// Where it is, in words: "toolbar", "sidebar", "File menu".
    public var `where`: String
    /// The selected row, tab, option or cell. Sent only when true.
    public var selected: Bool

    enum CodingKeys: String, CodingKey {
        case id, label, role, kind, enabled, focused, value, `where`, selected
    }

    public init(id: String, label: String, role: String, kind: CandidateKind, enabled: Bool = true,
                focused: Bool = false, value: String = "", where: String = "", selected: Bool = false) {
        self.id = id
        self.label = label
        self.role = role
        self.kind = kind
        self.enabled = enabled
        self.focused = focused
        self.value = value
        self.where = `where`
        self.selected = selected
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        role = try c.decode(String.self, forKey: .role)
        kind = try c.decode(CandidateKind.self, forKey: .kind)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        focused = try c.decodeIfPresent(Bool.self, forKey: .focused) ?? false
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        `where` = try c.decodeIfPresent(String.self, forKey: .where) ?? ""
        selected = try c.decodeIfPresent(Bool.self, forKey: .selected) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(role, forKey: .role)
        try c.encode(kind, forKey: .kind)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(focused, forKey: .focused)
        try c.encode(value, forKey: .value)
        try c.encode(`where`, forKey: .where)
        if selected { try c.encode(selected, forKey: .selected) }
    }
}

/// An application that can be opened, offered the same way.
public struct AppCandidate: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// App → daemon `task.start`.
public struct TaskStartFrame: Codable, Sendable, Equatable {
    public var id: String
    public var taskId: String
    public var goal: String
    public var app: String
    public var window: String
    public var apps: [String]

    enum CodingKeys: String, CodingKey {
        case id, goal, app, window, apps
        case taskId = "task_id"
    }

    public init(id: String = RequestFrame.newID(), taskId: String, goal: String, app: String, window: String, apps: [String]) {
        self.id = id
        self.taskId = taskId
        self.goal = goal
        self.app = app
        self.window = window
        self.apps = apps
    }

    public static func newTaskID() -> String {
        "task_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
    }
}

/// App → daemon `observe` for a task: everything that can be done now.
public struct TaskObserveFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var id: String
    public var taskId: String
    public var step: Int
    public var app: String
    public var window: String
    public var digest: String
    public var candidates: [AgentCandidate]
    public var apps: [AppCandidate]
    /// What the window shows, top to bottom, read from the screen: the
    /// figures in a sheet, the text of a page, the code in an editor.
    public var screenText: String?
    /// The keys that make sense here, by `KeyChord` name.
    public var keys: [String]?

    enum CodingKeys: String, CodingKey {
        case ts, id, step, app, window, digest, candidates, apps, keys
        case taskId = "task_id"
        case screenText = "screen_text"
    }

    public init(ts: Double = Date().timeIntervalSince1970, id: String = TaskObserveFrame.newID(), taskId: String, step: Int,
                app: String, window: String, digest: String, candidates: [AgentCandidate], apps: [AppCandidate],
                screenText: String? = nil, keys: [String]? = nil) {
        self.ts = ts
        self.id = id
        self.taskId = taskId
        self.step = step
        self.app = app
        self.window = window
        self.digest = digest
        self.candidates = candidates
        self.apps = apps
        self.screenText = screenText
        self.keys = keys
    }

    public static func newID() -> String {
        "obs_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
    }
}

/// How a step ended, as the app saw it.
public enum StepOutcome: String, Codable, Sendable, Equatable {
    case ok
    case failed
    /// The permission engine or the user refused it.
    case denied
    case undone
    /// The user did the step themselves.
    case user
}

/// App → daemon `task.step`: what actually happened, for the audit and for
/// the next step's history.
public struct TaskStepFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var taskId: String
    public var step: Int
    public var app: String
    public var window: String
    public var operation: String
    public var target: String
    public var targetRole: String
    public var confidence: Double?
    /// "allowed", "asked" (the user approved), or "refused".
    public var permission: String
    public var outcome: StepOutcome
    public var latencyMs: Double?
    public var digest: String

    enum CodingKeys: String, CodingKey {
        case ts, step, app, window, operation, target, confidence, permission, outcome, digest
        case taskId = "task_id"
        case targetRole = "target_role"
        case latencyMs = "latency_ms"
    }

    public init(ts: Double = Date().timeIntervalSince1970, taskId: String, step: Int, app: String, window: String,
                operation: String, target: String, targetRole: String, confidence: Double?, permission: String,
                outcome: StepOutcome, latencyMs: Double?, digest: String) {
        self.ts = ts
        self.taskId = taskId
        self.step = step
        self.app = app
        self.window = window
        self.operation = operation
        self.target = target
        self.targetRole = targetRole
        self.confidence = confidence
        self.permission = permission
        self.outcome = outcome
        self.latencyMs = latencyMs
        self.digest = digest
    }
}

public enum TaskStatus: String, Codable, Sendable, Equatable {
    case running, done, stopped, blocked, failed
}

/// App → daemon `task.end`.
public struct TaskEndFrame: Codable, Sendable, Equatable {
    public var taskId: String
    public var status: TaskStatus
    public var detail: String

    enum CodingKeys: String, CodingKey {
        case status, detail
        case taskId = "task_id"
    }

    public init(taskId: String, status: TaskStatus, detail: String = "") {
        self.taskId = taskId
        self.status = status
        self.detail = detail
    }
}

public struct TasksRecentFrame: Codable, Sendable, Equatable {
    public var id: String
    public var limit: Int

    public init(id: String = RequestFrame.newID(), limit: Int = 30) {
        self.id = id
        self.limit = limit
    }
}

/// Daemon → app `task.plan`: the steps the text model proposes. Shown to the
/// user as the task's outline; each step is still decided on screen.
public struct TaskPlanFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var requestId: String?
    public var taskId: String
    public var goal: String
    public var steps: [String]

    enum CodingKeys: String, CodingKey {
        case ts, goal, steps
        case requestId = "request_id"
        case taskId = "task_id"
    }

    public init(ts: Double, requestId: String?, taskId: String, goal: String, steps: [String]) {
        self.ts = ts
        self.requestId = requestId
        self.taskId = taskId
        self.goal = goal
        self.steps = steps
    }
}

public struct TaskStepRecord: Codable, Sendable, Equatable {
    public var step: Int
    public var ts: Double
    public var app: String?
    public var window: String?
    public var operation: String
    public var target: String?
    public var confidence: Double?
    public var permission: String?
    public var outcome: String
    public var latencyMs: Double?

    enum CodingKeys: String, CodingKey {
        case step, ts, app, window, operation, target, confidence, permission, outcome
        case latencyMs = "latency_ms"
    }

    public init(step: Int, ts: Double, app: String? = nil, window: String? = nil, operation: String, target: String? = nil,
                confidence: Double? = nil, permission: String? = nil, outcome: String, latencyMs: Double? = nil) {
        self.step = step
        self.ts = ts
        self.app = app
        self.window = window
        self.operation = operation
        self.target = target
        self.confidence = confidence
        self.permission = permission
        self.outcome = outcome
        self.latencyMs = latencyMs
    }
}

public struct TaskRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var ts: Double
    public var goal: String
    public var app: String?
    public var plan: [String]
    public var status: String
    public var endedTs: Double?
    public var detail: String
    public var steps: [TaskStepRecord]

    enum CodingKeys: String, CodingKey {
        case id, ts, goal, app, plan, status, detail, steps
        case endedTs = "ended_ts"
    }

    public init(id: String, ts: Double, goal: String, app: String? = nil, plan: [String], status: String,
                endedTs: Double? = nil, detail: String = "", steps: [TaskStepRecord]) {
        self.id = id
        self.ts = ts
        self.goal = goal
        self.app = app
        self.plan = plan
        self.status = status
        self.endedTs = endedTs
        self.detail = detail
        self.steps = steps
    }
}

public struct TasksResultsFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var requestId: String?
    public var tasks: [TaskRecord]

    enum CodingKeys: String, CodingKey {
        case ts, tasks
        case requestId = "request_id"
    }

    public init(ts: Double, requestId: String?, tasks: [TaskRecord]) {
        self.ts = ts
        self.requestId = requestId
        self.tasks = tasks
    }
}

/// The `tasks` block of a `stats` frame.
public struct TaskSummary: Codable, Sendable, Equatable {
    public var tasks: Int
    public var done: Int
    public var stopped: Int
    public var blocked: Int
    public var steps: Int
    public var stepsOk: Int
    public var asked: Int
    public var undone: Int
    public var meanStepMs: Double?

    enum CodingKeys: String, CodingKey {
        case tasks, done, stopped, blocked, steps, asked, undone
        case stepsOk = "steps_ok"
        case meanStepMs = "mean_step_ms"
    }

    public init(tasks: Int = 0, done: Int = 0, stopped: Int = 0, blocked: Int = 0, steps: Int = 0, stepsOk: Int = 0,
                asked: Int = 0, undone: Int = 0, meanStepMs: Double? = nil) {
        self.tasks = tasks
        self.done = done
        self.stopped = stopped
        self.blocked = blocked
        self.steps = steps
        self.stepsOk = stepsOk
        self.asked = asked
        self.undone = undone
        self.meanStepMs = meanStepMs
    }
}
