/// One event's full life in the Mind panel: what happened, every trace
/// stage the daemon reported for it, and the decision it resolved to (nil
/// until the `decision` frame arrives — the contract guarantees exactly
/// one, eventually, per event).
public struct MindEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public var event: EventFrame
    public var traces: [TraceFrame]
    public var decision: DecisionFrame?

    public init(event: EventFrame, traces: [TraceFrame] = [], decision: DecisionFrame? = nil) {
        self.id = event.id
        self.event = event
        self.traces = traces
        self.decision = decision
    }
}
