import Foundation

/// What the screen looked like when Bobb looked: the app in front, its
/// window, and every element worth considering, as plain values.
public struct ScreenObservation: Sendable, Equatable {
    public var app: String
    public var bundleId: String?
    public var window: String
    public var elements: [UIElementSnapshot]
    public var screen: ScreenRect?
    /// The window's text, top to bottom.
    public var screenText: String
    /// The title of the window's default button, which Return presses.
    public var defaultButton: String
    /// The window showed no controls to read and its pixels could not be
    /// read either (the user has not allowed reading text in images).
    public var unreadable: Bool
    /// URL attested by the current native web area, independent of its title.
    public var sourceURL: String?

    public init(app: String, bundleId: String?, window: String, elements: [UIElementSnapshot], screen: ScreenRect? = nil,
                screenText: String = "", defaultButton: String = "", unreadable: Bool = false, sourceURL: String? = nil) {
        self.app = app
        self.bundleId = bundleId
        self.window = window
        self.elements = elements
        self.screen = screen
        self.screenText = screenText
        self.defaultButton = defaultButton
        self.unreadable = unreadable
        self.sourceURL = sourceURL
    }
}

/// One thing the driver does to the live desktop. Elements are named by the
/// key the driver itself handed out in the last observation.
public enum DriverAction: Sendable, Equatable {
    case press(key: Int)
    /// Open the item, as a double-click would.
    case open(key: Int)
    case type(key: Int, text: String, submit: Bool)
    case scroll(key: Int, down: Bool)
    case openApp(name: String)
    case key(KeyChord)
}

public enum DriverResult: Sendable, Equatable {
    case ok
    /// The element is gone or changed since it was observed.
    case stale
    case failed(String)
}

/// The platform half of a task: reads the accessibility tree and operates
/// applications. Implemented with AX in the app, with fakes in tests.
@MainActor
public protocol TaskDriver: AnyObject {
    var usesSharedDesktop: Bool { get }
    var requiresAccessibility: Bool { get }
    func close() async
    func observe() async -> ScreenObservation?
    /// Independent evidence required before the model may declare success.
    func completionProblem(goal: String) async -> String?
    func installedApps() -> [String]
    func bundleIdentifier(forApp name: String) -> String?
    func offeredKeys(for observation: ScreenObservation) -> [KeyChord]
    func permissionDetail(for action: DriverAction) -> String?
    func perform(_ action: DriverAction) async -> DriverResult
    /// Waits for the screen to stop changing after an action.
    func settle() async
    /// Undoes the last action, through the application's own Undo where it
    /// has one. Returns false when there is nothing Bobb can undo.
    func undoLast() async -> Bool
}

extension TaskDriver {
    public var usesSharedDesktop: Bool { true }
    public var requiresAccessibility: Bool { true }
    public func close() async {}
    public func completionProblem(goal: String) async -> String? { nil }
    public func bundleIdentifier(forApp name: String) -> String? { nil }
    public func offeredKeys(for observation: ScreenObservation) -> [KeyChord] { KeyChord.offered(bundleId: observation.bundleId) }
    public func permissionDetail(for action: DriverAction) -> String? { nil }
}

/// The daemon half of a task: plans and decides. Implemented over the
/// socket by `BobbCoordinator`.
@MainActor
public protocol TaskBrain: AnyObject {
    func plan(_ frame: TaskStartFrame) async -> TaskPlanFrame?
    func decide(_ frame: TaskObserveFrame) async -> ActFrame?
    func report(_ frame: TaskStepFrame) async
    func end(_ frame: TaskEndFrame) async
}

public enum PermissionAnswer: Sendable, Equatable {
    case allowOnce
    case allowAlways
    case deny
}

/// Runs one task to its end: observe, rank, ask the daemon, check the
/// permission engine, act, settle, report — until DONE, BLOCKED, a stop, or
/// the step limit. Every step, taken or refused, is reported to the daemon
/// for the audit trail and for the next step's history.
@MainActor
public final class TaskLoop {
    public let taskId: String
    public let goal: String
    public let state: AppState
    public var policy: ActionPolicy
    public var ranker: CandidateRanker
    public var maxSteps: Int
    public var maxConsecutiveFailures = 3
    public var maxConsecutiveWaits = 4
    public var waitDelay: UInt64 = 800_000_000
    /// Called when the user answers "Always allow", to persist the rule.
    public var onAllowAlways: ((ActionAllowRule) -> Void)?
    /// Live settings and the global desktop lease are checked at each step.
    public var currentPolicy: (() -> ActionPolicy)?
    public var shouldStop: (() -> Bool)?

