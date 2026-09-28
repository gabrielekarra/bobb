import Foundation
import Testing
@testable import LeonardCore

// MARK: - Elements

private func el(_ key: Int, _ role: String, title: String = "", description: String = "", value: String = "",
                placeholder: String = "", subrole: String = "", enabled: Bool = true, focused: Bool = false,
                frame: ScreenRect? = ScreenRect(x: 10, y: 10, width: 80, height: 20), actions: [String] = [],
                context: [String] = [], menuPath: [String] = []) -> UIElementSnapshot {
    UIElementSnapshot(key: key, role: role, subrole: subrole, title: title, description: description, value: value,
                      placeholder: placeholder, enabled: enabled, focused: focused, frame: frame, actions: actions,
                      context: context, menuPath: menuPath)
}

@Suite struct ElementTests {
    @Test func classifiesByRoleAndNeverOffersSecureFields() {
        #expect(ElementClassifier.kind(of: el(1, "AXButton", title: "Play")) == .press)
        #expect(ElementClassifier.kind(of: el(2, "AXTextField", placeholder: "Search")) == .text)
        #expect(ElementClassifier.kind(of: el(3, "AXTextField", subrole: "AXSecureTextField")) == nil)
        #expect(ElementClassifier.kind(of: el(4, "AXSecureTextField")) == nil)
        #expect(ElementClassifier.kind(of: el(5, "AXScrollArea")) == .scroll)
        #expect(ElementClassifier.kind(of: el(6, "AXStaticText", value: "Hello")) == nil)
        #expect(ElementClassifier.kind(of: el(7, "AXImage", actions: ["AXPress"])) == .press)
        #expect(ElementClassifier.kind(of: el(8, "AXGroup", subrole: "AXSearchField")) == .text)
    }

    @Test func labelsReadLikeAPersonWould() {
        #expect(ElementClassifier.label(of: el(1, "AXButton", description: "Play")) == "Play")
        #expect(ElementClassifier.label(of: el(2, "AXTextField", value: "typed", placeholder: "What do you want to play?"))
                == "What do you want to play?")
        #expect(ElementClassifier.label(of: el(3, "AXMenuItem", title: "New Window", frame: nil, menuPath: ["File"])) == "File › New Window")
        #expect(ElementClassifier.label(of: el(4, "AXRow", value: "Focus Flow")) == "Focus Flow")
        #expect(ElementClassifier.roleName(el(5, "AXTextField", subrole: "AXSearchField")) == "search field")
        #expect(ElementClassifier.place(of: el(6, "AXButton", title: "x", context: ["Toolbar", "Sidebar"])) == "Sidebar")
    }

    @Test func tokensFoldAccentsAndDropFillers() {
        #expect(Tokens.words("Metti la playlist «Città» per favore") == ["metti", "playlist", "citta"])
        #expect(Tokens.words("Open the Focus playlist on Spotify") == ["open", "focus", "playlist", "spotify"])
    }
}

// MARK: - Ranking

@Suite struct RankerTests {
    let elements: [UIElementSnapshot] = [
        el(1, "AXButton", title: "Home", context: ["Sidebar"]),
        el(2, "AXButton", title: "Search", context: ["Sidebar"]),
        el(3, "AXTextField", placeholder: "What do you want to play?", focused: true),
        el(4, "AXRow", value: "Focus Flow", frame: ScreenRect(x: 10, y: 300, width: 300, height: 40)),
        el(5, "AXRow", value: "Daily Mix 1", frame: ScreenRect(x: 10, y: 340, width: 300, height: 40)),
        el(6, "AXMenuItem", title: "Quit Spotify", frame: nil, menuPath: ["Spotify"]),
        el(7, "AXMenuItem", title: "Focus Mode", frame: nil, menuPath: ["View"]),
        el(8, "AXButton", title: "Search", context: ["Sidebar"]),
        el(9, "AXButton", title: "Hidden", frame: ScreenRect(x: 0, y: 0, width: 0, height: 0)),
        el(10, "AXButton"),
    ]

    @Test func wordsFromTheRequestComeFirst() {
        let ranked = CandidateRanker().rank(elements, goal: "Play my Focus playlist")
        #expect(ranked[.press]?.first?.label == "Focus Flow")
        #expect(ranked[.text]?.first?.element.key == 3)
    }

