import Foundation
import Testing
@testable import BobbCore

@Suite struct ToolArgumentTests {
    @Test func nativeSchemasRejectMissingUnknownAndWrongTypes() {
        let create = NativeAppToolCatalog.tools.first { $0.id == "reminders.create" }!
        #expect(ToolArguments.parse("{}", schema: create.schema) == nil)
        #expect(ToolArguments.parse(#"{"title":"Buy milk","priority":2}"#, schema: create.schema) != nil)
        #expect(ToolArguments.parse(#"{"title":"Buy milk","priority":"2"}"#, schema: create.schema) == nil)
        #expect(ToolArguments.parse(#"{"title":"Buy milk","priority":10}"#, schema: create.schema) == nil)
        #expect(ToolArguments.parse(#"{"title":"Buy milk","shell":"rm"}"#, schema: create.schema) == nil)
        #expect(ToolArguments.parse("[]") == nil)
        let draft = NativeAppToolCatalog.tools.first { $0.id == "mail.draft" }!
        #expect(ToolArguments.parse(#"{"to":["a@example.com"],"subject":"Hi","body":"Hello"}"#, schema: draft.schema) != nil)
        #expect(ToolArguments.parse(#"{"to":[1],"subject":"Hi","body":"Hello"}"#, schema: draft.schema) == nil)
    }
    @Test func importedConfigurationIsBackwardCompatibleAndCredentialsAreReferences() throws {
        let old = try JSONDecoder().decode(MCPConfiguration.self, from: Data(#"{"id":"x","executable":"/usr/bin/test","arguments":[],"enabled":true}"#.utf8))
        #expect(old.environmentReferences.isEmpty)
        #expect(old.excludedTools.isEmpty)
        let entries = try MCPImportedServer.parse(Data(#"{"mcpServers":{"x":{"command":"node","args":["server.js"],"env":{"API_TOKEN":"example"},"excluded_tools":["delete"]}}}"#.utf8))
        #expect(entries["x"]?.env["API_TOKEN"] == "example")
        #expect(entries["x"]?.excludedTools == ["delete"])
        for key in ["PATH", "HOME", "DYLD_INSERT_LIBRARIES", "NODE_OPTIONS", "BASH_ENV", "LD_PRELOAD", "A=B"] {
            #expect(!MCPImportedServer.allowedEnvironmentKey(key))
        }
        #expect(try MCPImportedServer.parse(Data(#"{"mcpServers":{"x":{"url":"https://example.com/mcp"}}}"#.utf8))["x"]?.transport == .http)
        #expect(throws: (any Error).self) { try MCPImportedServer.parse(Data(#"{"mcpServers":{"x":{"command":"node","env":{"NODE_OPTIONS":"evil"}}}}"#.utf8)) }
    }
    @Test func typedEffectsCannotHideBehindAReadLabel() {
        var boundaries = BoundaryConfiguration()
        boundaries.apps = [AppBoundary(id: "com.apple.iCal", name: "Calendar", actions: ["delete": .deny, "write": .allow])]
        let policy = ActionPolicy(boundaries: boundaries)
        #expect(policy.evaluate(operation: .click, label: "Read", role: "button", appBundleId: "com.apple.iCal", appName: "Calendar", actionCategories: [.delete]) == .deny(reason: "boundary:delete"))
        #expect(policy.evaluate(operation: .click, label: "Call create", role: "button", appBundleId: "com.apple.iCal", appName: "Calendar", actionCategories: [.write]) == .allow)
        boundaries.apps = [AppBoundary(id: "com.apple.shortcuts", name: "Shortcuts", actions: ["execute": .allow])]
        #expect(ActionPolicy(boundaries: boundaries).evaluate(operation: .click, label: "Call", role: "button", appBundleId: "com.apple.shortcuts", appName: "Shortcuts", actionCategories: [.execute]) == .allow)
        #expect(ActionPolicy(boundaries: BoundaryConfiguration()).evaluate(operation: .click, label: "Call", role: "button", appBundleId: "com.apple.shortcuts", appName: "Shortcuts", actionCategories: [.execute]) == .ask(reason: "boundary:execute"))
    }
}

@MainActor @Suite struct AppToolComputerTests {
    @MainActor private final class Access { var allowed = true }
    private var tool: AppTool { NativeAppToolCatalog.tools.first { $0.id == "reminders.create" }! }
    @Test func discoveryAndPreparationDoNotExecuteAndWritesAreDeduplicated() async {
        var calls = 0
        let driver = AppToolComputer(tools: [tool], permitted: { _ in true }) { _, args in calls += 1; return ["status": "created", "title": args["title"]!] }
        #expect(await driver.perform(.press(key: 0)) == .ok)
        #expect(calls == 0)
        #expect(await driver.perform(.type(key: -2, text: #"{"title":"Buy milk"}"#, submit: false)) == .ok)
        #expect(calls == 0)
        #expect(await driver.completionProblem(goal: "create") != nil)
        #expect(driver.actionContext(for: .press(key: -3))?.categories == [.write])
        #expect(driver.actionContext(for: .type(key: -2, text: "{}", submit: false))?.categories == [.navigate])
        #expect(await driver.perform(.press(key: -3)) == .ok)
        #expect(await driver.perform(.press(key: -3)) == .ok)
        #expect(calls == 1)
        #expect(await driver.completionProblem(goal: "create") == nil)
        #expect((await driver.observe())?.screenText.contains("created") == true)
    }
    @Test func invalidArgumentsAndRevokedAppsNeverRun() async {
        let access = Access(); var calls = 0
        let driver = AppToolComputer(tools: [tool], permitted: { _ in access.allowed }) { _, _ in calls += 1; return ["status": "created"] }
        _ = await driver.perform(.press(key: 0))
        _ = await driver.perform(.type(key: -2, text: #"{"unknown":1}"#, submit: false))
        #expect(await driver.perform(.press(key: -3)) == .failed("invalidToolArguments"))
        #expect(calls == 0)
        _ = await driver.perform(.type(key: -2, text: #"{"title":"x"}"#, submit: false))
        access.allowed = false
        #expect(await driver.perform(.press(key: -3)) == .failed("invalidToolArguments"))
        #expect((await driver.observe())?.elements.isEmpty == true)
        #expect(calls == 0)
    }
    @Test func failedCallsCannotCompleteAndCloseCannotExecute() async {
        let driver = AppToolComputer(tools: [tool], permitted: { _ in true }) { _, _ in ["isError": true, "error": "denied"] }
        _ = await driver.perform(.press(key: 0))
        _ = await driver.perform(.type(key: -2, text: #"{"title":"x"}"#, submit: false))
        #expect(await driver.perform(.press(key: -3)) == .failed("toolFailed"))
        #expect(await driver.completionProblem(goal: "create") != nil)
        await driver.close()
        #expect(await driver.perform(.press(key: -3)) == .stale)
        #expect(await driver.observe() == nil)
    }
    @Test func repeatablePlaybackCommandsRunAgainAndRevokedResultsAreHidden() async {
        let next = NativeAppToolCatalog.tools.first { $0.id == "music.next" }!
        let access = Access(); var calls = 0
        let driver = AppToolComputer(tools: [next], permitted: { _ in access.allowed }) { _, _ in
            calls += 1
            if calls == 3 { access.allowed = false }
            return ["title": .string("Track \(calls)")]
        }
        _ = await driver.perform(.press(key: 0))
        #expect(await driver.perform(.press(key: -3)) == .ok)
        let first = await driver.observe()
        #expect(first == (await driver.observe()))
        #expect(await driver.perform(.press(key: -3)) == .ok)
        #expect(calls == 2)
        #expect(await driver.perform(.press(key: -3)) == .stale)
        #expect(await driver.completionProblem(goal: "next") != nil)
        #expect((await driver.observe())?.screenText.contains("Track 3") == false)
    }
    @Test func taskLoopDeniesToolDeletionBeforeTheAdapter() async {
        let delete = NativeAppToolCatalog.tools.first { $0.id == "reminders.delete" }!
        var calls = 0
        let driver = AppToolComputer(tools: [delete], permitted: { _ in true }) { _, _ in calls += 1; return ["status": "deleted"] }
        let choose: (TaskObserveFrame, String, ActOperation, String?) -> ActFrame = { frame, label, operation, text in
            ActFrame(ts: 0, observationId: frame.id, operation: operation,
                     candidateId: frame.candidates.first { $0.label == label }!.id, confidence: 0.99, schemaMass: 1,
                     text: text, latencyMs: 0, why: "test", taskId: frame.taskId)
        }
        let brain = FakeBrain([
            { choose($0, delete.name, .click, nil) },
            { choose($0, "JSON arguments for \(delete.name)", .type, #"{"reminder_id":"exact-id"}"#) },
            { choose($0, "Call \(delete.name)", .click, nil) },
        ])
        var boundaries = BoundaryConfiguration()
        boundaries.apps = [AppBoundary(id: "com.apple.reminders", name: "Reminders", actions: ["delete": .deny])]
        let loop = TaskLoop(goal: "Delete reminder", state: AppState(), brain: brain, driver: driver, policy: ActionPolicy(boundaries: boundaries))
        #expect(await loop.run() == .blocked)
        #expect(calls == 0)
        #expect(brain.steps.last?.outcome == .denied)
    }
}

@MainActor @Suite struct ToolRecoveryTests {
    @Test func largeResultsHavePagesAndNeverDiscardTheTail() async {
        let tool = NativeAppToolCatalog.tools.first { $0.id == "music.status" }!
        let output = String(repeating: "abcdef", count: 3000) + "END_RECEIPT"
        let driver = AppToolComputer(tools: [tool], permitted: { _ in true }) { _, _ in ["text": .string(output)] }
        _ = await driver.perform(.press(key: 0)); _ = await driver.perform(.press(key: -3))
        var pages = ""
        while let observation = await driver.observe() {
            pages += observation.screenText
            guard observation.elements.contains(where: { $0.key == -5 }) else { break }
            #expect(await driver.perform(.press(key: -5)) == .ok)
        }
        #expect(pages.contains("END_RECEIPT"))
        #expect(await driver.perform(.press(key: -4)) == .ok)
        #expect(driver.actionContext(for: .press(key: -4))?.categories == [.navigate])
    }
    @Test func uncertainWritesCannotBeBlindlyRetried() async {
        var calls = 0
        let tool = NativeAppToolCatalog.tools.first { $0.id == "messages.send" }!
        let driver = AppToolComputer(tools: [tool], permitted: { _ in true }) { _, _ in calls += 1; throw CocoaError(.fileWriteUnknown) }
        _ = await driver.perform(.press(key: 0))
        _ = await driver.perform(.type(key: -2, text: #"{"chat_id":"exact","members":["a"],"body":"Hi"}"#, submit: false))
        #expect(await driver.perform(.press(key: -3)) == .failed("toolUnavailable"))
        #expect(await driver.perform(.press(key: -3)) == .failed("uncertainToolOutcome"))
        #expect(calls == 1)
        #expect(await driver.completionProblem(goal: "send") != nil)
    }
    @Test func receiptSurvivesPermissionChangeAfterAnEffect() async {
        var allowed = true; var calls = 0
        let tool = NativeAppToolCatalog.tools.first { $0.id == "reminders.create" }!
        let driver = AppToolComputer(tools: [tool], permitted: { _ in allowed }) { _, _ in calls += 1; allowed = false; return ["status": "created"] }
        _ = await driver.perform(.press(key: 0)); _ = await driver.perform(.type(key: -2, text: #"{"title":"x"}"#, submit: false))
        #expect(await driver.perform(.press(key: -3)) == .stale)
        allowed = true
        #expect(await driver.perform(.press(key: -3)) == .ok)
        #expect(calls == 1)
    }
}

@MainActor @Test func largeToolSchemaIsSeparateFromResultAndFitsScreenBudget() async {
    let schema: JSONValue = ["type": "object", "properties": ["name": ["type": "string", "description": .string(String(repeating: "x", count: 9000))]]]
    let tool = AppTool(id: "large", name: "Large", summary: "", bundleId: "mcp:test", app: "MCP test", category: .execute, schema: schema, validatesSchema: false)
    let driver = AppToolComputer(tools: [tool], permitted: { _ in true }) { _, _ in ["receipt": "tail-result"] }
    #expect(await driver.perform(.press(key: 0)) == .ok)
    #expect(await driver.perform(.press(key: -3)) == .ok)
    let observation = await driver.observe()
    #expect(observation?.toolSchema == schema)
    #expect(observation?.screenText.contains("tail-result") == true, "\(observation?.screenText ?? "nil")")
    #expect((observation?.screenText.count ?? 0) < 6000)
}

@MainActor @Test func configuredToolRoutesRemainDiscoverableWithoutAnAppKeyword() {
    let choices = TaskLoop.appCandidates(["Unrelated", "MCP project", NativeAppToolCatalog.applicationName], goal: "Help with my workflow", current: "Safari", alwaysOffered: ["MCP project", NativeAppToolCatalog.applicationName])
    #expect(Set(choices.map(\.label)) == ["MCP project", NativeAppToolCatalog.applicationName])
}