    private let brain: TaskBrain
    private let driver: TaskDriver
    private var stopped = false
    private var permission: CheckedContinuation<PermissionAnswer, Never>?
    private var recentTargets: [String] = []

    public init(goal: String, state: AppState, brain: TaskBrain, driver: TaskDriver, policy: ActionPolicy,
                ranker: CandidateRanker = CandidateRanker(), maxSteps: Int = 30, taskId: String = TaskStartFrame.newTaskID()) {
        self.taskId = taskId
        self.goal = goal
        self.state = state
        self.brain = brain
        self.driver = driver
        self.policy = policy
        self.ranker = ranker
        self.maxSteps = maxSteps
    }

    // MARK: Control

    public func stop() {
        stopped = true
        answerPermission(.deny)
    }

    public func answerPermission(_ answer: PermissionAnswer) {
        let pending = permission
        permission = nil
        pending?.resume(returning: answer)
    }

    /// Undoes the last step Bobb took, if the app lets it.
    public func undoLast() async {
        guard let index = state.task?.steps.lastIndex(where: { $0.outcome == .ok && $0.operation != .wait }) else { return }
        let undone = await driver.undoLast()
        guard undone, var task = state.task else { return }
        let line = task.steps[index]
        task.steps[index].outcome = .undone
        task.canUndo = task.steps.contains { $0.outcome == .ok && $0.operation != .wait && $0.id != line.id }
        state.task = task
        await brain.report(TaskStepFrame(taskId: taskId, step: line.id, app: line.app, window: "", operation: line.operation.rawValue,
                                         target: line.target, targetRole: "", confidence: nil, permission: "allowed",
                                         outcome: .undone, latencyMs: nil, digest: ""))
    }

    // MARK: Running