    @Test func menuItemsOnlyWhenTheyMatch() {
        let labels = CandidateRanker().rank(elements, goal: "Play my Focus playlist")[.press]!.map(\.label)
        #expect(labels.contains("View › Focus Mode"))
        #expect(!labels.contains("Spotify › Quit Spotify"))
    }

    @Test func duplicatesCollapseAndUnlabelledButtonsDrop() {
        let labels = CandidateRanker().rank(elements, goal: "search")[.press]!.map(\.label)
        #expect(labels.filter { $0 == "Search" }.count == 1)
        #expect(!labels.contains(""))
        #expect(labels.last == "Hidden")
    }

    @Test func limitsAreRespected() {
        let many = (1...80).map { el($0, "AXButton", title: "Button \($0)") }
        let ranked = CandidateRanker(limits: .init(press: 5, text: 2, scroll: 1)).rank(many, goal: "anything")
        #expect(ranked[.press]?.count == 5)
    }

    @Test func tableIdsAreFreshPerObservationAndMapBack() {
        let ranked = CandidateRanker().rank(elements, goal: "focus")
        let table = CandidateTable(ranked: ranked, observation: 7)
        #expect(table.candidates.allSatisfy { $0.id.hasPrefix("o7e") })
        let first = table.candidates[0]
        #expect(table.keys[first.id] != nil)
        #expect(table.digest == CandidateTable(ranked: ranked, observation: 8).digest)
    }
}

// MARK: - Permissions

@Suite struct PolicyTests {
    let policy = ActionPolicy()

    @Test func consequencesAsk() {
        #expect(policy.evaluate(operation: .click, label: "Send", role: "button", appBundleId: "com.apple.mail", appName: "Mail")
                == .ask(reason: "sends"))
        #expect(policy.evaluate(operation: .click, label: "Elimina conversazione", role: "button", appBundleId: "x", appName: "X")
                == .ask(reason: "deletes"))
        #expect(policy.evaluate(operation: .click, label: "Buy now", role: "button", appBundleId: "x", appName: "X")
                == .ask(reason: "pays"))
        #expect(policy.evaluate(operation: .click, label: "Don’t Save", role: "button", appBundleId: "x", appName: "X")
                == .ask(reason: "closesWithoutSaving"))
    }

    @Test func harmlessStepsAreAllowedAndWordsMustBeWhole() {
        #expect(policy.evaluate(operation: .click, label: "Play", role: "button", appBundleId: "x", appName: "X") == .allow)
        #expect(policy.evaluate(operation: .click, label: "Sender details", role: "button", appBundleId: "x", appName: "X") == .allow)
        #expect(policy.evaluate(operation: .type, label: "Search", role: "search field", appBundleId: "com.spotify.client",
                                appName: "Spotify", submit: true) == .allow)
    }

    @Test func returnInAMessageBoxAsks() {
        #expect(policy.evaluate(operation: .type, label: "Message", role: "text area", appBundleId: "com.tinyspeck.slackmacgap",
                                appName: "Slack", submit: true) == .ask(reason: "sendsMessage"))
        #expect(policy.evaluate(operation: .type, label: "Body", role: "text area", appBundleId: "x", appName: "X",
                                submit: true, multiline: true) == .ask(reason: "sendsMessage"))
        #expect(policy.evaluate(operation: .type, label: "Message", role: "text area", appBundleId: "com.tinyspeck.slackmacgap",
                                appName: "Slack", submit: false) == .allow)
    }

    @Test func terminalsAlwaysAsk() {
        #expect(policy.evaluate(operation: .type, label: "shell", role: "text area", appBundleId: "com.apple.Terminal", appName: "Terminal")
                == .ask(reason: "runsCommand"))
    }

    @Test func protectedAppsAndSecureFieldsAreDenied() {
        #expect(policy.evaluate(operation: .click, label: "Play", role: "button", appBundleId: "com.1password.1password", appName: "1Password")
                == .deny(reason: "protected"))
        #expect(policy.evaluate(operation: .click, label: "OK", role: "button", appBundleId: "com.apple.systempreferences", appName: "System Settings")
                == .deny(reason: "protected"))
        #expect(policy.evaluate(operation: .type, label: "Password", role: "text field", appBundleId: "x", appName: "X", secure: true)
                == .deny(reason: "secure"))
    }

    @Test func everyStepModeAndAlwaysAllowRules() {
        var strict = ActionPolicy(approval: .everyStep)
        #expect(strict.evaluate(operation: .click, label: "Play", role: "button", appBundleId: "x", appName: "X") == .ask(reason: "everyStep"))
        strict.allowRules.insert(ActionAllowRule(app: "x", operation: "CLICK", label: "Play"))
        #expect(strict.evaluate(operation: .click, label: "Play", role: "button", appBundleId: "x", appName: "X") == .allow)
        let rule = ActionPolicy(allowRules: [ActionAllowRule(app: "com.apple.mail", operation: "CLICK", label: "Send")])
        #expect(rule.evaluate(operation: .click, label: "Send", role: "button", appBundleId: "com.apple.mail", appName: "Mail") == .allow)
    }
}

