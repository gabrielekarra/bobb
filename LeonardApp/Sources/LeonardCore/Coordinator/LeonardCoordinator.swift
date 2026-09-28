import Foundation

/// Wires the event sources to one `IPCClient` and folds everything either
/// produces into `AppState`. This is the only place that knows both sides
/// exist; the menu bar, the overlay, Mind, the command bar, the draft panel
/// and the memory browser only ever look at `AppState` or call methods here.
///
/// Two kinds of traffic go through it. Fire-and-forget frames (events,
/// approvals, settings) are sent and their consequences arrive as state.
/// Request/response frames (memory search, stats) are awaited: `request`
/// sends a frame carrying an id and suspends until the frame answering that
/// id arrives, or a timeout — never forever, because the daemon may restart
/// mid-request.
@MainActor
public final class LeonardCoordinator {
    public let state: AppState
    public let client: IPCClient
    public let eventSource: EventSource

    /// Called whenever the user's settings change, to persist them and to
    /// reconfigure platform services (login item, hotkey, sensors).
    public var onSettingsChanged: ((LeonardSettings) -> Void)?
    /// Called for every screen-memory frame an app-side sensor produces.
    public var memorySink: ((MemoryObserveFrame) -> Void)?

    private var stateTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var housekeeping: Task<Void, Never>?
    private var waiting: [String: CheckedContinuation<IncomingFrame?, Never>] = [:]

    public init(state: AppState = AppState(), client: IPCClient, eventSource: EventSource) {
        self.state = state
        self.client = client
        self.eventSource = eventSource
    }

