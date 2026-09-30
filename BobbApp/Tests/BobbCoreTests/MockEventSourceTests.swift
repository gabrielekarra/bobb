import Testing
@testable import BobbCore

@MainActor
@Suite("MockEventSource scenario replay")
struct MockEventSourceTests {
    @Test func replaysStepsInOrder() async {
        let scenario = [
            ScenarioStep(delay: 0.01, event: EventFrame(kind: .appActivated, app: "Mail", payload: EventPayload(typing: false, idle: false))),
            ScenarioStep(delay: 0.01, event: EventFrame(kind: .mailOpened, app: "Mail", payload: EventPayload(typing: false, idle: false))),
        ]
        let source = MockEventSource(scenario: scenario, loop: false)
        source.start()
        let events = await collect(source.events, count: 2, timeoutSeconds: 3)
        source.stop()
        #expect(events.map(\.kind) == [.appActivated, .mailOpened])
    }

    @Test func loopsWhenConfiguredTo() async {
        let scenario = [
            ScenarioStep(delay: 0.01, event: EventFrame(kind: .appActivated, app: "X", payload: EventPayload(typing: false, idle: false)))
        ]
        let source = MockEventSource(scenario: scenario, loop: true)
        source.start()
        let events = await collect(source.events, count: 3, timeoutSeconds: 3)
        source.stop()
        #expect(events.count == 3)
        #expect(events.allSatisfy { $0.kind == .appActivated })
    }

    @Test func stopPreventsFurtherEmission() async {
        let scenario = [
            ScenarioStep(delay: 0.02, event: EventFrame(kind: .appActivated, app: "X", payload: EventPayload(typing: false, idle: false)))
        ]
        let source = MockEventSource(scenario: scenario, loop: true)
        source.start()
        _ = await collect(source.events, count: 1, timeoutSeconds: 3)
        source.stop()
        let more = await collect(source.events, count: 1, timeoutSeconds: 0.2)
        #expect(more.isEmpty)
    }
}
