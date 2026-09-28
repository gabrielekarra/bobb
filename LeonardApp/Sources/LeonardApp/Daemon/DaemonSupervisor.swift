import Foundation
import Observation
import LeonardCore

/// How to start `leonardd`.
struct DaemonCommand: Equatable {
    var executable: URL
    var arguments: [String]
    var environment: [String: String]
    var workingDirectory: URL?

    /// The daemon Leonard.app ships with: a relocatable Python in
    /// `Contents/Resources/daemon` (see `scripts/package.sh`), started as
    /// `python -m leonardd`. In development, `--daemon-dir <repo>/leonardd`
    /// runs the checkout through `uv` instead, and `--no-daemon` starts
    /// nothing, for a daemon (or `scripts/mockd.py`) the developer runs by hand.
    static func resolve(dataDir: URL, modelsDir: URL, logFile: URL) -> DaemonCommand? {
        if AppPaths.flag("--no-daemon") || AppPaths.flag("--mock-events") { return nil }
        let common = [
            "--data-dir", dataDir.path,
            "--log-file", logFile.path,
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
        ] + (AppPaths.argument("--socket").map { ["--socket", $0] } ?? [])
        var environment = cleanEnvironment()
        environment["LEONARD_MODELS_DIR"] = modelsDir.path

        if let checkout = AppPaths.argument("--daemon-dir") ?? ProcessInfo.processInfo.environment["LEONARD_DAEMON_DIR"] {
            let uv = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", NSHomeDirectory() + "/.local/bin/uv", NSHomeDirectory() + "/.cargo/bin/uv"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
            guard let uv else { return nil }
            return DaemonCommand(
                executable: URL(fileURLWithPath: uv),
                arguments: ["run", "--project", checkout, "python", "-m", "leonardd"] + common,
                environment: environment,
                workingDirectory: URL(fileURLWithPath: checkout)
            )
        }

        // The bundled interpreter is relocatable and has `leonardd` and its
        // dependencies installed in its own site-packages, so it needs no
        // PYTHONHOME or PYTHONPATH; `-s` keeps any user site-packages out.
        guard let resources = Bundle.main.resourceURL else { return nil }
        let root = resources.appendingPathComponent("daemon", isDirectory: true)
        let python = root.appendingPathComponent("python/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return nil }
        return DaemonCommand(
            executable: python,
            arguments: ["-s", "-m", "leonardd"] + common,
            environment: environment,
            workingDirectory: root
        )
    }

    /// The daemon's environment is built, not inherited: no proxy settings,
    /// no user site-packages, no stray `PYTHON*` variables, and the Hugging
    /// Face libraries told they are offline before they are imported.
    static func cleanEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": inherited["HOME"] ?? NSHomeDirectory(),
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
            "TMPDIR": inherited["TMPDIR"] ?? NSTemporaryDirectory(),
            "PYTHONNOUSERSITE": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONUNBUFFERED": "1",
            "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1",
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "TOKENIZERS_PARALLELISM": "false",
        ]
        if let user = inherited["USER"] { env["USER"] = user }
        return env
    }
}

/// Keeps `leonardd` running for as long as the app is: starts it, restarts
/// it with backoff when it exits, gives up after repeated fast crashes
/// rather than burning a core in a crash loop, and stops it on quit. The
/// daemon also watches for this process to disappear (`--parent-pid`), so a
/// force-quit app never leaves two gigabytes of model resident.
@MainActor
@Observable
final class DaemonSupervisor {
    enum State: Equatable {
        case idle
        case running(pid: Int32)
        case restarting(attempt: Int)
        /// Another daemon already owns the data directory — a developer's
        /// manual run. The app just connects to it.
        case external
        case failed(String)
        case unavailable
    }

    private(set) var state: State = .idle

    private let command: DaemonCommand?
    private var process: Process?
    private var recentExits: [Date] = []
    private var stopping = false
    private let lockExitCode: Int32 = 3

    init(command: DaemonCommand?) {
        self.command = command
    }

    var isManaged: Bool { command != nil }

    func start() {
        guard let command else {
            state = .unavailable
            return
        }
        guard process == nil else { return }
        stopping = false
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = command.environment
        process.currentDirectoryURL = command.workingDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.processExited(status: status) }
        }
        do {
            try process.run()
            self.process = process
            state = .running(pid: process.processIdentifier)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        stopping = true
        guard let process, process.isRunning else {
            self.process = nil
            return
        }
        process.terminate()
        let pid = process.processIdentifier
        // Give it two seconds to close the socket and the databases cleanly.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        self.process = nil
    }

    func restart() {
        stop()
        recentExits.removeAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.start() }
        }
    }

    private func processExited(status: Int32) {
        process = nil
        guard !stopping else {
            state = .idle
            return
        }
        if status == lockExitCode {
            state = .external
            return
        }
        let now = Date()
        recentExits = recentExits.filter { now.timeIntervalSince($0) < 120 } + [now]
        if recentExits.count >= 5 {
            state = .failed("leonardd exited \(recentExits.count) times in two minutes (last status \(status))")
            return
        }
        let attempt = recentExits.count
        state = .restarting(attempt: attempt)
        let delay = min(30.0, pow(2.0, Double(attempt)))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.start() }
        }
    }
}
