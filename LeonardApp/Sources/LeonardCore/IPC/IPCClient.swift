import Foundation

/// Unix-domain-socket, NDJSON client for the Leonard IPC contract.
///
/// One `IPCClient` owns at most one live `UnixSocketConnection`. On any
/// disconnect — clean EOF, a read error, or a failed `connect()` — it
/// reconnects with `Backoff`, and `states` always reflects what is actually
/// true of the socket: the UI must never claim `ready` when the daemon is
/// unreachable.
public actor IPCClient {
    public enum ConnectionState: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        case ready(ReadyFrame)
        case reconnecting(attempt: Int, retryingAt: Double)

        public var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    public let socketPath: String
    public let backoff: Backoff

    public let states: AsyncStream<ConnectionState>
    public let frames: AsyncStream<IncomingFrame>

    private let stateContinuation: AsyncStream<ConnectionState>.Continuation
    private let frameContinuation: AsyncStream<IncomingFrame>.Continuation

    private var connection: UnixSocketConnection?
    private var readerTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var attempt = 0
    private var stopped = false
    private var locale: String?

    private var state: ConnectionState = .disconnected {
        didSet { stateContinuation.yield(state) }
    }

    public init(socketPath: String, backoff: Backoff = Backoff()) {
        self.socketPath = socketPath
        self.backoff = backoff
        var stateContinuation: AsyncStream<ConnectionState>.Continuation!
        self.states = AsyncStream { stateContinuation = $0 }
        self.stateContinuation = stateContinuation
        var frameContinuation: AsyncStream<IncomingFrame>.Continuation!
        self.frames = AsyncStream { frameContinuation = $0 }
        self.frameContinuation = frameContinuation
    }

    public func currentState() -> ConnectionState { state }

    public func start() {
        guard !stopped, connection == nil, reconnectTask == nil else { return }
        connectNow()
    }

    public func stop() {
        stopped = true
        reconnectTask?.cancel()
        reconnectTask = nil
        readerTask?.cancel()
        readerTask = nil
        connection?.close()
        connection = nil
        state = .disconnected
    }

    public func send(event: EventFrame) {
        sendOrDisconnect(.event(event))
    }

    /// Any frame. Returns false when there is no live connection, so a
    /// caller waiting on a reply can fail fast instead of timing out.
    @discardableResult
    public func send(_ frame: OutgoingFrame) -> Bool {
        guard connection != nil else { return false }
        sendOrDisconnect(frame)
        return connection != nil
    }

    /// The UI language sent in every `hello` from now on.
    public func setLocale(_ locale: String) {
        self.locale = locale
    }

    public var isConnected: Bool { connection != nil }

    public func sendApprove(decisionId: String) {
        sendOrDisconnect(.approve(DecisionResponseFrame(decisionId: decisionId)))
    }

    public func sendDismiss(decisionId: String, reason: DismissReason? = nil) {
        sendOrDisconnect(.dismiss(DecisionResponseFrame(decisionId: decisionId, reason: reason)))
    }

    public func sendPolicy(floor: Double) {
        sendOrDisconnect(.policy(PolicyFrame(floor: floor)))
    }

    /// Not called by anything in this target yet — see `OutgoingFrame.observe`.
    public func sendObserve(_ observation: ObserveFrame) {
        sendOrDisconnect(.observe(observation))
    }

    private func sendOrDisconnect(_ frame: OutgoingFrame) {
        guard let connection else { return }
        do {
            try connection.write(try frame.encoded())
        } catch {
            handleDisconnect(of: connection)
        }
    }

    private func connectNow() {
        state = .connecting
        do {
            let conn = try UnixSocketConnection(path: socketPath)
            connection = conn
            attempt = 0
            state = .connected
            readerTask = Task { [weak self] in
                await self?.readLoop(conn)
            }
            try conn.write(try OutgoingFrame.hello(HelloFrame(locale: locale)).encoded())
        } catch {
            connection = nil
            scheduleReconnect()
        }
    }

    private func readLoop(_ conn: UnixSocketConnection) async {
        do {
            for try await lineData in conn.lines {
                handle(lineData)
            }
            handleDisconnect(of: conn)
        } catch {
            handleDisconnect(of: conn)
        }
    }

    private func handle(_ data: Data) {
        guard let frame = try? IncomingFrame.decode(from: data) else { return }
        if case .ready(let ready) = frame {
            state = .ready(ready)
        }
        frameContinuation.yield(frame)
    }

    private func handleDisconnect(of conn: UnixSocketConnection) {
        guard connection === conn else { return }
        conn.close()
        connection = nil
        guard !stopped else { return }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        attempt += 1
        let delay = backoff.delay(forAttempt: attempt)
        state = .reconnecting(attempt: attempt, retryingAt: Date().timeIntervalSince1970 + delay)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            await self?.retryConnect()
        }
    }

    private func retryConnect() {
        reconnectTask = nil
        guard !stopped else { return }
        connectNow()
    }

    deinit {
        stateContinuation.finish()
        frameContinuation.finish()
    }
}
