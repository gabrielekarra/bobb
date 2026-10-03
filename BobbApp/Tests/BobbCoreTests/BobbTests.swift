import Foundation
import Testing
@testable import BobbCore

@Test func aMixedActionMustRespectEveryBoundary() {
    var boundaries = BoundaryConfiguration()
    boundaries.apps = [AppBoundary(id: "shop", name: "Shop", actions: ["send": .allow, "pay": .deny])]
    let policy = ActionPolicy(boundaries: boundaries)
    #expect(policy.evaluate(operation: .click, label: "Confirm purchase", role: "AXButton", appBundleId: "shop", appName: "Shop") == .deny(reason: "boundary:pay"))
    #expect(BobbSettings().daemonFrame().connectedApps == nil)
}

@Test func macAppsAreAutomaticallyAvailableWithConsequentialActionsReviewed() {
    let settings = BobbSettings()
    #expect(!settings.bobb.backgroundEnabled)
    #expect(!settings.bobb.iMessageEnabled)
    #expect(settings.bobb.boundaries.apps.isEmpty)
    let policy = ActionPolicy(boundaries: settings.bobb.boundaries)
    #expect(policy.evaluate(operation: .click, label: "Search", role: "AXButton", appBundleId: "com.apple.Safari", appName: "Safari") == .allow)
    #expect(policy.evaluate(operation: .openApp, label: "Notes", role: "application", appBundleId: "com.apple.Notes", appName: "Notes") == .allow)
    #expect(policy.evaluate(operation: .click, label: "Send", role: "AXButton", appBundleId: "com.apple.mail", appName: "Mail") == .ask(reason: "boundary:send"))
    #expect(policy.evaluate(operation: .click, label: "Pay", role: "AXButton", appBundleId: "com.apple.Safari", appName: "Safari") == .ask(reason: "boundary:pay"))
    #expect(policy.evaluate(operation: .click, label: "Delete", role: "AXButton", appBundleId: "com.apple.Notes", appName: "Notes") == .ask(reason: "boundary:delete"))
    #expect(policy.evaluate(operation: .click, label: "Publish", role: "AXButton", appBundleId: "com.apple.Safari", appName: "Safari") == .ask(reason: "boundary:publish"))
    #expect(policy.evaluate(operation: .click, label: "Open", role: "AXButton", appBundleId: "com.apple.Passwords", appName: "Passwords") == .deny(reason: "protected"))
    #expect(settings.bobb.boundaries.app(bundleId: "mcp:unknown", name: "MCP unknown") == nil)
}

@Test func exclusionsOverrideAppRulesAndReachTheDaemon() throws {
    var settings = BobbSettings()
    settings.bobb.boundaries.apps = [AppBoundary(id: "com.apple.mail", name: "Mail", actions: ["send": .allow])]
    settings.bobb.boundaries.excludedApps = ["com.apple.mail", "Notes"]
    settings.extraProtectedApps = ["Private App"]
    let policy = ActionPolicy(boundaries: settings.bobb.boundaries)
    #expect(policy.evaluate(operation: .click, label: "Send", role: "AXButton", appBundleId: "com.apple.mail", appName: "Mail") == .deny(reason: "unavailableApp"))
    #expect(settings.bobb.boundaries.app(bundleId: "com.apple.Notes", name: "Notes") == nil)
    #expect(Set(settings.daemonFrame().extraProtectedApps) == ["com.apple.mail", "Notes", "Private App"])
    #expect(try JSONDecoder().decode(BobbSettings.self, from: JSONEncoder().encode(settings)) == settings)
    let wire = try OutgoingFrame.settings(settings.daemonFrame()).encoded()
    #expect(String(decoding: wire, as: UTF8.self).contains("\"connected_apps\":null"))
}

@Test func browserExclusionsCannotBeBypassedByDefaultAccess() {
    var boundaries = BoundaryConfiguration()
    #expect(boundaries.webApp(host: "example.test")?.id == "bobb.browser")
    boundaries.apps = [AppBoundary(id: "web:example.test", name: "example.test", actions: ["send": .deny])]
    #expect(boundaries.webApp(host: "example.test")?.mode(.send) == .deny)
    boundaries.excludedApps = ["web:example.test"]
    #expect(boundaries.webApp(host: "example.test") == nil)
    #expect(boundaries.webApp(host: "other.test") != nil)
    boundaries.excludedApps = ["bobb.browser"]
    #expect(boundaries.webApp(host: "example.test") == nil)
    #expect(boundaries.webApp(host: "other.test") == nil)
}

@Test func explicitDenyOverridesOldAlwaysAllowRules() {
    var boundaries = BoundaryConfiguration()
    boundaries.apps = [AppBoundary(id: "mail", name: "Mail", actions: ["send": .deny])]
    let rule = ActionAllowRule(app: "mail", operation: "CLICK", label: "Send")
    let policy = ActionPolicy(allowRules: [rule], boundaries: boundaries)
    #expect(policy.evaluate(operation: .click, label: "Send", role: "AXButton", appBundleId: "mail", appName: "Mail") == .deny(reason: "boundary:send"))
}

