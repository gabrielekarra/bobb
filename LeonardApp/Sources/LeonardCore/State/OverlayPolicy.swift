/// Maps a `decision.action` to what the app does about it. This is the
/// entire contract-mandated state machine: `suggest` shows the overlay,
/// everything else — `ignore`, `wait`, `prepare`, and any `suggest` the
/// daemon downgraded to `wait` with `abstained: true` — shows nothing.
public enum OverlayPolicy {
    public static func shouldShowOverlay(for decision: DecisionFrame) -> Bool {
        decision.action == .suggest && !decision.abstained && decision.suggestion != nil
    }
}