// MARK: - The loop

@MainActor
final class FakeDriver: TaskDriver {
    var screens: [ScreenObservation]
    var performed: [DriverAction] = []
    var results: [DriverResult] = []
    var undos = 0

    init(screens: [ScreenObservation]) {
        self.screens = screens
    }

    func observe() async -> ScreenObservation? {
        screens.count > 1 ? screens.removeFirst() : screens.first
    }

    func installedApps() -> [String] { ["Spotify", "Music", "Mail", "Numbers"] }

    func perform(_ action: DriverAction) async -> DriverResult {
        performed.append(action)
        return results.isEmpty ? .ok : results.removeFirst()
    }

    func settle() async {}

    func undoLast() async -> Bool {
        undos += 1
        return true
    }
}

@MainActor
final class FakeBrain: TaskBrain {
    var verdicts: [(TaskObserveFrame) -> ActFrame?]
    var observed: [TaskObserveFrame] = []
    var steps: [TaskStepFrame] = []
    var ended: [TaskEndFrame] = []
    var planned: [TaskStartFrame] = []

    init(_ verdicts: [(TaskObserveFrame) -> ActFrame?]) {
        self.verdicts = verdicts
    }

    func plan(_ frame: TaskStartFrame) async -> TaskPlanFrame? {
        planned.append(frame)
        return TaskPlanFrame(ts: 0, requestId: frame.id, taskId: frame.taskId, goal: frame.goal, steps: ["Open Spotify", "Play Focus"])
    }

    func decide(_ frame: TaskObserveFrame) async -> ActFrame? {
        observed.append(frame)
        return verdicts.isEmpty ? nil : verdicts.removeFirst()(frame)
    }

    func report(_ frame: TaskStepFrame) async { steps.append(frame) }
    func end(_ frame: TaskEndFrame) async { ended.append(frame) }
}

private func act(_ operation: ActOperation, _ pick: @escaping (TaskObserveFrame) -> String = { _ in "" }, text: String? = nil,
                 submit: Bool = false, why: String = "") -> (TaskObserveFrame) -> ActFrame? {
    { frame in
        ActFrame(ts: 0, observationId: frame.id, operation: operation, candidateId: pick(frame), confidence: 0.9, schemaMass: 0.99,
                 text: text, latencyMs: 5, why: why, taskId: frame.taskId, submit: submit)
    }
}

private func candidate(_ label: String) -> (TaskObserveFrame) -> String {
    { frame in frame.candidates.first(where: { $0.label == label })?.id ?? frame.apps.first(where: { $0.label == label })?.id ?? "missing" }
}

private let finder = ScreenObservation(app: "Finder", bundleId: "com.apple.finder", window: "Downloads", elements: [])
private let spotify = ScreenObservation(app: "Spotify", bundleId: "com.spotify.client", window: "Spotify", elements: [
    el(1, "AXTextField", placeholder: "What do you want to play?"),
    el(2, "AXRow", value: "Focus Flow"),
    el(3, "AXButton", title: "Delete playlist"),
])

