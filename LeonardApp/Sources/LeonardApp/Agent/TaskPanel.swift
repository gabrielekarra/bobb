import AppKit
import SwiftUI
import LeonardCore

/// What the task panel's buttons do.
@MainActor
struct TaskActions {
    var stop: () -> Void
    var allow: (PermissionAnswer) -> Void
    var undo: () -> Void
    var close: () -> Void
    var showMe: () -> Void = {}
    var finishShowing: (Bool) -> Void = { _ in }
}

/// The task panel: a small card at the top of the screen while Leonard
/// works in your apps. It says what Leonard is doing right now in one line,
/// shows the plan and the steps taken, asks before anything consequential,
/// and always offers Stop. It never takes focus from the app being used.
struct TaskView: View {
    let state: AppState
    let actions: TaskActions

    var body: some View {
        if let task = state.task {
            VStack(alignment: .leading, spacing: 10) {
                header(task)
                if case .waitingForPermission(let request) = task.phase {
                    permission(request)
                } else if case .watching = task.phase {
                    watching
                } else if case .learned = task.phase {
                    Label(L10n.t(.taskLearned), systemImage: "graduationcap")
                        .font(.system(size: 12))
                } else if case .finished(let status, let detail) = task.phase {
                    finished(task, status: status, detail: detail)
                } else {
                    activity(task)
                }
                if !task.steps.isEmpty { steps(task) }
                if !task.isFinished {
                    Text(L10n.t(.taskEscHint))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .frame(width: 440, alignment: .leading)
        }
    }

    private func header(_ task: TaskRunState) -> some View {
        HStack(alignment: .top, spacing: 10) {
            LeonardMark(size: 26, color: markColor(task), eyes: eyes(task))
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.goal)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                if !task.plan.isEmpty, task.plan != [task.goal] {
                    Text(task.plan.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "  "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if task.isFinished {
                Button(L10n.t(.genericClose), action: actions.close)
                    .buttonStyle(QuietButtonStyle())
            } else {
                Button(L10n.t(.taskStop), action: actions.stop)
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func activity(_ task: TaskRunState) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(Self.activityLine(task))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    static func activityLine(_ task: TaskRunState) -> String {
        switch task.phase {
        case .planning:
            return L10n.t(.taskPlanning)
        case .working:
            return L10n.t(.taskLooking, ["app": task.steps.last?.app ?? "…"])
        case .acting:
            guard let line = task.steps.last else { return L10n.t(.taskPlanning) }
            return describe(line)
        default:
            return ""
        }
    }

    static func describe(_ line: TaskStepLine) -> String {
        switch line.operation {
        case .click, .select, .key: L10n.t(.taskPressing, ["target": line.target])
        case .open: L10n.t(.taskOpening, ["target": line.target])
        case .type, .typeText: L10n.t(.taskTyping, ["target": line.target])
        case .scrollDown, .scrollUp: L10n.t(.taskScrolling, ["target": line.target])
        case .openApp: L10n.t(.taskOpening, ["target": line.target])
        case .wait: L10n.t(.taskWaiting)
        case .done: L10n.t(.taskDone)
        case .blocked: L10n.t(.taskStopped)
        }
    }

    private func permission(_ request: PermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.question(request))
                .font(.system(size: 12.5, weight: .medium))
            Text(Self.reason(request.reason))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            if let text = request.text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 11.5))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.smallCorner))
                    .lineLimit(6)
            }
            HStack {
                Button(L10n.t(.taskStop)) { actions.allow(.deny) }
                    .buttonStyle(QuietButtonStyle())
                Spacer()
                Button(L10n.t(.taskAllowAlways, ["app": request.app])) { actions.allow(.allowAlways) }
                    .buttonStyle(QuietButtonStyle())
                Button(L10n.t(.taskAllow)) { actions.allow(.allowOnce) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .background(Theme.attention.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.corner))
    }

    static func question(_ request: PermissionRequest) -> String {
        let values = ["target": request.label, "app": request.app]
        switch request.operation {
        case .type, .typeText:
            return L10n.t(request.reason == ActionPolicy.Reason.sendsMessage.rawValue ? .taskAskTypeSubmit : .taskAskType, values)
        case .scrollDown, .scrollUp: return L10n.t(.taskAskScroll, values)
        case .openApp: return L10n.t(.taskAskOpen, values)
        default: return L10n.t(.taskAskPress, values)
        }
    }

    static func reason(_ reason: String) -> String {
        switch ActionPolicy.Reason(rawValue: reason) {
        case .sends: L10n.t(.reasonSends)
        case .pays: L10n.t(.reasonPays)
        case .deletes: L10n.t(.reasonDeletes)
        case .publishes: L10n.t(.reasonPublishes)
        case .signs: L10n.t(.reasonSigns)
        case .runsCommand: L10n.t(.reasonRunsCommand)
        case .sendsMessage: L10n.t(.reasonSendsMessage)
        case .closesWithoutSaving: L10n.t(.reasonClosesWithoutSaving)
        case .everyStep: L10n.t(.reasonEveryStep)
        case nil: reason
        }
    }

    private func finished(_ task: TaskRunState, status: TaskStatus, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Self.outcome(status: status, detail: detail))
                .font(.system(size: 12))
                .foregroundStyle(status == .done ? Color.primary : Theme.attention)
            Spacer()
            if task.canUndo {
                Button(L10n.t(.taskUndo), action: actions.undo)
                    .buttonStyle(QuietButtonStyle())
            }
            if status == .blocked || status == .failed {
                Button(L10n.t(.taskShowMe), action: actions.showMe)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var watching: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.t(.taskWatching), systemImage: "eye")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.t(.genericCancel)) { actions.finishShowing(false) }
                    .buttonStyle(QuietButtonStyle())
                Spacer()
                Button(L10n.t(.taskWatchDone)) { actions.finishShowing(true) }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(10)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.corner))
    }

    static func outcome(status: TaskStatus, detail: String) -> String {
        switch status {
        case .done: return L10n.t(.taskDone)
        case .stopped: return L10n.t(.taskStopped)
        case .blocked: return L10n.t(.taskBlocked, ["reason": explain(detail)])
        case .failed: return L10n.t(.taskFailed, ["reason": explain(detail)])
        case .running: return ""
        }
    }

    /// The loop's and the daemon's short reasons, in the user's words.
    static func explain(_ detail: String) -> String {
        switch detail {
        case "engine": return L10n.t(.taskEngine)
        case "protected": return L10n.t(.taskProtected)
        case "secure": return L10n.t(.taskSecure)
        case "steps": return L10n.t(.taskTooManySteps)
        case "waiting": return L10n.t(.taskKeptLoading)
        case "stale", "actions": return L10n.t(.taskAppDidNotRespond)
        default:
            if detail.hasPrefix("not sure") { return L10n.t(.taskNotSure) }
            if detail.hasPrefix("nothing on screen") { return L10n.t(.taskNothingFits) }
            if detail.hasPrefix("the same step") { return L10n.t(.taskStuck) }
            if detail.hasPrefix("stopped after") { return L10n.t(.taskTooManySteps) }
            return detail
        }
    }

    private func steps(_ task: TaskRunState) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(task.steps.suffix(6)) { line in
                HStack(spacing: 6) {
                    Image(systemName: icon(line.outcome))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(color(line.outcome))
                        .frame(width: 12)
                    Text(Self.describe(line))
                        .font(.system(size: 11))
                        .foregroundStyle(line.outcome == .undone ? .tertiary : .secondary)
                        .strikethrough(line.outcome == .undone)
                        .lineLimit(1)
                }
            }
        }
    }

    private func icon(_ outcome: StepOutcome?) -> String {
        switch outcome {
        case .ok: "checkmark"
        case .failed: "xmark"
        case .denied: "hand.raised"
        case .undone: "arrow.uturn.backward"
        case .user: "person"
        case nil: "circle.dotted"
        }
    }

    private func color(_ outcome: StepOutcome?) -> Color {
        switch outcome {
        case .ok: .green
        case .failed, .denied: Theme.attention
        default: .secondary
        }
    }

    private func markColor(_ task: TaskRunState) -> Color {
        if case .waitingForPermission = task.phase { return Theme.attention }
        if case .finished(let status, _) = task.phase, status != .done { return Theme.attention }
        return .primary
    }

    private func eyes(_ task: TaskRunState) -> Glasses.Eyes {
        switch task.phase {
        case .waitingForPermission: .look(CGVector(dx: 0, dy: 1))
        case .acting: .look(CGVector(dx: 0.8, dy: 0.2))
        case .finished(let status, _): status == .done ? .up : .closed
        case .watching: .look(CGVector(dx: -0.7, dy: 0.5))
        default: .up
        }
    }
}

