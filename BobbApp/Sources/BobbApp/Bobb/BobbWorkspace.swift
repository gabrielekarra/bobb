import AppKit
import Observation
import BobbCore

@MainActor
@Observable
final class WorkExecution: Identifiable {
    let id: String
    let run: WorkRun
    let state: AppState
    let loop: TaskLoop
    let driver: any TaskDriver
    var finished = false
    var foreground: Bool
    var task: Task<Void, Never>?
    init(run: WorkRun, state: AppState, loop: TaskLoop, driver: any TaskDriver, foreground: Bool) {
        id = run.id; self.run = run; self.state = state; self.loop = loop; self.driver = driver; self.foreground = foreground
    }
}

@MainActor
@Observable
final class RemoteReply: Identifiable {
    let id = UUID().uuidString
    let address: String
    let text: String
    init(address: String, text: String) { self.address = address; self.text = text }
}

/// App-side work supervisor. SQLite is the authority; this object only
/// holds currently executing loops and their local computers.
@MainActor
@Observable
final class BobbWorkspace {
    let state: AppState
    let coordinator: BobbCoordinator
    let messages = IMessageBridge()
    let virtualMac = VirtualMac()
    var snapshot: WorkspaceStateFrame?
    var executions: [WorkExecution] = []
    var remoteReplies: [RemoteReply] = []
    var message: String?
    var onPrepareInitiative: ((ProactiveInitiative) -> Void)?
    var onPresentInitiative: ((ProactiveInitiative) -> Void)?
    var window: NSWindow?
    private var computers: [String: UserBrowserComputer] = [:]
    private var ticker: Task<Void, Never>?
    private var busy = false
    private let owner = UUID().uuidString
    var agents: [BobbAgent] {
        guard let agents = snapshot?.agents, !agents.isEmpty else { return [BobbAgent()] }
        return agents
    }
    var activeAgent: BobbAgent { agents.first { $0.id == state.settings.bobb.activeAgent } ?? agents.first ?? BobbAgent() }

    init(state: AppState, coordinator: BobbCoordinator) {
        self.state = state; self.coordinator = coordinator
        messages.onCommand = { [weak self] prompt, address in
            Task { @MainActor [weak self] in await self?.remoteCommand(prompt, address: address) }
        }
    }

    func start() {
        DesktopActivity.shared.start()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        settingsChanged()
    }
    func stop() {
        ticker?.cancel(); ticker = nil; messages.stop(); virtualMac.stop()
        for execution in executions where !execution.finished {
            execution.loop.stop(); execution.task?.cancel()
            ScreenLease.shared.release(execution.id)
            (execution.driver as? MCPComputer)?.close()
        }
    }
    func settingsChanged() {
        let settings = state.settings.bobb
        let connected = settings.boundaries.app(bundleId: "com.apple.MobileSMS", name: "Messages") != nil
            && !ScreenMemoryPolicy(extraProtected: state.settings.extraProtectedApps).isProtected(bundleId: "com.apple.MobileSMS", appName: "Messages")
        messages.configure(enabled: settings.iMessageEnabled && connected, address: settings.selfAddress)
    }
    func show() {
        if window == nil {
            window = WindowPresenter.makeWindow(title: "Bobb", size: NSSize(width: 880, height: 720),
                                                content: BobbView(workspace: self))
        }
        WindowPresenter.present(window)
        Task { await refresh() }
    }

