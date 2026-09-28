import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct SocketError: Error, CustomStringConvertible {
    let description: String
}

/// A connected `AF_UNIX` `SOCK_STREAM` socket, split into a blocking
/// background reader that yields complete NDJSON lines and a synchronous
/// writer for the same fd. Read and write happen on different threads by
/// design (one blocking `recv` loop, one caller-driven `send`), which is the
/// ordinary, safe way to use a single socket fd bidirectionally.
final class UnixSocketConnection: @unchecked Sendable {
    private let fd: Int32
    private let closeLock = NSLock()
    private var closed = false

    let lines: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(path: String) throws {
        let pathBytes = Array(path.utf8)
        var addr = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            throw SocketError(description: "socket path too long: \(path)")
        }
        addr.sun_family = sa_family_t(AF_UNIX)
        #if os(macOS)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        withUnsafeMutablePointer(to: &addr.sun_path) { rawPath in
            rawPath.withMemoryRebound(to: CChar.self, capacity: capacity) { charPath in
                for (index, byte) in pathBytes.enumerated() {
                    charPath[index] = CChar(bitPattern: byte)
                }
                charPath[pathBytes.count] = 0
            }
        }

        let newFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard newFd >= 0 else {
            throw SocketError(description: "socket() failed: \(String(cString: strerror(errno)))")
        }

        let connectResult = withUnsafePointer(to: &addr) { sunPtr -> Int32 in
            sunPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(newFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(newFd)
            throw SocketError(description: "connect() failed: \(message)")
        }

        self.fd = newFd
        var capturedContinuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.lines = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
        startReading()
    }

    private func startReading() {
        let thread = Thread { [fd, continuation] in
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            readLoop: while true {
                let n = chunk.withUnsafeMutableBytes { raw -> Int in
                    Darwin.read(fd, raw.baseAddress, raw.count)
                }
                if n > 0 {
                    buffer.append(contentsOf: chunk[0..<n])
                    while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                        let line = buffer[buffer.startIndex..<newlineIndex]
                        continuation.yield(Data(line))
                        buffer.removeSubrange(buffer.startIndex...newlineIndex)
                    }
                } else if n == 0 {
                    continuation.finish()
                    break readLoop
                } else {
                    if errno == EINTR { continue }
                    continuation.finish(throwing: SocketError(description: "read() failed: \(String(cString: strerror(errno)))"))
                    break readLoop
                }
            }
        }
        thread.name = "leonard.ipc.reader"
        thread.start()
    }

    func write(_ data: Data) throws {
        var framed = data
        framed.append(0x0A)
        try framed.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    throw SocketError(description: "write() failed: \(String(cString: strerror(errno)))")
                }
            }
        }
    }

    func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    deinit {
        close()
    }
}
