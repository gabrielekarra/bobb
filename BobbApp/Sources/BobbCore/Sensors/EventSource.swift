/// A source of contract-shaped `EventFrame`s.
///
/// This is the seam the product's other workstream plugs the real sensors
/// into once the Cua-Driver-vs-hand-rolled-AX decision is made: a
/// `MailEventSource` conforming to this protocol, emitting `mail.opened` /
/// `mail.composing`, is the entire integration surface. Nothing downstream
/// — `IPCClient`, `AppState`, the Mind panel — knows or cares where an
/// event came from.
@MainActor
public protocol EventSource: AnyObject {
    var events: AsyncStream<EventFrame> { get }
    func start()
    func stop()
}