@MainActor
@Suite struct TaskLoopTests {
    @Test func aTaskRunsToDone() async {
        let state = AppState()
        let driver = FakeDriver(screens: [finder, finder, spotify, spotify, spotify])
        let brain = FakeBrain([
            act(.openApp, candidate("Spotify")),
            act(.type, candidate("What do you want to play?"), text: "Focus", submit: true),
            act(.click, candidate("Focus Flow")),
            act(.done, why: "playing"),
        ])
        let loop = TaskLoop(goal: "Play my Focus playlist on Spotify", state: state, brain: brain, driver: driver, policy: ActionPolicy())
        let status = await loop.run()

        #expect(status == .done)
        #expect(driver.performed == [.openApp(name: "Spotify"), .type(key: 1, text: "Focus", submit: true), .press(key: 2)])
        #expect(brain.planned.first?.apps == ["Spotify", "Music", "Mail", "Numbers"])
        #expect(brain.steps.map(\.outcome) == [.ok, .ok, .ok])
        #expect(brain.steps.map(\.target) == ["Spotify", "What do you want to play?", "Focus Flow"])
        #expect(brain.ended.first?.status == .done)
        #expect(state.task?.status == .done)
        #expect(state.task?.plan == ["Open Spotify", "Play Focus"])
        #expect(state.task?.steps.count == 3)
    }

    @Test func appsOfferedAreTheOnesTheRequestNames() async {
        let apps = TaskLoop.appCandidates(["Spotify", "Music", "Mail", "Numbers"], goal: "metti Focus su Spotify", current: "Finder")
        #expect(apps.map(\.label) == ["Spotify"])
        #expect(TaskLoop.appCandidates(["Spotify"], goal: "Spotify", current: "Spotify").isEmpty)
    }

    @Test func aConsequentialStepWaitsForTheUser() async {
        let state = AppState()
        let driver = FakeDriver(screens: [spotify, spotify, spotify])
        let brain = FakeBrain([act(.click, candidate("Delete playlist")), act(.done)])
        let loop = TaskLoop(goal: "Delete the playlist", state: state, brain: brain, driver: driver, policy: ActionPolicy())
        let run = Task { await loop.run() }
        for _ in 0..<200 {
            if case .waitingForPermission = state.task?.phase { break }
            await Task.yield()
        }
        guard case .waitingForPermission(let request) = state.task?.phase else {
            Issue.record("never asked")
            return
        }
        #expect(request.label == "Delete playlist")
        #expect(request.reason == "deletes")
        #expect(driver.performed.isEmpty)
        loop.answerPermission(.allowOnce)
        #expect(await run.value == .done)
        #expect(driver.performed == [.press(key: 3)])
        #expect(brain.steps.first?.permission == "asked")
    }

    @Test func declinedPermissionStopsWithoutActing() async {
        let state = AppState()
        let driver = FakeDriver(screens: [spotify, spotify])
        let brain = FakeBrain([act(.click, candidate("Delete playlist"))])
        let loop = TaskLoop(goal: "Delete it", state: state, brain: brain, driver: driver, policy: ActionPolicy())
        let run = Task { await loop.run() }
        for _ in 0..<200 {
            if case .waitingForPermission = state.task?.phase { break }
            await Task.yield()
        }
        loop.answerPermission(.deny)
        #expect(await run.value == .stopped)
        #expect(driver.performed.isEmpty)
        #expect(brain.steps.first?.outcome == .denied)
    }

    @Test func alwaysAllowIsRememberedForNextTime() async {
        let state = AppState()
        let driver = FakeDriver(screens: [spotify, spotify, spotify])
        let brain = FakeBrain([act(.click, candidate("Delete playlist")), act(.click, candidate("Delete playlist")), act(.done)])
        let loop = TaskLoop(goal: "Delete", state: state, brain: brain, driver: driver, policy: ActionPolicy())
        var saved: [ActionAllowRule] = []
        loop.onAllowAlways = { saved.append($0) }
        let run = Task { await loop.run() }
        for _ in 0..<200 {
            if case .waitingForPermission = state.task?.phase { break }
            await Task.yield()
        }
        loop.answerPermission(.allowAlways)
        #expect(await run.value == .done)
        #expect(driver.performed.count == 2)
        #expect(saved == [ActionAllowRule(app: "com.spotify.client", operation: "CLICK", label: "Delete playlist")])
    }