@Test func boundaryModesApplyToConsequencesAndProtectedFieldsStayDenied() {
    var boundaries = BoundaryConfiguration()
    boundaries.apps = [AppBoundary(id: "shop", name: "Shop", actions: ["pay": .allow, "delete": .deny])]
    let policy = ActionPolicy(boundaries: boundaries)
    #expect(policy.evaluate(operation: .click, label: "Pay", role: "AXButton", appBundleId: "shop", appName: "Shop") == .allow)
    #expect(policy.evaluate(operation: .click, label: "Delete", role: "AXButton", appBundleId: "shop", appName: "Shop") == .deny(reason: "boundary:delete"))
    #expect(policy.evaluate(operation: .type, label: "Password", role: "AXSecureTextField", appBundleId: "shop", appName: "Shop", secure: true) == .deny(reason: "secure"))
}

@Test func naturalRulesOnlyConstrainAndResolveKnownPeople() {
    var boundaries = BoundaryConfiguration()
    boundaries.apps = [AppBoundary(id: "mail", name: "Mail", actions: ["send": .allow])]
    boundaries.rules = ["non scrivere mai al mio capo senza chiedermelo"]
    boundaries.people = ["capo": ["Marco Rossi", "marco@firm.test"]]
    #expect(boundaries.evaluate(category: .send, bundleId: "mail", name: "Mail", context: "To Marco Rossi") == .ask(reason: "boundary:send"))
    #expect(boundaries.evaluate(category: .send, bundleId: "mail", name: "Mail", context: "To Anna") == .ask(reason: "boundary:send"))
    boundaries.rules = ["never delete anything"]
    #expect(boundaries.evaluate(category: .delete, bundleId: "mail", name: "Mail", context: "") == .deny(reason: "boundary:delete"))
    boundaries.rules = ["an unsupported constraint"]
    #expect(boundaries.evaluate(category: .send, bundleId: "mail", name: "Mail", context: "") == .ask(reason: "boundary:send"))
}

@Test func workingHoursWrapMidnightAndEqualHoursBlockAllDay() {
    var boundaries = BoundaryConfiguration(); boundaries.hoursEnabled = true
    boundaries.fromHour = 20; boundaries.toHour = 8
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = Date(timeIntervalSince1970: 23 * 3600)
    #expect(boundaries.canWork(at: date, calendar: calendar))
    #expect(!boundaries.canWork(at: Date(timeIntervalSince1970: 12 * 3600), calendar: calendar))
    boundaries.toHour = 20
    #expect(!boundaries.canWork(at: date, calendar: calendar))
}

@Test func webReturnAndToolExecutionAreConsequential() {
    #expect(ActionPolicy.category(operation: .key, label: "Return", app: "bobb.browser", submit: false, key: .returnKey, defaultButton: "") == .send)
    #expect(ActionPolicy.category(operation: .click, label: "Execute send_mail", app: "mcp:mail", submit: false, key: nil, defaultButton: "") == .execute)
    #expect(ActionPolicy.category(operation: .click, label: "Prenota", app: "bobb.browser", submit: false, key: nil, defaultButton: "") == .send)
}

@Test func largerModelRecommendationKeepsHeadroom() {
    #expect(LocalModelOption.recommended(memoryBytes: 8 * 1_073_741_824).minimumMemoryGB == 16)
    #expect(LocalModelOption.recommended(memoryBytes: 16 * 1_073_741_824).parameters == "4B")
    #expect(LocalModelOption.recommended(memoryBytes: 24 * 1_073_741_824).parameters == "7–8B")
    #expect(LocalModelOption.backgroundConcurrency(memoryBytes: 16 * 1_073_741_824) == 1)
    #expect(LocalModelOption.backgroundConcurrency(memoryBytes: 32 * 1_073_741_824) == 3)
    #expect(LocalModelOption.recommended(memoryBytes: 64 * 1_073_741_824).parameters == "30–32B")
}

