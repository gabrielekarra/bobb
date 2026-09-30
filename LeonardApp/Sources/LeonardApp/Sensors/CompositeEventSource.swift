import Foundation
import LeonardCore

/// Every real sensor behind the one `EventSource` the coordinator reads:
/// app and idle changes from `WorkspaceEventSource`, and the open message
/// and the draft in progress from `MailSensor`.
@MainActor
final class CompositeEventSource: EventSource {
    let events: AsyncStream<EventFrame>
    private let continuation: AsyncStream<EventFrame>.Continuation
    private let workspace: WorkspaceEventSource
    let mail: MailSensor
    var permittedApp: ((String?, String) -> Bool)? {
        didSet { workspace.permittedApp = permittedApp }
    }
    private var forwarding: Task<Void, Never>?

    init(workspace: WorkspaceEventSource = WorkspaceEventSource(), mail: MailSensor = MailSensor()) {
        self.workspace = workspace
        self.mail = mail
        var continuation: AsyncStream<EventFrame>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func start() {
        let continuation = continuation
        mail.onEvent = { continuation.yield($0) }
        forwarding = Task { [workspace] in
            for await event in workspace.events {
                continuation.yield(event)
            }
        }
        workspace.start()
        mail.start()
    }

    func stop() {
        workspace.stop()
        mail.stop()
        forwarding?.cancel()
        forwarding = nil
    }
}