    @Test func protectedAppsStopTheTask() async {
        let state = AppState()
        let vault = ScreenObservation(app: "1Password", bundleId: "com.1password.1password", window: "Vault", elements: [el(1, "AXButton", title: "Copy")])
        let brain = FakeBrain([act(.click, candidate("Copy"))])
        let loop = TaskLoop(goal: "copy my password", state: state, brain: brain, driver: FakeDriver(screens: [vault, vault]), policy: ActionPolicy())
        #expect(await loop.run() == .blocked)
        #expect(brain.observed.isEmpty)
    }

    @Test func aVerdictNamingSomethingNotOfferedIsNotExecuted() async {
        let state = AppState()
        let driver = FakeDriver(screens: [spotify, spotify, spotify, spotify])
        let brain = FakeBrain([act(.click) { _ in "o99e1" }, act(.type, candidate("Focus Flow"), text: "x"), act(.done)])
        let loop = TaskLoop(goal: "x", state: state, brain: brain, driver: driver, policy: ActionPolicy())
        #expect(await loop.run() == .done)
        #expect(driver.performed.isEmpty)
        #expect(brain.steps.map(\.outcome) == [.failed, .failed])
    }

    @Test func stopEndsTheTask() async {
        let state = AppState()
        let driver = FakeDriver(screens: [spotify])
        let brain = FakeBrain([])
        let loop = TaskLoop(goal: "x", state: state, brain: brain, driver: driver, policy: ActionPolicy())
        loop.stop()
        #expect(await loop.run() == .stopped)
        #expect(brain.ended.first?.status == .stopped)
    }

    @Test func noAnswerFromTheEngineFails() async {
        let state = AppState()
        let loop = TaskLoop(goal: "x", state: state, brain: FakeBrain([]), driver: FakeDriver(screens: [spotify]), policy: ActionPolicy())
        #expect(await loop.run() == .failed)
    }

    @Test func undoMarksTheLastStepUndone() async {
        let state = AppState()
        let driver = FakeDriver(screens: [spotify, spotify, spotify])
        let brain = FakeBrain([act(.click, candidate("Focus Flow")), act(.done)])
        let loop = TaskLoop(goal: "focus", state: state, brain: brain, driver: driver, policy: ActionPolicy())
        #expect(await loop.run() == .done)
        #expect(state.task?.canUndo == true)
        await loop.undoLast()
        #expect(driver.undos == 1)
        #expect(state.task?.steps.last?.outcome == .undone)
        #expect(state.task?.canUndo == false)
        #expect(brain.steps.last?.outcome == .undone)
    }

    @Test func waitingTooLongBlocks() async {
        let state = AppState()
        let brain = FakeBrain(Array(repeating: act(.wait), count: 10))
        let loop = TaskLoop(goal: "x", state: state, brain: brain, driver: FakeDriver(screens: [spotify]), policy: ActionPolicy())
        loop.waitDelay = 0
        #expect(await loop.run() == .blocked)
    }
}

// MARK: - Frames

