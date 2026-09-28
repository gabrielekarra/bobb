import Foundation
import Testing
@testable import LeonardCore

@Suite("IPCClient against a fake unix-socket daemon")
struct IPCClientTests {

    private static let readyLine = #"{"t":"ready","ts":1.0,"model":"m","prime_ms":1.0,"decide_ms":1.0,"floor":0.6}"#

    @Test func handshakeReachesReady() async throws {
        let path = makeTemporarySocketPath()
        let daemon = try FakeUnixDaemon(path: path)
        defer { daemon.shutdown() }

        let acceptThread = Thread { daemon.acceptClient() }
        acceptThread.start()

        let client = IPCClient(socketPath: path)
        await client.start()

        let hello = await withTimeout(seconds: 3) { daemon.readLine() }
        #expect(hello?.contains("\"t\":\"hello\"") == true)
        daemon.sendLine(Self.readyLine)

        let states = await collect(client.states, count: 3, timeoutSeconds: 3)
        #expect(states.contains(.connecting))
        #expect(states.contains(.connected))
        if case .ready(let ready)? = states.last(where: { if case .ready = $0 { true } else { false } }) {
            #expect(ready.model == "m")
        } else {
            Issue.record("never reached .ready, got \(states)")
        }

        await client.stop()
    }

    @Test func unknownFrameDoesNotBlockSubsequentFrames() async throws {
        let path = makeTemporarySocketPath()
        let daemon = try FakeUnixDaemon(path: path)
        defer { daemon.shutdown() }

        let acceptThread = Thread { daemon.acceptClient() }
        acceptThread.start()

        let client = IPCClient(socketPath: path)
        await client.start()
        _ = await withTimeout(seconds: 3) { daemon.readLine() }
        daemon.sendLine(Self.readyLine)
        daemon.sendLine(#"{"t":"some_future_frame_type","ts":1.0,"anything":"goes"}"#)
        daemon.sendLine(#"{"t":"trace","ts":1.0,"event_id":"e1","stage":"gate","detail":"ok","ms":0.5}"#)

        let frames = await collect(client.frames, count: 3, timeoutSeconds: 3)
        #expect(frames.count == 3)
        if frames.count == 3 {
            guard case .ready = frames[0] else { Issue.record("frame 0 not .ready: \(frames[0])"); return }
            guard case .unknown(let type) = frames[1] else { Issue.record("frame 1 not .unknown: \(frames[1])"); return }
            #expect(type == "some_future_frame_type")
            guard case .trace(let trace) = frames[2] else { Issue.record("frame 2 not .trace: \(frames[2])"); return }
            #expect(trace.eventId == "e1")
        }

        await client.stop()
    }

    @Test func disconnectTriggersReconnectWithBackoff() async throws {
        let path = makeTemporarySocketPath()
        let daemon = try FakeUnixDaemon(path: path)
        defer { daemon.shutdown() }

        let firstAccept = Thread { daemon.acceptClient() }
        firstAccept.start()

        let client = IPCClient(socketPath: path, backoff: Backoff(initial: 0.05, multiplier: 2, max: 0.3))
        await client.start()
        _ = await withTimeout(seconds: 3) { daemon.readLine() }
        daemon.sendLine(Self.readyLine)

        let toReady = await collect(client.states, count: 3, timeoutSeconds: 3)
        #expect(toReady.contains { if case .ready = $0 { true } else { false } })

        // The daemon hangs up; the client must notice, report it honestly,
        // and come back on its own once the daemon accepts again.
        daemon.hangUpClient()

        let secondAccept = Thread {
            daemon.acceptClient()
            _ = daemon.readLine()
            daemon.sendLine(Self.readyLine)
        }
        secondAccept.start()

        let afterDrop = await collect(client.states, count: 4, timeoutSeconds: 5)
        #expect(afterDrop.contains { if case .reconnecting = $0 { true } else { false } })
        #expect(afterDrop.contains { if case .ready = $0 { true } else { false } })

        await client.stop()
    }
}

/// Runs a blocking closure off the cooperative pool and races it against a
/// timeout, for the fake daemon's blocking `readLine`/`acceptClient`.
func withTimeout<T: Sendable>(seconds: Double, _ blocking: @escaping @Sendable () -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            await withCheckedContinuation { continuation in
                let thread = Thread { continuation.resume(returning: blocking()) }
                thread.start()
            }
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? nil
    }
}
