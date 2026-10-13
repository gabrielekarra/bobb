import Foundation
import Darwin

/// Fixed executable and argv only: model text never becomes shell source.
enum AppIntegrationProcess {
    static func run(executable: String, arguments: [String]) async throws -> String {
        let job = Job(executable: executable, arguments: arguments)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in job.start(continuation) }
        } onCancel: { job.stop("The integration was cancelled.") }
    }
    static func runShortcut(name: String, input: String?) async throws -> String {
        guard !name.hasPrefix("-"), !name.contains("\n") else { throw NativeAppTools.Failure.unavailable("Unsupported shortcut name.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bobb-shortcut-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("output.txt")
        var arguments = ["run", name, "--output-path", output.path]
        if let input {
            let file = folder.appendingPathComponent("input.txt")
            try Data(input.utf8).write(to: file, options: .atomic)
            arguments += ["--input-path", file.path]
        }
        let stdout = try await run(executable: "/usr/bin/shortcuts", arguments: arguments)
        guard FileManager.default.fileExists(atPath: output.path) else { return stdout }
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= 64_000 else { throw NativeAppTools.Failure.unavailable("Shortcut output exceeds 64 KB.") }
        let data = try Data(contentsOf: output)
        guard let text = String(data: data, encoding: .utf8) else { throw NativeAppTools.Failure.unavailable("The shortcut returned binary output. Inspect it in Shortcuts.") }
        return text
    }
    private final class Job: @unchecked Sendable {
        private let process = Process()
        private let pipe = Pipe()
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String, Error>?
        private var stopped: String?
        init(executable: String, arguments: [String]) {
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        }
        func start(_ continuation: CheckedContinuation<String, Error>) {
            lock.lock()
            if let stopped { lock.unlock(); continuation.resume(throwing: NativeAppTools.Failure.unavailable(stopped)); return }
            self.continuation = continuation
            do { try process.run() } catch { self.continuation = nil; lock.unlock(); continuation.resume(throwing: error); return }
            lock.unlock()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    var output = Data()
                    while let chunk = try pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                        output.append(chunk)
                        if output.count > 64_000 { stop("Integration output exceeds 64 KB."); return }
                    }
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { stop("Integration exited with status \(process.terminationStatus)."); return }
                    finish(String(decoding: output, as: UTF8.self))
                } catch { stop("Integration output was unavailable.") }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) { [weak self] in self?.stop("Integration timed out after 60 seconds.") }
        }
        private func finish(_ value: String) {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            try? pipe.fileHandleForReading.close(); pending?.resume(returning: value)
        }
        func stop(_ reason: String) {
            lock.lock()
            guard stopped == nil else { lock.unlock(); return }
            stopped = reason; let pending = continuation; continuation = nil
            let running = process.isRunning; let pid = process.processIdentifier
            lock.unlock()
            if running { process.terminate(); DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in if process.isRunning { kill(pid, SIGKILL) } } }
            try? pipe.fileHandleForReading.close()
            pending?.resume(throwing: NativeAppTools.Failure.unavailable(reason))
        }
    }
}