@Test func workspaceWireContractDecodesWithoutOptionalResultOrOwner() throws {
    let data = Data(#"{"t":"bobb.state","request_id":"w","agents":[{"id":"bobb","name":"Bobb","character":"concise","profile":"general"}],"jobs":[],"projects":[],"routines":[],"runs":[]}"#.utf8)
    let frame = try IncomingFrame.decode(from: data)
    if case .workspace(let state) = frame { #expect(state.requestId == "w"); #expect(state.agents[0].name == "Bobb") }
    else { Issue.record("workspace frame was ignored") }
    let encoded = try OutgoingFrame.workspace(WorkspaceCommandFrame(op: "tick")).encoded()
    #expect(String(decoding: encoded, as: UTF8.self).contains("bobb.command"))
}

@Test func oldSettingsMigrateWithoutEnablingNewCapabilities() throws {
    let settings = try JSONDecoder().decode(BobbSettings.self, from: Data(#"{"floor":0.7,"memory_enabled":true}"#.utf8))
    #expect(settings.floor == 0.7); #expect(settings.bobb.boundaries.apps.isEmpty)
    #expect(Entitlement.community.allowsAssistance)
    #expect(try JSONDecoder().decode(BobbSettings.self, from: JSONEncoder().encode(settings)) == settings)
}

@Test func messagesCommandsAreBoundedAndArchivesAreNotExecuted() {
    #expect(MessagesCommandDecoder.decode(plain: "/bobb status", attributedBody: nil) == "status")
    #expect(MessagesCommandDecoder.decode(plain: "[Bobb] status", attributedBody: nil) == nil)
    #expect(MessagesCommandDecoder.decode(plain: "/bobb " + String(repeating: "x", count: 4000), attributedBody: nil) == nil)
    var archive = Data([4, 11]) + Data("streamtyped".utf8)
    let text = Data("/bobb controlla il caffè".utf8)
    archive += Data([0x84, 1, 0x2b, UInt8(text.count)]) + text
    #expect(MessagesCommandDecoder.decode(plain: nil, attributedBody: archive) == "controlla il caffè")
    #expect(MessagesCommandDecoder.decode(plain: "/bobb different", attributedBody: archive) == nil)
    #expect(MessagesCommandDecoder.decode(plain: nil, attributedBody: Data(archive.dropLast())) == nil)
    #expect(MessagesCommandDecoder.decode(plain: nil, attributedBody: Data([0x84, 1, 0x2b, 0xff])) == nil)
}

@MainActor
@Test func visualTargetsAskOnEveryObservationAndNeverPersistAlways() async {
    let screen = ScreenObservation(app: "Canvas", bundleId: "canvas", window: "Canvas", elements: [
        UIElementSnapshot(key: 1, role: UIElementSnapshot.visualTextRole, title: "Continue")
    ])
    let state = AppState(), driver = FakeDriver(screens: [screen])
    let click: (TaskObserveFrame) -> ActFrame? = { frame in
        ActFrame(ts: 0, observationId: frame.id, operation: .click, candidateId: frame.candidates[0].id,
                 confidence: 0.9, schemaMass: 0.99, latencyMs: 0, taskId: frame.taskId)
    }
    let brain = FakeBrain([click, click, { frame in
        ActFrame(ts: 0, observationId: frame.id, operation: .done, candidateId: "", confidence: 1, schemaMass: 1, latencyMs: 0, taskId: frame.taskId)
    }])
    var boundaries = BoundaryConfiguration()
    boundaries.apps = [AppBoundary(id: "canvas", name: "Canvas")]
    let loop = TaskLoop(goal: "Continue", state: state, brain: brain, driver: driver, policy: ActionPolicy(boundaries: boundaries))
    var saved: [ActionAllowRule] = []
    loop.onAllowAlways = { saved.append($0) }
    let running = Task { await loop.run() }
    for expectedCount in 0...1 {
        for _ in 0..<2000 {
            if driver.performed.count == expectedCount, case .waitingForPermission = state.task?.phase { break }
            await Task.yield()
        }
        guard case .waitingForPermission(let request) = state.task?.phase else {
            Issue.record("A visual target executed without asking"); loop.stop(); _ = await running.value; return
        }
        #expect(request.reason == "visualTarget")
        #expect(driver.performed.count == expectedCount)
        loop.answerPermission(expectedCount == 0 ? .allowAlways : .allowOnce)
        while driver.performed.count <= expectedCount, !state.task!.isFinished { await Task.yield() }
    }
    #expect(await running.value == .done)
    #expect(saved.isEmpty)
    #expect(driver.performed.count == 2)
}

@Test func oldCloudSettingsAreDiscardedWithoutLosingLocalPreferences() throws {
    var original = BobbSettings()
    original.bobb.backgroundEnabled = true
    original.bobb.localModelPath = "/models/local"
    original.bobb.boundaries.apps = [AppBoundary(id: "com.apple.mail", name: "Mail", actions: ["send": .deny])]
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
    var workspace = json["bobb"] as! [String: Any]
    workspace["cloud"] = ["enabled": true, "endpoint": "https://provider.example/chat", "model": "remote", "privateTerms": ["private"]]
    var boundaries = workspace["boundaries"] as! [String: Any]
    boundaries.removeValue(forKey: "excludedApps")
    workspace["boundaries"] = boundaries; json["bobb"] = workspace
    let migrated = try JSONDecoder().decode(BobbSettings.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(migrated == original)
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as! [String: Any]
    #expect((encoded["bobb"] as? [String: Any])?["cloud"] == nil)
}