    @discardableResult
    public func run() async -> TaskStatus {
        state.task = TaskRunState(id: taskId, goal: goal)
        let first = await driver.observe()
        let apps = driver.installedApps()
        guard let plan = await brain.plan(TaskStartFrame(taskId: taskId, goal: goal, app: first?.app ?? "",
                                                         window: first?.window ?? "", apps: apps)) else {
            return await finish(.failed, detail: "engine")
        }
        state.task?.plan = plan.steps

        var failures = 0
        var waits = 0
        for step in 1...max(1, maxSteps) {
            if stopped || Task.isCancelled || shouldStop?() == true { return await finish(.stopped, detail: "user") }
            if let currentPolicy { policy = currentPolicy() }
            state.task?.phase = .working
            let observation = await driver.observe() ?? ScreenObservation(app: "", bundleId: nil, window: "", elements: [])
            if policy.isProtected(bundleId: observation.bundleId, appName: observation.app), !observation.app.isEmpty {
                return await finish(.blocked, detail: "protected")
            }
            let focusWords = plan.steps.joined(separator: " ")
            let ranked = ranker.rank(observation.elements, goal: goal, focus: focusWords, recent: recentTargets, screen: observation.screen)
            let table = CandidateTable(ranked: ranked, observation: step)
            let appChoices = Self.appCandidates(apps, goal: goal + " " + focusWords, current: observation.app)
            let screenText = String(observation.screenText.prefix(Self.maxScreenText))
            let keys = driver.offeredKeys(for: observation)
            let digest = table.digest(screenText: screenText)
            let frame = TaskObserveFrame(taskId: taskId, step: step, app: observation.app, window: observation.window,
                                         digest: digest, candidates: table.candidates, apps: appChoices,
                                         screenText: screenText.isEmpty ? nil : screenText, keys: keys.map(\.rawValue))
            guard let act = await brain.decide(frame) else {
                return await finish(.failed, detail: "engine")
            }
            if stopped { return await finish(.stopped, detail: "user") }

            switch act.operation {
            case .done:
                if let problem = await driver.completionProblem(goal: goal) {
                    return await finish(.blocked, detail: problem)
                }
                if let text = act.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    state.task?.report = text
                }
                return await finish(.done, detail: act.why)
            case .blocked:
                return await finish(.blocked, detail: observation.unreadable ? "unreadable" : act.why)
            case .wait:
                waits += 1
                if waits > maxConsecutiveWaits { return await finish(.blocked, detail: "waiting") }
                try? await Task.sleep(nanoseconds: waitDelay)
                continue
            default:
                waits = 0
            }

            guard let resolved = resolve(act, table: table, apps: appChoices, keys: keys) else {
                await report(step, act, observation, label: act.targetLabel ?? "", role: "", outcome: .failed, permission: "allowed", digest: digest)
                failures += 1
                if failures >= maxConsecutiveFailures { return await finish(.failed, detail: "stale") }
                continue
            }

            let element = resolved.element
            let actionDetail = driver.permissionDetail(for: resolved.action) ?? act.text
            let multiline = element?.role == "AXTextArea" || element?.role == "AXWebArea"
            let verdict = policy.evaluate(operation: act.operation, label: resolved.label, role: element?.role ?? resolved.role,
                                          appBundleId: act.operation == .openApp ? driver.bundleIdentifier(forApp: resolved.label) : observation.bundleId,
                                          appName: act.operation == .openApp ? resolved.label : observation.app,
                                          secure: element?.isSecure ?? false, submit: act.submit, multiline: multiline,
                                          window: observation.window, key: resolved.key, defaultButton: observation.defaultButton,
                                          context: observation.screenText, typedText: actionDetail ?? "", websiteURL: observation.sourceURL)
            var permissionUsed = "allowed"
            switch verdict {
            case .deny(let reason):
                await report(step, act, observation, label: resolved.label, role: resolved.role, outcome: .denied, permission: "refused", digest: digest)
                return await finish(.blocked, detail: reason)
            case .ask(let reason):
                let request = PermissionRequest(operation: act.operation, label: resolved.label, role: resolved.role,
                                                app: observation.app, reason: reason, text: actionDetail)
                state.task?.phase = .waitingForPermission(request)
                let answer = await askPermission()
                if answer == .deny || stopped {
                    await report(step, act, observation, label: resolved.label, role: resolved.role, outcome: .denied, permission: "refused", digest: digest)
                    return await finish(.stopped, detail: "declined")
                }
                if answer == .allowAlways {
                    if reason != ActionPolicy.Reason.settings.rawValue && reason != "visualTarget" && !reason.hasPrefix("boundary:") {
                        let rule = ActionAllowRule(app: observation.bundleId ?? observation.app, operation: act.operation.rawValue, label: resolved.label)
                        policy.allowRules.insert(rule)
                        onAllowAlways?(rule)
                    }
                }
                permissionUsed = "asked"
            case .allow:
                break
            }

            if stopped || Task.isCancelled || shouldStop?() == true { return await finish(.stopped, detail: "user") }
            if let currentPolicy {
                let live = currentPolicy()
                if live.boundaries != policy.boundaries || live.protectedApps.extraProtected != policy.protectedApps.extraProtected {
                    return await finish(.blocked, detail: "boundariesChanged")
                }
            }

            state.task?.phase = .acting
            appendLine(TaskStepLine(id: step, operation: act.operation, target: resolved.label,
                                    text: actionDetail, app: observation.app))
            let started = Date()
            let result = await driver.perform(resolved.action)
            await driver.settle()
            let outcome: StepOutcome = result == .ok ? .ok : .failed
            updateLine(step, outcome: outcome)
            recentTargets.append(resolved.label)
            await report(step, act, observation, label: resolved.label, role: resolved.role, outcome: outcome,
                         permission: permissionUsed, digest: digest, latency: Date().timeIntervalSince(started) * 1000)
            if outcome == .ok {
                failures = 0
                state.task?.canUndo = act.operation != .openApp
            } else {
                failures += 1
                if failures >= maxConsecutiveFailures { return await finish(.failed, detail: "actions") }
            }
        }
        return await finish(.blocked, detail: "steps")
    }

    // MARK: Helpers

    /// How much of the window's text travels with each observation.
    static let maxScreenText = 6000

    struct Resolved {
        var action: DriverAction
        var label: String
        var role: String
        var element: UIElementSnapshot?
        var key: KeyChord? = nil
    }

    func resolve(_ act: ActFrame, table: CandidateTable, apps: [AppCandidate], keys: [KeyChord] = KeyChord.allCases) -> Resolved? {
        if act.operation == .openApp {
            guard let app = apps.first(where: { $0.id == act.candidateId }) else { return nil }
            return Resolved(action: .openApp(name: app.label), label: app.label, role: "application", element: nil)
        }
        if act.operation == .key {
            // Only a key that was offered, by its exact name.
            guard let chord = KeyChord(rawValue: act.candidateId), keys.contains(chord) else { return nil }
            return Resolved(action: .key(chord), label: chord.symbol, role: "key", element: nil, key: chord)
        }
        guard let key = table.keys[act.candidateId], let element = table.byId[act.candidateId],
              let candidate = table.candidates.first(where: { $0.id == act.candidateId }) else { return nil }
        let action: DriverAction
        switch act.operation {
        case .click, .select:
            guard candidate.kind == .press else { return nil }
            action = .press(key: key)
        case .open:
            guard candidate.kind == .press else { return nil }
            action = .open(key: key)
        case .type, .typeText:
            guard candidate.kind == .text, let text = act.text, !text.isEmpty else { return nil }
            action = .type(key: key, text: text, submit: act.submit)
        case .scrollDown, .scrollUp:
            guard candidate.kind == .scroll else { return nil }
            action = .scroll(key: key, down: act.operation == .scrollDown)
        default:
            return nil
        }
        return Resolved(action: action, label: candidate.label, role: candidate.role, element: element)
    }

    /// Installed applications worth offering for this request: those whose
    /// names share a word with it, best first, never the one already in front.
    static func appCandidates(_ apps: [String], goal: String, current: String, limit: Int = 10) -> [AppCandidate] {
        let words = Set(Tokens.words(goal))
        guard !words.isEmpty else { return [] }
        var scored: [(String, Double)] = []
        for name in apps where name != current {
            let nameWords = Tokens.words(name)
            guard !nameWords.isEmpty else { continue }
            var score = 0.0
            for word in nameWords {
                if words.contains(word) { score += 2 }
                else if word.count >= 4, words.contains(where: { $0.count >= 4 && ($0.hasPrefix(word) || word.hasPrefix($0)) }) { score += 1 }
            }
            if score > 0 { scored.append((name, score / Double(nameWords.count))) }
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        return scored.prefix(limit).enumerated().map { AppCandidate(id: "app\($0.offset + 1)", label: $0.element.0) }
    }

    private func askPermission() async -> PermissionAnswer {
        if stopped { return .deny }
        return await withCheckedContinuation { continuation in
            permission = continuation
        }
    }

    private func appendLine(_ line: TaskStepLine) {
        state.task?.steps.append(line)
    }

    private func updateLine(_ step: Int, outcome: StepOutcome) {
        guard let index = state.task?.steps.lastIndex(where: { $0.id == step }) else { return }
        state.task?.steps[index].outcome = outcome
    }

    private func report(_ step: Int, _ act: ActFrame, _ observation: ScreenObservation, label: String, role: String,
                        outcome: StepOutcome, permission: String, digest: String, latency: Double? = nil) async {
        await brain.report(TaskStepFrame(taskId: taskId, step: step, app: observation.app, window: observation.window,
                                         operation: act.operation.rawValue, target: label, targetRole: role,
                                         confidence: act.confidence, permission: permission, outcome: outcome,
                                         latencyMs: latency ?? act.latencyMs, digest: digest))
    }

    private func finish(_ status: TaskStatus, detail: String) async -> TaskStatus {
        if var task = state.task, task.id == taskId {
            task.phase = .finished(status, detail: detail)
            state.task = task
        }
        await brain.end(TaskEndFrame(taskId: taskId, status: status, detail: detail))
        return status
    }
}

