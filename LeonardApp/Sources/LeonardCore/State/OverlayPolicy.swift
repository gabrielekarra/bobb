/// Maps a `decision.action` to what the app does about it: `suggest` shows
/// the overlay; `suggest` and `prepare` both wait in "For you" until the
/// user answers them; everything else — `ignore`, `wait`, and anything the
/// daemon downgraded to `wait` with `abstained: true` — shows nothing.
public enum OverlayPolicy {
    public static func shouldShowOverlay(for decision: DecisionFrame) -> Bool {
        decision.action == .suggest && !decision.abstained && decision.suggestion != nil
    }

    public static func belongsInForYou(_ decision: DecisionFrame) -> Bool {
        (decision.action == .suggest || decision.action == .prepare) && !decision.abstained && decision.suggestion != nil
    }
}