/// Owns the task panel and the running `TaskLoop`: starts tasks from the
/// command bar, shows the panel, forwards Stop, permission answers and
/// Undo, and listens for ⎋ anywhere while a task runs.
@MainActor
final class TaskController {
    private let state: AppState
    private let coordinator: LeonardCoordinator
    private var panel: NSPanel?
    private var loop: TaskLoop?
    private var running: Task<Void, Never>?
    private var escapeMonitors: [Any] = []
    private var hideTask: Task<Void, Never>?
    let driver = AXDriver()
    var brainFactory: (() -> any TaskBrain)?
    private var leaseId: String?

    init(state: AppState, coordinator: LeonardCoordinator) {
        self.state = state
        self.coordinator = coordinator
    }

    var isRunning: Bool { running != nil }

    /// Starts `goal`, replacing any task already running. Returns a reason
    /// it cannot start, in the user's words, or nil.
    @discardableResult
    func start(goal: String) -> String? {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard state.settings.actingEnabled else { return L10n.t(.taskDisabled) }
        guard AXIsProcessTrusted() else { return L10n.t(.taskNotTrusted) }
        guard state.entitlement.allowsAssistance else { return L10n.t(.statusTrialExpired) }
        if let leaseId { ScreenLease.shared.release(leaseId) }
        loop?.stop()
        running?.cancel()
        let id = TaskStartFrame.newTaskID()
        guard ScreenLease.shared.acquire(id) else { return BobbCopy.t("The desktop is busy. Stop its current task in Bobb Activity.", "Lo schermo è occupato. Ferma l’incarico attuale in Attività di Bobb.") }
        leaseId = id
        driver.settings = { [weak self] in self?.state.settings ?? LeonardSettings() }
        driver.stillOwnsScreen = { ScreenLease.shared.owner == id }

        let settings = state.settings
        let policy = ActionPolicy(approval: settings.actingApproval, allowRules: settings.actionAllowRules,
                                  extraProtected: settings.extraProtectedApps, boundaries: settings.bobb.boundaries)
        let loop = TaskLoop(goal: trimmed, state: state, brain: brainFactory?() ?? coordinator, driver: driver, policy: policy, taskId: id)
        loop.currentPolicy = { [weak self] in
            let s = self?.state.settings ?? LeonardSettings()
            return ActionPolicy(approval: s.actingApproval, allowRules: s.actionAllowRules, extraProtected: s.extraProtectedApps, boundaries: s.bobb.boundaries)
        }
        loop.shouldStop = { [weak self] in self?.state.settings.actingEnabled != true || ScreenLease.shared.owner != id }
        loop.onAllowAlways = { [weak self] rule in
            self?.coordinator.updateSettings { settings in
                if !settings.actionAllowRules.contains(rule) { settings.actionAllowRules.append(rule) }
            }
        }
        self.loop = loop
        hideTask?.cancel()
        show()
        installEscape()
        running = Task { [weak self] in
            let status = await loop.run()
            ScreenLease.shared.release(id)
            if self?.leaseId == id { self?.leaseId = nil; self?.finished(status) }
        }
        return nil
    }