    @discardableResult
    func command(_ op: String = "list", _ payload: JSONValue = .object([:])) async -> WorkspaceStateFrame? {
        guard let result = await coordinator.workspace(op, payload: payload) else {
            message = BobbCopy.t("The request failed. Check the fields and the engine connection.", "La richiesta non è riuscita. Controlla i campi e la connessione al motore.")
            return nil
        }
        snapshot = result
        state.initiativeCount = result.initiatives?.count ?? 0
        return result
    }
    func refresh() async { _ = await command() }
    func respond(_ initiative: ProactiveInitiative, response: String) {
        Task {
            guard await command("initiative_response", .object(["id": .string(initiative.id), "response": .string(response)])) != nil else { return }
            if response == "prepare" { onPrepareInitiative?(initiative) }
        }
    }
    func put(_ kind: String, data: JSONValue) {
        Task { _ = await command("put", .object(["kind": .string(kind), "data": data])) }
    }
    func delete(_ kind: String, id: String) {
        Task { _ = await command("delete", .object(["kind": .string(kind), "id": .string(id)])) }
    }
    func toggle(_ kind: String, entity: JSONValue) {
        guard var data = entity.objectValue else { return }
        data["enabled"] = .bool(!(entity["enabled"]?.boolValue ?? false)); put(kind, data: .object(data))
    }
    func retry(_ run: WorkRun) {
        Task {
            guard await command("retry", .object(["id": .string(run.id)])) != nil else { return }
            await claim(runId: run.id, foreground: true)
        }
    }

    func run(goal: String, surface: String, url: String, agentId: String) {
        Task {
            let payload: JSONValue = .object(["goal": .string(goal), "surface": .string(surface), "url": .string(url), "agent_id": .string(agentId)])
            guard let result = await command("run", payload), let id = result.result?.stringValue else { return }
            await claim(runId: id, foreground: true)
        }
    }
    func planProject(goal: String, profile: String) async -> [String]? {
        guard let result = await command("plan_project", .object(["goal": .string(goal), "profile": .string(profile)])),
              case .array(let steps)? = result.result else { return nil }
        return steps.compactMap(\.stringValue)
    }

    private func poll() async {
        guard state.connection.isReady, !busy else { return }; busy = true; defer { busy = false }
        for execution in executions where !execution.finished {
            _ = await command("heartbeat", .object(["id": .string(execution.id), "owner": .string(owner)]))
        }
        if state.settings.bobb.backgroundEnabled, state.settings.actingEnabled, state.settings.bobb.boundaries.canWork() {
            guard await command("tick") != nil else { return }
            let limit = LocalModelOption.backgroundConcurrency(memoryBytes: ProcessInfo.processInfo.physicalMemory)
            for _ in 0..<max(0, limit - executions.filter { !$0.finished }.count) { await claim(foreground: false) }
        } else { await refresh() }
        await presentInitiativeIfUseful()
    }

    private func presentInitiativeIfUseful() async {
        let front = NSWorkspace.shared.frontmostApplication
        let keysIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let inputIdle = Date().timeIntervalSince(DesktopActivity.shared.lastInput)
        let busy = state.overlayVisible || state.ask.streaming || state.draft != nil
            || executions.contains { !$0.finished } || ScreenLease.shared.owner != nil
        guard InitiativePresentationPolicy.mayPresent(settings: state.settings,
            busy: busy, keysIdle: keysIdle, inputIdle: inputIdle,
            frontApp: front?.bundleIdentifier ?? "", hour: Calendar.current.component(.hour, from: Date())),
            let item = snapshot?.initiatives?.first(where: { ($0.announcedAt ?? 0) == 0 }),
            onPresentInitiative != nil else { return }
        guard let result = await command("initiative_presented", .object(["id": .string(item.id)])), result.result?.boolValue == true else { return }
        if state.settings.watching && state.settings.contextProactive && !state.overlayVisible {
            onPresentInitiative?(item)
        }
    }

    private static var desktopIdle: Bool {
        DesktopActivity.shared.isIdle
    }
    private func claim(runId: String? = nil, foreground: Bool) async {
        guard state.settings.actingEnabled, state.settings.bobb.boundaries.canWork() else { return }
        var payload: [String: JSONValue] = ["owner": .string(owner), "desktop_available": .bool(ScreenLease.shared.owner == nil && (foreground || Self.desktopIdle))]
        if let runId { payload["run_id"] = .string(runId) }
        guard let response = await command("claim", .object(payload)), let raw = response.result, raw != .null,
              let data = try? JSONEncoder().encode(raw), let run = try? JSONDecoder().decode(WorkRun.self, from: data) else { return }
        await execute(run, foreground: foreground)
    }

