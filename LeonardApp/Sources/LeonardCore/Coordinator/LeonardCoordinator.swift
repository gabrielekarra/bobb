import Foundation

/// Wires one `EventSource` to one `IPCClient` and folds everything either
/// produces into `AppState`. This is the only place that knows both sides
/// exist; `MenuBar`, `Overlay`, `Mind` and `Audit` only ever look at
/// `AppState`.
@MainActor
public final class LeonardCoordinator {
    public let state: AppState
    public let client: IPCClient
    public let eventSource: EventSource

    private var stateTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    public init(state: AppState = AppState(), client: IPCClient, eventSource: EventSource) {
        self.state = state
        self.client = client
        self.eventSource = eventSource
    }

    public func start() {
        let client = client
        let state = state
        stateTask = Task {
            for await connectionState in client.states {
                state.connection = connectionState
                if case .ready(let ready) = connectionState {
                    state.floor = ready.floor
                }
            }
        }
        frameTask = Task {
            for await frame in client.frames {
                switch frame {
                case .decision(let decision):
                    state.recordDecision(decision)
                case .trace(let trace):
                    state.recordTrace(trace)
                case .ready, .prepared, .error, .act, .unknown:
                    break
                }
            }
        }
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.eventSource.events {
                guard self.state.watching else { continue }
                self.state.recordEvent(event)
                await self.client.send(event: event)
            }
        }
        eventSource.start()
        Task { await client.start() }
    }

    public func stop() {
        stateTask?.cancel()
        frameTask?.cancel()
        eventTask?.cancel()
        eventSource.stop()
        Task { await client.stop() }
    }

    public func approve(_ decision: DecisionFrame) {
        Task { await client.sendApprove(decisionId: decision.id) }
    }

    public func dismiss(_ decision: DecisionFrame) {
        Task { await client.sendDismiss(decisionId: decision.id) }
    }

    public func setFloor(_ floor: Double) {
        state.floor = floor
        Task { await client.sendPolicy(floor: floor) }
    }

    public func setWatching(_ watching: Bool) {
        state.watching = watching
    }
}
