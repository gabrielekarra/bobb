import Foundation
import BobbCore

enum ConnectorError: LocalizedError {
    case configuration, response, authorization, sessionExpired, registration, http(Int)
    var errorDescription: String? {
        switch self {
        case .configuration: "Check this connector’s address, executable and configured credentials."
        case .response: "The connector response was unavailable or invalid; verify any action already submitted."
        case .authorization: "Sign in to this connector, or check its configured credentials."
        case .sessionExpired: "The connector session expired. Restart the task after verifying any submitted action."
        case .registration: "This service requires a registered OAuth client id with native loopback redirects."
        case .http(let code): "The connector returned HTTP \(code); verify any submitted action before retrying."
        }
    }
}

/// Optional stdio MCP, restricted to the executable the user configured.
/// The model never supplies a path or command; servers cannot request
/// sampling, credentials or arbitrary host tools from this client.
@MainActor
final class MCPConnection {
    private var remote: MCPHTTPTransport?
    private var connected = false
    private var jobs: [String: Task<Void, Never>] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var waiting: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private(set) var tools: [JSONValue] = []
    private(set) var generation = 0
    private var needsToolRefresh = false
    private let configuration: MCPConfiguration
    private let environment: [String: String]
    private let protocolVersion: String
    init(configuration: MCPConfiguration, environment: [String: String] = [:], protocolVersion: String = "2025-11-25") {
        self.configuration = configuration; self.environment = environment; self.protocolVersion = protocolVersion
    }

    func connect() async throws {
        guard configuration.enabled else { throw ConnectorError.configuration }
        if connected {
            if needsToolRefresh { try await discoverTools() }
            return
        }
        do {
            if configuration.transport == .stdio { try launch() }
            else {
                let transport = try MCPHTTPTransport(configuration: configuration); remote = transport
                transport.receive = { [weak self] value in
                    if let data = try? JSONEncoder().encode(value) { self?.receive(data + Data([10])) }
                }
                transport.ended = { [weak self] in self?.disconnect() }
                try await transport.start()
            }
            let hello = try await request("initialize", params: .object(["protocolVersion": .string(protocolVersion), "capabilities": .object([:]),
                "clientInfo": .object(["name": "Bobb", "version": "2.0.0"])]))
            guard let version = hello["protocolVersion"]?.stringValue,
                  ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"].contains(version),
                  hello["capabilities"]?["tools"] != nil else { throw ConnectorError.response }
            remote?.protocolVersion = version
            try await send(.object(["jsonrpc": "2.0", "method": "notifications/initialized"]))
            connected = true; remote?.listen()
            try await discoverTools()
        } catch { disconnect(); throw error }
    }
    private func launch() throws {
        guard configuration.executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: configuration.executable) else { throw ConnectorError.configuration }
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: configuration.executable)
        process.arguments = configuration.arguments
        // Do not inherit API keys, developer credentials or shell startup files.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "HOME": NSHomeDirectory(),
                               "LANG": "en_US.UTF-8"]
        process.environment?.merge(environment) { _, trusted in trusted }
        process.environment?.merge(try MCPSecrets.environment(configuration)) { _, configured in configured }
        if let directory = configuration.workingDirectory {
            guard directory.hasPrefix("/"), FileManager.default.fileExists(atPath: directory) else { throw ConnectorError.configuration }
            process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        }
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in Task { @MainActor [weak self] in self?.disconnect() } }
        self.process = process
        try process.run()
    }

    private func discoverTools() async throws {
        var discovered: [JSONValue] = [], seen: Set<String> = [], cursor: String?
        for _ in 0..<10 {
            let page = try await request("tools/list", params: cursor.map { .object(["cursor": .string($0)]) } ?? .object([:]))
            guard let entries = page["tools"]?.arrayValue else { throw ConnectorError.response }
            for value in entries where discovered.count < 200 {
                guard let name = value["name"]?.stringValue, !name.isEmpty, name.count <= 100,
                      !configuration.excludedTools.contains(name),
                      let schema = value["inputSchema"], schema.objectValue != nil, ((try? JSONEncoder().encode(schema).count) ?? Int.max) <= 64_000,
                      seen.insert(name).inserted else { continue }
                discovered.append(value)
            }
            cursor = page["nextCursor"]?.stringValue
            if cursor == nil || discovered.count >= 200 { break }
        }
        tools = discovered.sorted { ($0["name"]?.stringValue ?? "") < ($1["name"]?.stringValue ?? "") }
        needsToolRefresh = false; generation += 1
    }

    func call(name: String, arguments: JSONValue) async throws -> JSONValue {
        guard configuration.enabled, tools.contains(where: { $0["name"]?.stringValue == name }), arguments.objectValue != nil else { throw ConnectorError.configuration }
        return try await request("tools/call", params: .object(["name": .string(name), "arguments": arguments]))
    }

    private func request(_ method: String, params: JSONValue) async throws -> JSONValue {
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiting[id] = continuation
                jobs[id] = Task { [weak self] in
                    guard let self else { return }
                    do {
                        try Task.checkCancellation()
                        try await self.send(.object(["jsonrpc": "2.0", "id": .string(id), "method": .string(method), "params": params]))
                    } catch { self.fail(id, error: error) }
                }
                timers[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    self?.cancel(id, error: ConnectorError.response)
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel(id, error: CancellationError()) } }
    }
    private func fail(_ id: String, error: Error) {
        jobs.removeValue(forKey: id)?.cancel(); timers.removeValue(forKey: id)?.cancel()
        waiting.removeValue(forKey: id)?.resume(throwing: error)
    }
    private func cancel(_ id: String, error: Error) {
        guard waiting[id] != nil else { return }
        fail(id, error: error)
        Task { [weak self] in
            try? await self?.send(.object(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": .object(["requestId": .string(id), "reason": "cancelled"])]))
        }
    }
    private func send(_ value: JSONValue) async throws {
        if let remote { try await remote.send(value); return }
        guard let input, process?.isRunning == true else { throw ConnectorError.response }
        try input.write(contentsOf: JSONEncoder().encode(value) + Data([10]))
    }
    private func receive(_ data: Data) {
        if data.isEmpty { disconnect(); return }
        buffer.append(data)
        guard buffer.count <= 1_000_000 else { disconnect(); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: line), value["jsonrpc"]?.stringValue == "2.0" else { continue }
            if value["method"]?.stringValue == "notifications/tools/list_changed" { needsToolRefresh = true }
            guard let rawID = value["id"], rawID != .null else { continue }
            if let id = rawID.stringValue, let pending = waiting.removeValue(forKey: id) {
                jobs.removeValue(forKey: id)?.cancel(); timers.removeValue(forKey: id)?.cancel()
                if let result = value["result"] { pending.resume(returning: result) }
                else { pending.resume(throwing: ConnectorError.response) }
            } else if value["method"] != nil {
                Task { [weak self] in try? await self?.send(.object(["jsonrpc": "2.0", "id": rawID, "error": .object(["code": -32601, "message": "Host requests are not supported"])])) }
            }
        }
    }
    func disconnect() {
        connected = false; remote?.close(); remote = nil
        jobs.values.forEach { $0.cancel() }; jobs.removeAll()
        timers.values.forEach { $0.cancel() }; timers.removeAll()
        output?.readabilityHandler = nil
        try? input?.close(); try? output?.close(); input = nil; output = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil; buffer.removeAll()
        tools.removeAll(); needsToolRefresh = false
        let pending = waiting; waiting.removeAll()
        for continuation in pending.values { continuation.resume(throwing: ConnectorError.response) }
    }
}