    public func start() {
        let client = client
        let state = state
        stateTask = Task { [weak self] in
            for await connectionState in client.states {
                state.connection = connectionState
                if case .ready = connectionState {
                    state.daemonStatus = nil
                    await self?.pushSettings()
                    await self?.refreshStats()
                }
                if case .connected = connectionState {
                    await self?.pushSettings()
                }
            }
        }
        frameTask = Task { [weak self] in
            for await frame in client.frames {
                self?.handle(frame)
            }
        }
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.eventSource.events {
                guard self.state.watching, self.state.entitlement.allowsAssistance else { continue }
                self.state.recordEvent(event)
                await self.client.send(event: event)
            }
        }
        housekeeping = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
                self?.state.expireForYou()
            }
        }
        eventSource.start()
        Task {
            await client.setLocale(L10n.code)
            await client.start()
        }
    }

    public func stop() {
        stateTask?.cancel()
        frameTask?.cancel()
        eventTask?.cancel()
        housekeeping?.cancel()
        eventSource.stop()
        for (_, continuation) in waiting { continuation.resume(returning: nil) }
        waiting.removeAll()
        Task { await client.stop() }
    }

    // MARK: Incoming

    func handle(_ frame: IncomingFrame) {
        if let id = frame.requestId, let continuation = waiting.removeValue(forKey: id) {
            continuation.resume(returning: frame)
        }
        switch frame {
        case .ready(let ready):
            state.daemonStatus = nil
            if ready.protocolVersion == nil {
                state.floor = ready.floor
            }
        case .status(let status):
            state.daemonStatus = status
        case .decision(let decision):
            state.recordDecision(decision)
        case .trace(let trace):
            state.recordTrace(trace)
        case .preparedDelta(let delta):
            state.applyPreparedDelta(delta)
        case .prepared(let prepared):
            state.applyPrepared(prepared)
        case .answerDelta(let delta):
            state.applyAnswerDelta(delta)
        case .answer(let answer):
            state.applyAnswer(answer)
        case .stats(let stats):
            state.stats = stats
        case .error(let error):
            state.applyError(error)
        case .memoryResults, .memoryDeleted, .memoryStats, .historyDeleted, .act, .unknown:
            break
        }
    }

    // MARK: Settings

    public func updateSettings(_ change: (inout LeonardSettings) -> Void) {
        var settings = state.settings
        change(&settings)
        guard settings != state.settings else { return }
        let languageChanged = settings.language != state.settings.language
        state.settings = settings
        if languageChanged {
            L10n.code = settings.language.code
            Task { await client.setLocale(L10n.code) }
        }
        onSettingsChanged?(settings)
        Task { await pushSettings() }
    }

    public func pushSettings() async {
        await client.send(.settings(state.settings.daemonFrame()))
    }

    public func setFloor(_ floor: Double) {
        updateSettings { $0.floor = floor }
    }

    public func setWatching(_ watching: Bool) {
        updateSettings { $0.watching = watching }
    }

    // MARK: Suggestions and drafts

    /// "Prepare": accept the suggestion and start writing, in the draft panel.
    public func approve(_ decision: DecisionFrame) {
        state.resolve(decision.id)
        if decision.suggestion != nil {
            state.beginDraft(for: decision)
        }
        Task { await client.sendApprove(decisionId: decision.id) }
    }

    public func dismiss(_ decision: DecisionFrame, reason: DismissReason = .user) {
        if reason == .user { state.resolve(decision.id) }
        Task { await client.sendDismiss(decisionId: decision.id, reason: reason) }
    }

    /// Rewrite the current draft, optionally as one of the quick variants
    /// (`accept`, `decline`, `more_time`, `ask_details`) or with free text.
    public func regenerate(instruction: String = "") {
        guard let session = state.draft else { return }
        if session.streaming {
            Task { await client.send(.cancel(CancelFrame(requestId: session.decision.id))) }
        }
        state.beginDraft(for: session.decision, instruction: instruction)
        Task { await client.send(.regenerate(RegenerateFrame(decisionId: session.decision.id, instruction: instruction))) }
    }

    public func closeDraft() {
        if let session = state.draft, session.streaming {
            Task { await client.send(.cancel(CancelFrame(requestId: session.decision.id))) }
        }
        state.draft = nil
    }

    // MARK: Command bar

    public func ask(prompt: String, mode: AskMode, selection: String = "", app: String = "", window: String = "") {
        guard state.entitlement.allowsAssistance else { return }
        if let previous = state.ask.requestId, state.ask.streaming {
            Task { await client.send(.cancel(CancelFrame(requestId: previous))) }
        }
        let frame = AskFrame(prompt: prompt, mode: mode, selection: selection, app: app, window: window)
        state.beginAsk(frame, mode: mode)
        let ipc = client
        Task { [weak self] in
            let sent = await ipc.send(.ask(frame))
            if !sent {
                self?.state.applyError(ErrorFrame(ts: Date().timeIntervalSince1970, detail: L10n.t(.askNotReady), requestId: frame.id))
            }
        }
    }

    public func cancelAsk() {
        guard let id = state.ask.requestId, state.ask.streaming else { return }
        state.ask.streaming = false
        Task { await client.send(.cancel(CancelFrame(requestId: id))) }
    }

    // MARK: Memory

    public func observe(_ frame: MemoryObserveFrame) {
        guard state.settings.memoryEnabled, state.watching, state.entitlement.allowsAssistance else { return }
        memorySink?(frame)
        Task { await client.send(.memoryObserve(frame)) }
    }

    public func searchMemory(_ query: String, app: String? = nil) async -> MemoryResultsFrame? {
        let id = RequestFrame.newID()
        let frame: OutgoingFrame = query.trimmingCharacters(in: .whitespaces).isEmpty
            ? .memoryRecent(MemoryRecentFrame(id: id, limit: 80, app: app))
            : .memorySearch(MemorySearchFrame(id: id, query: query, limit: 60, app: app))
        if case .memoryResults(let results)? = await request(frame, id: id) { return results }
        return nil
    }

    public func deleteMemory(_ frame: MemoryDeleteFrame) async -> Int? {
        if case .memoryDeleted(let deleted)? = await request(.memoryDelete(frame), id: frame.id) { return deleted.count }
        return nil
    }

    public func memoryStats() async -> MemoryStatsFrame? {
        let id = RequestFrame.newID()
        if case .memoryStats(let stats)? = await request(.memoryStats(RequestFrame(id: id)), id: id) { return stats }
        return nil
    }

    public func deleteHistory() async -> Int? {
        let id = RequestFrame.newID()
        guard case .historyDeleted(let deleted)? = await request(.historyDelete(RequestFrame(id: id)), id: id) else { return nil }
        state.reset()
        await refreshStats()
        return deleted.count
    }

    // MARK: Learning and stats

    public func refreshStats() async {
        let id = RequestFrame.newID()
        _ = await request(.stats(RequestFrame(id: id)), id: id)
    }

    public func forget(ruleId: String) {
        let frame = LearningForgetFrame(ruleId: ruleId)
        Task { _ = await request(.learningForget(frame), id: frame.id) }
    }

    public func mute(sender: String) {
        let frame = LearningMuteFrame(sender: sender)
        Task { _ = await request(.learningMute(frame), id: frame.id) }
    }

    /// Ask the daemon to look for the model again, after a download.
    public func reloadModel() {
        Task { await client.send(.reload(RequestFrame())) }
    }

    // MARK: Request plumbing

    func request(_ frame: OutgoingFrame, id: String, timeout: Double = 8) async -> IncomingFrame? {
        let sent = await client.send(frame)
        guard sent else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<IncomingFrame?, Never>) in
            waiting[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.timeOut(id)
            }
        }
    }

    private func timeOut(_ id: String) {
        waiting.removeValue(forKey: id)?.resume(returning: nil)
    }
}
