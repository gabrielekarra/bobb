import Foundation
@testable import LeonardCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A minimal, blocking `AF_UNIX` server used only to drive `IPCClient`
/// under test: bind, listen, accept one connection at a time, read/write
/// NDJSON lines. Deliberately dumb — the point is to control exactly what
/// bytes the "daemon" sends and when, including sending nothing, sending
/// garbage, and hanging up.
final class FakeUnixDaemon: @unchecked Sendable {
    let path: String
    private var listenFd: Int32 = -1
    private var clientFd: Int32 = -1

    init(path: String) throws {
        self.path = path
        unlink(path)
        let fd = socket(AF_UNIX, POSIX.streamSocket, 0)
        guard fd >= 0 else { throw SocketError(description: "socket() failed") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        #if os(macOS)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        let pathBytes = Array(path.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { rawPath in
            rawPath.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { charPath in
                for (index, byte) in pathBytes.enumerated() { charPath[index] = CChar(bitPattern: byte) }
                charPath[pathBytes.count] = 0
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { sunPtr -> Int32 in
            sunPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { throw SocketError(description: "bind() failed: \(String(cString: strerror(errno)))") }
        guard listen(fd, 4) == 0 else { throw SocketError(description: "listen() failed") }
        self.listenFd = fd
    }

    /// Blocks until a client connects.
    func acceptClient() {
        clientFd = accept(listenFd, nil, nil)
    }

    func sendLine(_ text: String) {
        var data = Data(text.utf8)
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            _ = POSIX.write(clientFd, raw.baseAddress, raw.count)
        }
    }

    /// Reads one newline-delimited line, blocking. `nil` on EOF.
    func readLine() -> String? {
        var buffer: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let n = POSIX.read(clientFd, &byte, 1)
            if n <= 0 { return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self) }
            if byte == 0x0A { return String(decoding: buffer, as: UTF8.self) }
            buffer.append(byte)
        }
    }

    func hangUpClient() {
        if clientFd >= 0 { _ = POSIX.close(clientFd) }
        clientFd = -1
    }

    func shutdown() {
        hangUpClient()
        if listenFd >= 0 { _ = POSIX.close(listenFd) }
        unlink(path)
    }

    deinit {
        shutdown()
    }
}

func makeTemporarySocketPath() -> String {
    let dir = FileManager.default.temporaryDirectory
    return dir.appendingPathComponent("leonard-test-\(UUID().uuidString).sock").path
}