// MARK: - State the task panel shows

public struct PermissionRequest: Sendable, Equatable {
    public var operation: ActOperation
    public var label: String
    public var role: String
    public var app: String
    public var reason: String
    public var text: String?

    public init(operation: ActOperation, label: String, role: String, app: String, reason: String, text: String? = nil) {
        self.operation = operation
        self.label = label
        self.role = role
        self.app = app
        self.reason = reason
        self.text = text
    }
}

public struct TaskStepLine: Sendable, Equatable, Identifiable {
    public var id: Int
    public var operation: ActOperation
    public var target: String
    public var text: String?
    public var app: String
    /// nil while the step is running.
    public var outcome: StepOutcome?

    public init(id: Int, operation: ActOperation, target: String, text: String? = nil, app: String = "", outcome: StepOutcome? = nil) {
        self.id = id
        self.operation = operation
        self.target = target
        self.text = text
        self.app = app
        self.outcome = outcome
    }
}

public enum TaskPhase: Sendable, Equatable {
    case planning
    case working
    case acting
    case waitingForPermission(PermissionRequest)
    case finished(TaskStatus, detail: String)
    /// "Show me": the user is doing it and Bobb is watching.
    case watching
    /// The demonstration was kept as a procedure.
    case learned
}

public struct TaskRunState: Sendable, Equatable {
    public var id: String
    public var goal: String
    public var plan: [String] = []
    public var steps: [TaskStepLine] = []
    public var phase: TaskPhase = .planning
    public var canUndo = false
    public var startedAt: Date
    /// What Bobb found, when the request was to find something out.
    public var report: String?

    public init(id: String, goal: String, startedAt: Date = Date()) {
        self.id = id
        self.goal = goal
        self.startedAt = startedAt
    }

    public var isFinished: Bool {
        switch phase {
        case .finished, .learned: return true
        default: return false
        }
    }

    public var status: TaskStatus {
        if case .finished(let status, _) = phase { return status }
        return .running
    }
}