    func stop() {
        if watcher != nil {
            finishShowing(keep: false)
            return
        }
        loop?.stop()
    }

    // MARK: Show me

    private var watcher: DemonstrationWatcher?

    /// The user does it themselves; Leonard watches and learns the way.
    private func startShowing() {
        guard let task = state.task, running == nil else { return }
        hideTask?.cancel()
        let watcher = DemonstrationWatcher(goal: task.goal, protectedApps: state.settings.extraProtectedApps)
        watcher.onChange = { [weak self] recorder in
            self?.state.task?.steps = recorder.steps
        }
        self.watcher = watcher
        state.task?.steps = []
        state.task?.canUndo = false
        state.task?.phase = .watching
        watcher.start()
        installEscape()
    }

    private func finishShowing(keep: Bool) {
        guard let watcher else { return }
        self.watcher = nil
        removeEscape()
        let recorder = watcher.stop()
        if keep && !recorder.steps.isEmpty {
            coordinator.recordProcedure(recorder.frame)
            state.task?.phase = .learned
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self?.close()
            }
        } else {
            close()
        }
    }

    private func finished(_ status: TaskStatus) {
        running = nil
        removeEscape()
        resize()
        Task { await coordinator.refreshTasks() }
        if status == .done {
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                self?.close()
            }
        }
    }

    func close() {
        guard running == nil, watcher == nil else { return }
        panel?.orderOut(nil)
        state.task = nil
    }

    private func show() {
        if panel == nil {
            let view = TaskView(state: state, actions: TaskActions(
                stop: { [weak self] in self?.stop() },
                allow: { [weak self] answer in self?.loop?.answerPermission(answer) },
                undo: { [weak self] in
                    guard let loop = self?.loop else { return }
                    Task { await loop.undoLast() }
                },
                close: { [weak self] in self?.close() },
                showMe: { [weak self] in self?.startShowing() },
                finishShowing: { [weak self] keep in self?.finishShowing(keep: keep) }
            ))
            let hosting = NSHostingView(rootView: view.background(.regularMaterial))
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 120),
                                styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            hosting.wantsLayer = true
            hosting.layer?.cornerRadius = 14
            hosting.layer?.masksToBounds = true
            panel.contentView = hosting
            self.panel = panel
            observeSize()
        }
        resize()
        panel?.orderFrontRegardless()
    }

    private func observeSize() {
        withObservationTracking {
            _ = state.task
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.resize()
                self?.observeSize()
            }
        }
    }

    private func resize() {
        guard let panel, let hosting = panel.contentView else { return }
        let size = hosting.fittingSize
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 10)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func installEscape() {
        removeEscape()
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.stop() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) {
            escapeMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            handler(event)
            return event
        }) {
            escapeMonitors.append(local)
        }
    }

    private func removeEscape() {
        for monitor in escapeMonitors { NSEvent.removeMonitor(monitor) }
        escapeMonitors.removeAll()
    }
}
