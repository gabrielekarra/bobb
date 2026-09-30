import Testing
@testable import BobbCore

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

    private func modelDecision(id: String, eventId: String, latencyMs: Double) -> DecisionFrame {
        var d = decision(id: id, eventId: eventId, action: .ignore, latencyMs: latencyMs)
        d.readouts = [Readout(q: "urgency", value: .number(0), p: 0.9, schemaMass: 0.99)]
        return d
    }

    @Test func medianDecisionLatencyIsCorrectForEvenAndOddCounts() {
        let state = AppState()
        #expect(state.medianDecisionLatencyMs == 0)

        for (i, latency) in [10.0, 30.0, 20.0].enumerated() {
            state.recordEvent(event(id: "e\(i)"))
            state.recordDecision(modelDecision(id: "d\(i)", eventId: "e\(i)", latencyMs: latency))
        }
        #expect(state.medianDecisionLatencyMs == 20.0)

        state.recordEvent(event(id: "e3"))
        state.recordDecision(modelDecision(id: "d3", eventId: "e3", latencyMs: 40.0))
        #expect(state.medianDecisionLatencyMs == 25.0)
    }

    @Test func instantDecisionsWithoutAModelDoNotDragTheMedianDown() {
        let state = AppState()
        state.recordEvent(event(id: "e0"))
        state.recordDecision(modelDecision(id: "d0", eventId: "e0", latencyMs: 500))
        for i in 1...5 {
            state.recordEvent(event(id: "e\(i)", kind: .mailArrived))
            state.recordDecision(decision(id: "d\(i)", eventId: "e\(i)", action: .ignore, latencyMs: 0.1))
        }
        #expect(state.medianDecisionLatencyMs == 500)
    }

    @Test func suggestAndPrepareWaitInForYouUntilAnswered() {
        let state = AppState()
        var prepared = decision(id: "p1", eventId: "e1", action: .prepare, latencyMs: 1)
        prepared.suggestion = Suggestion(title: "Marco is waiting", actionId: "draft_reply", detail: "", cta: "Draft reply")
        state.recordDecision(prepared)
        state.recordDecision(decision(id: "s1", eventId: "e2", action: .suggest, latencyMs: 1))
        state.recordDecision(decision(id: "w1", eventId: "e3", action: .wait, latencyMs: 1, abstained: true))
        #expect(state.forYou.map(\.id) == ["s1", "p1"])
        #expect(state.pendingOverlay?.id == "s1")
        state.resolve("s1")
        #expect(state.forYou.map(\.id) == ["p1"])
        state.expireForYou(now: 1 + 13 * 3600)
        #expect(state.forYou.isEmpty)
    }

    @Test func draftStreamsThenSettles() {
        let state = AppState()
        let d = decision(id: "d1", eventId: "e1", action: .suggest, latencyMs: 1)
        state.beginDraft(for: d)
        state.applyPreparedDelta(PreparedDeltaFrame(ts: 1, decisionId: "d1", text: "Ciao "))
        state.applyPreparedDelta(PreparedDeltaFrame(ts: 1, decisionId: "other", text: "ignored"))
        state.applyPreparedDelta(PreparedDeltaFrame(ts: 1, decisionId: "d1", text: "Marco,"))
        #expect(state.draft?.text == "Ciao Marco,")
        #expect(state.draft?.streaming == true)
        state.applyPrepared(PreparedFrame(ts: 2, decisionId: "d1", actionId: "draft_reply",
                                          result: .object(["kind": .string("reply"), "body": .string("Ciao Marco, confermo.")]),
                                          latencyMs: 900))
        #expect(state.draft?.text == "Ciao Marco, confermo.")
        #expect(state.draft?.streaming == false)
        #expect(state.draft?.isReply == true)
    }

    @Test func askStreamsAndIgnoresStaleRequests() {
        let state = AppState()
        let frame = AskFrame(id: "a1", prompt: "IBAN?")
        state.beginAsk(frame, mode: .ask)
        state.applyAnswerDelta(AnswerDeltaFrame(ts: 1, requestId: "a0", text: "stale"))
        state.applyAnswerDelta(AnswerDeltaFrame(ts: 1, requestId: "a1", text: "IT60 [1]"))
        #expect(state.ask.text == "IT60 [1]")
        state.applyAnswer(AnswerFrame(ts: 2, requestId: "a1", ok: true, text: "IT60 [1]",
                                      sources: [SourceRef(n: 1, id: 7, app: "Mail", window: "Preventivo", ts: 1, lastSeen: 1)]))
        #expect(state.ask.streaming == false)
        #expect(state.ask.sources.first?.app == "Mail")
        state.beginAsk(AskFrame(id: "a2", prompt: "x"), mode: .ask)
        state.applyError(ErrorFrame(ts: 3, detail: "model loading", requestId: "a2"))
        #expect(state.ask.error == "model loading")
    }

    @Test func activityStateReflectsSetupAndPause() {
        let state = AppState()
        state.modelInstalled = false
        #expect(state.activityState == .setupNeeded)
        state.connection = .connected
        state.daemonStatus = StatusFrame(ts: 1, state: "loading")
        #expect(state.activityState == .starting)
        state.connection = .ready(ReadyFrame(ts: 1, model: "m", primeMs: 1, decideMs: 1, floor: 0.6))
        state.watching = false
        #expect(state.activityState == .paused)
        state.watching = true
        state.entitlement = .trialExpired
        #expect(state.activityState == .paused)
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
