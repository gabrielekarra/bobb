import Testing
@testable import BobbCore

@Suite("OverlayPolicy: decision.action -> UI behaviour")
struct OverlayPolicyTests {
    private func decision(action: DecisionAction, abstained: Bool = false, hasSuggestion: Bool) -> DecisionFrame {
        DecisionFrame(
            ts: 1, id: "d", eventId: "e", action: action, confidence: 0.9, schemaMass: 0.99, latencyMs: 10,
            suggestion: hasSuggestion ? Suggestion(title: "t", actionId: "a", detail: "d") : nil,
            why: "why", abstained: abstained
        )
    }

    @Test func suggestWithSuggestionShowsOverlay() {
        #expect(OverlayPolicy.shouldShowOverlay(for: decision(action: .suggest, hasSuggestion: true)))
    }

    @Test func ignoreNeverShowsOverlay() {
        #expect(!OverlayPolicy.shouldShowOverlay(for: decision(action: .ignore, hasSuggestion: false)))
    }

    @Test func waitNeverShowsOverlay() {
        #expect(!OverlayPolicy.shouldShowOverlay(for: decision(action: .wait, hasSuggestion: false)))
    }

    @Test func prepareNeverShowsOverlay() {
        #expect(!OverlayPolicy.shouldShowOverlay(for: decision(action: .prepare, hasSuggestion: false)))
    }

    @Test func abstainedNeverShowsOverlayEvenIfMislabeledSuggest() {
        // The daemon always downgrades an abstained decision's action to
        // "wait", but the UI policy must not show an overlay for an
        // abstained decision under any circumstance, even a malformed one.
        #expect(!OverlayPolicy.shouldShowOverlay(for: decision(action: .suggest, abstained: true, hasSuggestion: true)))
        #expect(!OverlayPolicy.shouldShowOverlay(for: decision(action: .wait, abstained: true, hasSuggestion: false)))
    }

    @Test func suggestWithoutSuggestionPayloadNeverShowsOverlay() {
        // Malformed on the wire (suggest without a suggestion body): the
        // policy must fail closed, not crash the overlay on force-unwrap.
        #expect(!OverlayPolicy.shouldShowOverlay(for: decision(action: .suggest, hasSuggestion: false)))
    }
}