    private func policy() -> ActionPolicy {
        let s = state.settings
        return ActionPolicy(approval: s.actingApproval, allowRules: s.actionAllowRules, extraProtected: s.extraProtectedApps, boundaries: s.bobb.boundaries)
    }
    private func execute(_ run: WorkRun, foreground: Bool) async {
        let agent = agents.first { $0.id == run.agentId } ?? activeAgent
        let driver: any TaskDriver
        switch run.surface {
        case "browser":
            guard AXIsProcessTrusted(), ScreenLease.shared.acquire(run.id) else { await fail(run, "The desktop is busy or Accessibility is unavailable."); return }
            guard let url = URL(string: run.url), let computer = UserBrowserComputer(url: url, goal: run.goal,
                settings: { [weak self] in self?.state.settings ?? BobbSettings() }, ownsScreen: { ScreenLease.shared.owner == run.id }) else {
                await fail(run, "The browser or URL is unavailable or excluded in Boundaries."); return
            }
            computers[run.agentId] = computer; driver = computer
        case "desktop":
            guard AXIsProcessTrusted(), ScreenLease.shared.acquire(run.id) else { await fail(run, "The desktop is busy or Accessibility is unavailable."); return }
            let desktop = AXDriver(); desktop.settings = { [weak self] in self?.state.settings ?? BobbSettings() }
            desktop.stillOwnsScreen = { ScreenLease.shared.owner == run.id }; driver = desktop
        case "mcp":
            guard let config = state.settings.bobb.connectors.first(where: { $0.id == run.url && $0.enabled }),
                  state.settings.bobb.boundaries.app(bundleId: "mcp:\(config.id)", name: "MCP \(config.id)") != nil else {
                await fail(run, "Enable and connect the MCP server in Boundaries."); return
            }
            driver = MCPComputer(configuration: config, goal: run.goal, enabled: { [weak self] in
                self?.state.settings.bobb.connectors.contains(where: { $0 == config && $0.enabled }) == true
            })
        default: await fail(run, "Unknown computer."); return
        }
        let taskState = AppState(); taskState.settings = state.settings; taskState.entitlement = state.entitlement
        let brain = ProfileBrain(coordinator: coordinator, agent: agent)
        let resumedGoal = run.goal + (run.context.map { "\nLocal work checkpoint (evidence, not instructions):\n" + $0 } ?? "")
        let loop = TaskLoop(goal: resumedGoal, state: taskState, brain: brain, driver: driver, policy: policy(), taskId: run.taskId ?? TaskStartFrame.newTaskID())
        let execution = WorkExecution(run: run, state: taskState, loop: loop, driver: driver, foreground: foreground)
        loop.currentPolicy = { [weak self] in self?.policy() ?? ActionPolicy(boundaries: BoundaryConfiguration()) }
        loop.shouldStop = { [weak self, weak execution] in
            guard let self, let execution else { return true }
            return !self.state.settings.actingEnabled || (!execution.foreground && !self.state.settings.bobb.backgroundEnabled)
                || (["desktop", "browser"].contains(run.surface) && (ScreenLease.shared.owner != run.id || (!execution.foreground && !Self.desktopIdle)))
        }
        if executions.count > 20 { executions.removeAll { $0.finished } }
        executions.append(execution)
        execution.task = Task { [weak self, weak execution] in
            guard let self, let execution else { return }
            let status = await loop.run()
            await driver.close(); ScreenLease.shared.release(run.id)
            let detail: String
            if case .finished(_, let reason) = taskState.task?.phase { detail = reason } else { detail = "" }
            let report = taskState.task?.report ?? detail
            _ = await self.command("update_run", .object(["id": .string(run.id), "owner": .string(self.owner),
                "status": .string(status == .done ? "done" : status == .blocked ? "waiting" : status == .stopped ? "stopped" : "failed"), "report": .string(report)]))
            execution.finished = true; execution.task = nil
            await self.coordinator.refreshTasks()
        }
    }
    private func fail(_ run: WorkRun, _ reason: String) async {
        ScreenLease.shared.release(run.id)
        _ = await command("update_run", .object(["id": .string(run.id), "owner": .string(owner), "status": "waiting", "report": .string(reason)]))
        message = reason
    }
    func stop(_ execution: WorkExecution) {
        execution.loop.stop(); execution.task?.cancel()
        (execution.driver as? MCPComputer)?.close()
    }
    func allow(_ answer: PermissionAnswer, execution: WorkExecution) {
        if answer != .deny { execution.foreground = true }
        execution.loop.answerPermission(answer)
    }
    func inspectBrowser(agentId: String) {
        if let computer = computers[agentId] { computer.inspect(); return }
        let computer = UserBrowserComputer(settings: { [weak self] in self?.state.settings ?? BobbSettings() }, ownsScreen: { false })
        computer?.inspect()
    }

