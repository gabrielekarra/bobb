import Foundation
import Observation
import BobbCore

/// How to start `bobbd`.
struct DaemonCommand: Equatable {
    var executable: URL
    var arguments: [String]
    var environment: [String: String]
    var workingDirectory: URL?

    /// The daemon Bobb.app ships with: a relocatable Python in
    /// `Contents/Resources/daemon` (see `scripts/package.sh`), started as
    /// `python -m bobbd`. In development, `--daemon-dir <repo>/bobbd`
    /// uses the checkout's virtual environment, prepared by `uv sync`.
    /// `--no-daemon` starts
    /// nothing, for a daemon (or `scripts/mockd.py`) the developer runs by hand.
    static func resolve(dataDir: URL, modelsDir: URL, logFile: URL, modelPath: String = "") -> DaemonCommand? {
        if AppPaths.flag("--no-daemon") || AppPaths.flag("--mock-events") { return nil }
        let common = [
            "--data-dir", dataDir.path,
            "--log-file", logFile.path,
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
        ] + (AppPaths.argument("--socket").map { ["--socket", $0] } ?? [])
          + (modelPath.isEmpty ? [] : ["--model", modelPath])
        var environment = cleanEnvironment()
        environment["BOBB_MODELS_DIR"] = modelsDir.path

        if let checkout = AppPaths.daemonDirectory {
            let python = URL(fileURLWithPath: checkout).appendingPathComponent(".venv/bin/python3")
            guard FileManager.default.isExecutableFile(atPath: python.path) else { return nil }
            // Launch Python as the app's direct child. An intermediate `uv run`
            // process would invalidate bobbd's parent-pid lifetime check.
            return DaemonCommand(
                executable: python,
                arguments: ["-s", "-m", "bobbd"] + common,
                environment: environment,
                workingDirectory: URL(fileURLWithPath: checkout)
            )
        }

        // The bundled interpreter is relocatable and has `bobbd` and its
        // dependencies installed in its own site-packages, so it needs no
        // PYTHONHOME or PYTHONPATH; `-s` keeps any user site-packages out.
        guard let resources = Bundle.main.resourceURL else { return nil }
        let root = resources.appendingPathComponent("daemon", isDirectory: true)
        let python = root.appendingPathComponent("python/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return nil }
        return DaemonCommand(
            executable: python,
            arguments: ["-s", "-m", "bobbd"] + common,
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

/// Keeps `bobbd` running for as long as the app is: starts it, restarts
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

    private var command: DaemonCommand?
    private var process: Process?
    private var recentExits: [Date] = []
    private var stopping = false
    private var generation = 0
    private let lockExitCode: Int32 = 3

    init(command: DaemonCommand?) {
        self.command = command
    }

    var isManaged: Bool { command != nil }
    func reconfigure(_ command: DaemonCommand?) {
        self.command = command
        restart()
    }

    func start() {
        guard let command else {
            state = .unavailable
            return
        }
        guard process == nil else { return }
        generation += 1
        let currentGeneration = generation
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
            Task { @MainActor [weak self] in
                guard self?.generation == currentGeneration else { return }
                self?.processExited(status: status)
            }
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
        generation += 1
        state = .idle
        guard let process, process.isRunning else {
            self.process = nil
            return
        }
        process.terminate()
        let pid = process.processIdentifier
        // Give it two seconds to close the socket and the databases cleanly.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
        self.process = nil
    }

    func restart() {
        stop()
        recentExits.removeAll()
        let currentGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            MainActor.assumeIsolated {
                guard self?.generation == currentGeneration else { return }
                self?.start()
            }
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
            state = .failed("bobbd exited \(recentExits.count) times in two minutes (last status \(status))")
            return
        }
        let attempt = recentExits.count
        state = .restarting(attempt: attempt)
        let delay = min(30.0, pow(2.0, Double(attempt)))
        let currentGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard self?.generation == currentGeneration else { return }
                self?.start()
            }
        }
    }
}