@MainActor
final class MCPComputer: TaskDriver {
    private let connection: MCPConnection
    private let configuration: MCPConfiguration
    private var computer: AppToolComputer?
    private var generation = -1
    private var closed = false
    var enabled: () -> Bool
    init(configuration: MCPConfiguration, goal: String, enabled: @escaping () -> Bool) {
        connection = MCPConnection(configuration: configuration); self.configuration = configuration; self.enabled = enabled
    }
    var requiresAccessibility: Bool { false }
    func observe() async -> ScreenObservation? {
        guard !closed, enabled() else { return nil }
        do { try await connection.connect() } catch {
            return ScreenObservation(app: "MCP \(configuration.id)", bundleId: "mcp:\(configuration.id)", window: "", elements: [], screenText: error.localizedDescription, unreadable: true)
        }
        if computer == nil || generation != connection.generation {
            await computer?.close(); generation = connection.generation
            let id = configuration.id
            let tools = connection.tools.compactMap { value -> AppTool? in
                guard let name = value["name"]?.stringValue else { return nil }
                return AppTool(id: name, name: name, summary: String((value["description"]?.stringValue ?? "").prefix(1000)),
                    bundleId: "mcp:\(id)", app: "MCP \(id)", category: .execute,
                    schema: value["inputSchema"] ?? ["type": "object"], validatesSchema: false)
            }
            computer = AppToolComputer(tools: tools, name: "MCP \(id)", bundleId: "mcp:\(id)",
                permitted: { [weak self] _ in self?.enabled() == true && self?.closed == false },
                execute: { [weak self] tool, arguments in
                    guard let self, !self.closed, self.enabled() else { throw ConnectorError.configuration }
                    return try await self.connection.call(name: tool.id, arguments: arguments)
                })
        }
        return await computer?.observe()
    }
    func installedApps() -> [String] { [] }
    func offeredKeys(for observation: ScreenObservation) -> [KeyChord] { [] }
    func permissionDetail(for action: DriverAction) -> String? { computer?.permissionDetail(for: action) }
    func actionContext(for action: DriverAction) -> DriverActionContext? { computer?.actionContext(for: action) }
    func perform(_ action: DriverAction) async -> DriverResult {
        guard !closed, enabled(), let computer else { connection.disconnect(); return .failed("connectorDisabled") }
        return await computer.perform(action)
    }
    func settle() async {}
    func undoLast() async -> Bool { false }
    func supportsUndo(for action: DriverAction) -> Bool { false }
    func completionProblem(goal: String) async -> String? { await computer?.completionProblem(goal: goal) ?? "No connector result has been observed." }
    func shutdown() { closed = true; connection.disconnect() }
    func close() async { shutdown(); await computer?.close() }
}