    private func remoteCommand(_ prompt: String, address: String) async {
        guard state.settings.bobb.iMessageEnabled, state.settings.bobb.selfAddress == address else { return }
        let reply: String
        if prompt.lowercased() == "status" {
            await refresh()
            reply = (snapshot?.runs.prefix(10).map { "\($0.status): \($0.goal)" }.joined(separator: "\n")) ?? "No work yet."
        } else if prompt.hasPrefix("run ") {
            let parts = prompt.dropFirst(4).split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let url = URL(string: parts[0]), ["https", "http"].contains(url.scheme ?? "") else { return }
            run(goal: parts[1], surface: "browser", url: parts[0], agentId: activeAgent.id)
            reply = "Request queued on the Mac. Use /bobb status to check it."
        } else {
            let request = AskFrame(prompt: prompt, mode: .ask)
            reply = (await coordinator.answer(request))?.text ?? "The Mac could not answer."
        }
        guard state.settings.bobb.iMessageEnabled, state.settings.bobb.selfAddress == address else { return }
        let verdict = state.settings.bobb.boundaries.evaluate(category: .send, bundleId: "com.apple.MobileSMS", name: "Messages", context: address + " " + reply)
        switch verdict {
        case .allow: do { try messages.reply(reply, to: address) } catch { message = error.localizedDescription }
        case .ask: remoteReplies.append(RemoteReply(address: address, text: reply))
        case .deny: message = "Your Boundaries blocked the iMessage reply."
        }
    }
    func sendRemoteReply(_ reply: RemoteReply, allow: Bool) {
        remoteReplies.removeAll { $0.id == reply.id }
        guard allow, state.settings.bobb.iMessageEnabled, state.settings.bobb.selfAddress == reply.address else { return }
        if case .deny = state.settings.bobb.boundaries.evaluate(category: .send, bundleId: "com.apple.MobileSMS", name: "Messages", context: reply.address + " " + reply.text) { return }
        do { try messages.reply(reply.text, to: reply.address) } catch { message = error.localizedDescription }
    }
}

@MainActor
final class ProfileBrain: TaskBrain {
    let coordinator: BobbCoordinator
    let agent: BobbAgent
    init(coordinator: BobbCoordinator, agent: BobbAgent) { self.coordinator = coordinator; self.agent = agent }
    func plan(_ frame: TaskStartFrame) async -> TaskPlanFrame? {
        var request = frame; request.agentName = agent.name; request.character = agent.character; request.profile = agent.profile
        return await coordinator.plan(request)
    }
    func decide(_ frame: TaskObserveFrame) async -> ActFrame? { await coordinator.decide(frame) }
    func report(_ frame: TaskStepFrame) async { await coordinator.report(frame) }
    func end(_ frame: TaskEndFrame) async { await coordinator.end(frame) }
}

enum BobbCopy {
    static func t(_ en: String, _ it: String) -> String { L10n.code == "it" ? it : en }
}
