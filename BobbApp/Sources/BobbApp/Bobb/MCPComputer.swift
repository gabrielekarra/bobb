import Foundation
import BobbCore

enum ConnectorError: LocalizedError {
    case configuration, response
    var errorDescription: String? {
        switch self {
        case .configuration: "Check the local connector configuration."
        case .response: "The local connector response was unavailable or invalid."
        }
    }
}

/// Optional stdio MCP, restricted to the executable the user configured.
/// The model never supplies a path or command; servers cannot request
/// sampling, credentials or arbitrary host tools from this client.
@MainActor
final class MCPConnection {
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
        guard configuration.enabled, configuration.executable.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: configuration.executable) else { throw ConnectorError.configuration }
        if process?.isRunning == true {
            if needsToolRefresh { try await discoverTools() }
            return
        }
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
        do {
            try process.run()
            let hello = try await request("initialize", params: .object(["protocolVersion": .string(protocolVersion), "capabilities": .object([:]),
                "clientInfo": .object(["name": "Bobb", "version": "2.0.0"])]))
            guard ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"].contains(hello["protocolVersion"]?.stringValue ?? ""),
                  hello["capabilities"]?["tools"] != nil else { throw ConnectorError.response }
            try send(.object(["jsonrpc": "2.0", "method": "notifications/initialized"]))
            try await discoverTools()
        } catch { disconnect(); throw error }
    }

    private func discoverTools() async throws {
        var discovered: [JSONValue] = [], seen: Set<String> = [], cursor: String?
        for _ in 0..<10 {
            let page = try await request("tools/list", params: cursor.map { .object(["cursor": .string($0)]) } ?? .object([:]))
            guard let entries = page["tools"]?.arrayValue else { throw ConnectorError.response }
            for value in entries where discovered.count < 200 {
                guard let name = value["name"]?.stringValue, !name.isEmpty, name.count <= 100,
                      !configuration.excludedTools.contains(name), seen.insert(name).inserted else { continue }
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
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            do { try send(.object(["jsonrpc": "2.0", "id": .string(id), "method": .string(method), "params": params])) }
            catch { waiting.removeValue(forKey: id)?.resume(throwing: error) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard let self, let pending = self.waiting.removeValue(forKey: id) else { return }
                try? self.send(.object(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": .object(["requestId": .string(id), "reason": "timeout"])]))
                pending.resume(throwing: ConnectorError.response)
            }
        }
    }
    private func send(_ value: JSONValue) throws {
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
                if let result = value["result"] { pending.resume(returning: result) }
                else { pending.resume(throwing: ConnectorError.response) }
            } else if value["method"] != nil {
                try? send(.object(["jsonrpc": "2.0", "id": rawID, "error": .object(["code": -32601, "message": "Host requests are not supported"])]))
            }
        }
    }
    func disconnect() {
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
            return ScreenObservation(app: "MCP \(configuration.id)", bundleId: "mcp:\(configuration.id)", window: "", elements: [], screenText: "Connector could not start.", unreadable: true)
        }
        if computer == nil || generation != connection.generation {
            await computer?.close(); generation = connection.generation
            let id = configuration.id
            let tools = connection.tools.compactMap { value -> AppTool? in
                guard let name = value["name"]?.stringValue else { return nil }
                return AppTool(id: name, name: name, summary: value["description"]?.stringValue ?? "",
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