@Suite struct TaskFrameTests {
    @Test func observeEncodesTheWireShape() throws {
        let frame = TaskObserveFrame(ts: 1, id: "obs_1", taskId: "task_1", step: 2, app: "Spotify", window: "W", digest: "d",
                                     candidates: [AgentCandidate(id: "o2e1", label: "Play", role: "button", kind: .press, where: "toolbar")],
                                     apps: [AppCandidate(id: "app1", label: "Music")])
        let data = try OutgoingFrame.taskObserve(frame).encoded()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["t"] as? String == "observe")
        #expect(json["task_id"] as? String == "task_1")
        let candidate = (json["candidates"] as! [[String: Any]])[0]
        #expect(candidate["kind"] as? String == "press")
        #expect(candidate["where"] as? String == "toolbar")
    }

    @Test func actAndPlanDecode() throws {
        let act = try IncomingFrame.decode(from: Data(#"{"t":"act","ts":1,"observation_id":"obs_1","task_id":"task_1","operation":"OPEN_APP","candidate_id":"app1","target_label":"Spotify","confidence":0.9,"schema_mass":0.99,"operation_probabilities":{},"probabilities":{},"text":null,"submit":false,"latency_ms":12,"abstained":false,"why":"open"}"#.utf8))
        guard case .act(let frame) = act else { Issue.record("not act"); return }
        #expect(frame.operation == .openApp)
        #expect(frame.targetLabel == "Spotify")
        #expect(act.requestId == "obs_1")

        let plan = try IncomingFrame.decode(from: Data(#"{"t":"task.plan","ts":1,"request_id":"r1","task_id":"task_1","goal":"g","steps":["a","b"]}"#.utf8))
        #expect(plan.requestId == "r1")
    }

    @Test func askCanRouteAndDoIsNeverSentAsAMode() throws {
        let frame = AskFrame(prompt: "metti Focus", mode: .act, route: true)
        #expect(frame.mode == "ask")
        #expect(frame.route)
    }
}

// MARK: - Conversations

@Suite struct ConversationTests {
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func openingAConversationIsAnEventWithItsLatestLines() {
        var tracker = ConversationTracker()
        let event = tracker.observe(app: "Slack", bundleId: "com.tinyspeck.slackmacgap",
                                    window: "Giulia Bianchi (DM) - Studio Rossi - Slack",
                                    text: "Giulia Bianchi 10:41\nHai visto il preventivo?\nGiulia Bianchi 10:42\nMi confermi entro stasera?",
                                    now: start)
        #expect(event?.kind == .messageOpened)
        #expect(event?.payload.fields["sender"] == .string("Giulia Bianchi (DM)"))
        #expect(event?.payload.fields["subject"] == .string("Slack: Giulia Bianchi (DM)"))
        #expect(event?.payload.fields["new"] == .bool(false))
    }

    @Test func onlyNewLinesCountAndNotTooOften() {
        var tracker = ConversationTracker()
        let chat = "com.tinyspeck.slackmacgap"
        _ = tracker.observe(app: "Slack", bundleId: chat, window: "Giulia", text: "Ciao\nCome va?", now: start)
        #expect(tracker.observe(app: "Slack", bundleId: chat, window: "Giulia", text: "Ciao\nCome va?", now: start + 30) == nil)
        let fresh = tracker.observe(app: "Slack", bundleId: chat, window: "Giulia", text: "Ciao\nCome va?\nMi mandi il file?", now: start + 40)
        #expect(fresh?.payload.fields["body"] == .string("Mi mandi il file?"))
        #expect(fresh?.payload.fields["new"] == .bool(true))
        // Within the gap: held, not lost.
        #expect(tracker.observe(app: "Slack", bundleId: chat, window: "Giulia", text: "Ciao\nCome va?\nMi mandi il file?\nGrazie", now: start + 45) == nil)
        let later = tracker.observe(app: "Slack", bundleId: chat, window: "Giulia", text: "Ciao\nCome va?\nMi mandi il file?\nGrazie", now: start + 70)
        #expect(later?.payload.fields["body"] == .string("Grazie"))
    }

    @Test func notWhileTypingNotOutsideChatAppsAndNotAgainSoon() {
        var tracker = ConversationTracker()
        #expect(tracker.observe(app: "Safari", bundleId: "com.apple.Safari", window: "Docs", text: "Hello there", now: start) == nil)
        let chat = "net.whatsapp.WhatsApp"
        #expect(tracker.observe(app: "WhatsApp", bundleId: chat, window: "WhatsApp", text: "Marco\nci vediamo alle 5?", now: start) != nil)
        #expect(tracker.observe(app: "WhatsApp", bundleId: chat, window: "WhatsApp", text: "Marco\nci vediamo alle 5?\nok", typing: true, now: start + 60) == nil)
        _ = tracker.observe(app: "Slack", bundleId: "com.tinyspeck.slackmacgap", window: "general", text: "news of the day", now: start + 70)
        // Back to WhatsApp within ten minutes: nothing new, no event.
        #expect(tracker.observe(app: "WhatsApp", bundleId: chat, window: "WhatsApp", text: "Marco\nci vediamo alle 5?", now: start + 80) == nil)
        #expect(ConversationTracker.conversationName(window: "WhatsApp", app: "WhatsApp") == "")
    }

    @Test func chatIsAProactiveKindByDefault() {
        #expect(LeonardSettings().proactiveKinds.contains("message.opened"))
        var settings = LeonardSettings()
        settings.chatProactive = false
        #expect(!settings.proactiveKinds.contains("message.opened"))
    }
}
