import func Foundation.pow

/// Exponential reconnect backoff with a cap and a fixed multiplier, kept as
/// a pure value type so the schedule is testable without waiting in real
/// time.
public struct Backoff: Sendable, Equatable {
    public var initial: Double
    public var multiplier: Double
    public var max: Double

    public init(initial: Double = 0.5, multiplier: Double = 2.0, max: Double = 30.0) {
        self.initial = initial
        self.multiplier = multiplier
        self.max = max
    }

    /// Delay in seconds before reconnect attempt `attempt` (1-based: the
    /// first retry after the first failed connection is `attempt == 1`).
    public func delay(forAttempt attempt: Int) -> Double {
        guard attempt > 0 else { return 0 }
        let raw = initial * pow(multiplier, Double(attempt - 1))
        return Swift.min(raw, max)
    }
}
