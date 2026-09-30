import Testing
@testable import BobbCore

@Suite("Backoff schedule")
struct BackoffTests {
    @Test func firstAttemptUsesInitialDelay() {
        let backoff = Backoff(initial: 0.5, multiplier: 2.0, max: 30.0)
        #expect(backoff.delay(forAttempt: 1) == 0.5)
    }

    @Test func growsExponentially() {
        let backoff = Backoff(initial: 1.0, multiplier: 2.0, max: 1000.0)
        #expect(backoff.delay(forAttempt: 1) == 1.0)
        #expect(backoff.delay(forAttempt: 2) == 2.0)
        #expect(backoff.delay(forAttempt: 3) == 4.0)
        #expect(backoff.delay(forAttempt: 4) == 8.0)
    }

    @Test func capsAtMax() {
        let backoff = Backoff(initial: 1.0, multiplier: 2.0, max: 5.0)
        #expect(backoff.delay(forAttempt: 10) == 5.0)
    }

    @Test func zerothAttemptIsImmediate() {
        let backoff = Backoff()
        #expect(backoff.delay(forAttempt: 0) == 0)
    }
}
