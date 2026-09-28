import Testing
@testable import LeonardCore

@MainActor
@Suite("AppState tallies and Mind log")
struct AppStateTests {
    private func event(id: String, kind: EventKind = .mailOpened) -> EventFrame {
        EventFrame(ts: 1, id: id, kind: kind, app: "Mail", payload: EventPayload(typing: false, idle: false))
    }

    private func decision(id: String, eventId: String, action: DecisionAction, latencyMs: Double, abstained: Bool = false) -> DecisionFrame {
        DecisionFrame(
            ts: 1, id: id, eventId: eventId, action: action, confidence: 0.9, schemaMass: 0.99,
            latencyMs: latencyMs,
            suggestion: action == .suggest && !abstained ? Suggestion(title: "t", actionId: "a", detail: "d") : nil,
            why: "why", abstained: abstained
        )
    }

    @Test func recordEventIncrementsSeenAndInsertsAtFront() {
        let state = AppState()
        state.recordEvent(event(id: "e1"))
        state.recordEvent(event(id: "e2"))
        #expect(state.eventsSeen == 2)
        #expect(state.entries.map(\.id) == ["e2", "e1"])
    }

    @Test func recordTraceAttachesToMatchingEntry() {
        let state = AppState()
        state.recordEvent(event(id: "e1"))
        state.recordTrace(TraceFrame(ts: 1, eventId: "e1", stage: nil, rawStage: "gate", detail: "ok", ms: 0.4))
        #expect(state.entries.first?.traces.count == 1)
        #expect(state.entries.first?.traces.first?.detail == "ok")
    }

    @Test func recordDecisionUpdatesTallyAndEntry() {
        let state = AppState()
        state.recordEvent(event(id: "e1"))
        state.recordDecision(decision(id: "d1", eventId: "e1", action: .ignore, latencyMs: 10))
        #expect(state.decisionsMade == 1)
        #expect(state.staySilentCount == 1)
        #expect(state.entries.first?.decision?.id == "d1")
        #expect(state.pendingOverlay == nil)
    }

    @Test func suggestDecisionSetsPendingOverlayAndDoesNotCountAsSilent() {
        let state = AppState()
        state.recordEvent(event(id: "e1"))
        let d = decision(id: "d1", eventId: "e1", action: .suggest, latencyMs: 10)
        state.recordDecision(d)
        #expect(state.staySilentCount == 0)
        #expect(state.pendingOverlay == d)
    }

    @Test func abstainedSuggestNeverSetsPendingOverlay() {
        let state = AppState()
        state.recordEvent(event(id: "e1"))
        state.recordDecision(decision(id: "d1", eventId: "e1", action: .wait, latencyMs: 10, abstained: true))
        #expect(state.pendingOverlay == nil)
        #expect(state.staySilentCount == 1)
    }

    @Test func medianDecisionLatencyIsCorrectForEvenAndOddCounts() {
        let state = AppState()
        #expect(state.medianDecisionLatencyMs == 0)

        for (i, latency) in [10.0, 30.0, 20.0].enumerated() {
            state.recordEvent(event(id: "e\(i)"))
            state.recordDecision(decision(id: "d\(i)", eventId: "e\(i)", action: .ignore, latencyMs: latency))
        }
        #expect(state.medianDecisionLatencyMs == 20.0)

        state.recordEvent(event(id: "e3"))
        state.recordDecision(decision(id: "d3", eventId: "e3", action: .ignore, latencyMs: 40.0))
        #expect(state.medianDecisionLatencyMs == 25.0)
    }

    @Test func learningSignalEventsAreCountedAndHiddenFromVisibleEntriesByDefault() {
        let state = AppState()
        state.recordEvent(event(id: "e1", kind: .mailOpened))
        state.recordEvent(event(id: "e2", kind: .mailArrived))
        state.recordEvent(event(id: "e3", kind: .mailClosed))
        #expect(state.eventsSeen == 3)
        #expect(state.learningSignalCount == 2)
        #expect(state.entries.count == 3)
        #expect(state.visibleEntries.map(\.id) == ["e1"])

        state.hideLearningSignalsInMind = false
        #expect(state.visibleEntries.map(\.id) == ["e3", "e2", "e1"])
    }

    @Test func activityStateReflectsConnectionThinkingAndSuggesting() {
        let state = AppState()
        #expect(state.activityState == .disconnected)

        state.connection = .ready(ReadyFrame(ts: 1, model: "m", primeMs: 1, decideMs: 1, floor: 0.6))
        #expect(state.activityState == .watching)

        state.recordEvent(event(id: "e1"))
        #expect(state.activityState == .thinking)

        state.recordDecision(decision(id: "d1", eventId: "e1", action: .ignore, latencyMs: 5))
        #expect(state.activityState == .watching)

        state.overlayVisible = true
        #expect(state.activityState == .suggesting)

        state.overlayVisible = false
        state.connection = .reconnecting(attempt: 1, retryingAt: 0)
        #expect(state.activityState == .disconnected)
    }

    @Test func entriesAreCappedAtMaxEntries() {
        let state = AppState()
        state.maxEntries = 3
        for i in 0..<5 {
            state.recordEvent(event(id: "e\(i)"))
        }
        #expect(state.entries.count == 3)
        #expect(state.entries.map(\.id) == ["e4", "e3", "e2"])
    }
}
