import Foundation
import Testing
@testable import LeonardCore

@Test func aMixedActionMustRespectEveryBoundary() {
    var boundaries = BoundaryConfiguration()
    boundaries.apps = [AppBoundary(id: "shop", name: "Shop", actions: ["send": .allow, "pay": .deny])]
    let policy = ActionPolicy(boundaries: boundaries)
    #expect(policy.evaluate(operation: .click, label: "Confirm purchase", role: "AXButton", appBundleId: "shop", appName: "Shop") == .deny(reason: "boundary:pay"))
    #expect(LeonardSettings().daemonFrame().connectedApps == [])
}

@Test func bobbDefaultsRequireExplicitConnectionsAndCloudConsent() {
    let settings = LeonardSettings()
    #expect(!settings.bobb.cloud.enabled)
    #expect(!settings.bobb.backgroundEnabled)
    #expect(!settings.bobb.iMessageEnabled)
    #expect(settings.bobb.boundaries.apps.isEmpty)
    let policy = ActionPolicy(boundaries: settings.bobb.boundaries)
    #expect(policy.evaluate(operation: .click, label: "Search", role: "AXButton", appBundleId: "browser", appName: "Browser") == .deny(reason: "unconnectedApp"))
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

@Test func localRedactionRoundTripsWithRequestSpecificTokens() {
    let original = "Marco Rossi: marco@example.test, +39 333 123 4567, api_key: sk-secretkey12345678, IBAN IT60X0542811101000000123456"
    var redactor = LocalRedactor()
    let safe = redactor.redact(original, privateTerms: ["Marco Rossi"])
    #expect(!safe.contains("Marco Rossi")); #expect(!safe.contains("marco@example.test"))
    #expect(!safe.contains("333 123 4567")); #expect(!safe.contains("sk-secretkey"))
    #expect(redactor.restore(safe) == original)
    #expect(redactor.restore("[PRIVATE_forged_0]") == "[PRIVATE_forged_0]")
}

@Test func largerModelRecommendationKeepsHeadroom() {
    #expect(LocalModelOption.recommended(memoryBytes: 8 * 1_073_741_824).parameters == "3B")
    #expect(LocalModelOption.recommended(memoryBytes: 16 * 1_073_741_824).parameters == "7–8B")
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
    let settings = try JSONDecoder().decode(LeonardSettings.self, from: Data(#"{"floor":0.7,"memory_enabled":true}"#.utf8))
    #expect(settings.floor == 0.7); #expect(!settings.bobb.cloud.enabled)
    #expect(Entitlement.community.allowsAssistance)
    #expect(try JSONDecoder().decode(LeonardSettings.self, from: JSONEncoder().encode(settings)) == settings)
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
