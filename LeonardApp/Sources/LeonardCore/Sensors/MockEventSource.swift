import Foundation

/// One beat of a scripted scenario: wait `delay` seconds after the previous
/// step (or after `start()`), then emit `event`.
public struct ScenarioStep: Sendable {
    public var delay: TimeInterval
    public var event: EventFrame

    public init(delay: TimeInterval, event: EventFrame) {
        self.delay = delay
        self.event = event
    }
}

/// Replays a fixed, timed sequence of events. Used for demoing and for
/// exercising the Mind panel and overlay without Accessibility permission
/// or a live mailbox.
@MainActor
public final class MockEventSource: EventSource {
    public let events: AsyncStream<EventFrame>
    private let continuation: AsyncStream<EventFrame>.Continuation
    private let scenario: [ScenarioStep]
    private let loop: Bool
    private var task: Task<Void, Never>?

    public init(scenario: [ScenarioStep], loop: Bool = true) {
        self.scenario = scenario
        self.loop = loop
        var continuation: AsyncStream<EventFrame>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func start() {
        guard task == nil else { return }
        let scenario = self.scenario
        let loop = self.loop
        let continuation = self.continuation
        task = Task {
            repeat {
                for step in scenario {
                    if Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: UInt64(max(step.delay, 0) * 1_000_000_000))
                    if Task.isCancelled { return }
                    continuation.yield(step.event)
                }
            } while loop && !Task.isCancelled
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}

extension MockEventSource {
    /// A small, plausible working session: switch into Mail, an urgent
    /// unread thread opens, the user pauses mid-reply, then selects a term
    /// in a browser window. Enough kind variety to light up every panel of
    /// Mind without any sensor wired in yet.
    public static func demoScenario() -> [ScenarioStep] {
        [
            ScenarioStep(
                delay: 1.0,
                event: EventFrame(
                    kind: .appActivated, app: "Mail",
                    payload: EventPayload(typing: false, idle: false, fields: [
                        "previous_app": "Safari", "title": "Posta in arrivo",
                    ])
                )
            ),
            ScenarioStep(
                delay: 2.0,
                event: EventFrame(
                    kind: .mailOpened, app: "Mail",
                    payload: EventPayload(typing: false, idle: false, fields: [
                        "sender": "Marco Rossi <marco@example.com>",
                        "subject": "Preventivo revisione",
                        "body": "Ciao, mi confermi il preventivo così possiamo chiudere entro oggi? Grazie.",
                        "thread_len": 3,
                        "unread": true,
                    ])
                )
            ),
            ScenarioStep(
                delay: 4.0,
                event: EventFrame(
                    kind: .mailComposing, app: "Mail",
                    payload: EventPayload(typing: true, idle: false, fields: [
                        "to": "marco@example.com",
                        "subject": "Re: Preventivo revisione",
                        "draft": "Ciao Marco, confermo il preventivo e",
                        "idle_seconds": 14,
                    ])
                )
            ),
            ScenarioStep(
                delay: 3.0,
                event: EventFrame(
                    kind: .idleEntered, app: "Mail",
                    payload: EventPayload(typing: false, idle: true, fields: [:])
                )
            ),
            ScenarioStep(
                delay: 3.0,
                event: EventFrame(
                    kind: .idleLeft, app: "Mail",
                    payload: EventPayload(typing: false, idle: false, fields: [:])
                )
            ),
            ScenarioStep(
                delay: 2.0,
                event: EventFrame(
                    kind: .appActivated, app: "Safari",
                    payload: EventPayload(typing: false, idle: false, fields: [
                        "previous_app": "Mail", "title": "Documentazione fattura elettronica",
                    ])
                )
            ),
            ScenarioStep(
                delay: 2.0,
                event: EventFrame(
                    kind: .textSelected, app: "Safari",
                    payload: EventPayload(typing: false, idle: false, fields: [
                        "text": "fattura elettronica",
                        "surrounding": "...l'obbligo di fattura elettronica per i forfettari...",
                    ])
                )
            ),
        ]
    }
}
