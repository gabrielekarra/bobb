import Foundation
import LeonardCore

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
    private let configuration: MCPConfiguration
    init(configuration: MCPConfiguration) { self.configuration = configuration }

    func connect() async throws {
        guard configuration.enabled, configuration.executable.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: configuration.executable) else { throw CloudError.configuration }
        if process?.isRunning == true { return }
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: configuration.executable)
        process.arguments = configuration.arguments
        // Do not inherit API keys, developer credentials or shell startup files.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "HOME": NSHomeDirectory(),
                               "LANG": "en_US.UTF-8"]
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
            let hello = try await request("initialize", params: .object(["protocolVersion": "2025-11-25", "capabilities": .object([:]),
                "clientInfo": .object(["name": "Bobb", "version": "2.0.0"])]))
            guard ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"].contains(hello["protocolVersion"]?.stringValue ?? ""),
                  hello["capabilities"]?["tools"] != nil else { throw CloudError.response }
            try send(.object(["jsonrpc": "2.0", "method": "notifications/initialized"]))
            tools = []
            var cursor: String?
            for _ in 0..<10 {
                let page = try await request("tools/list", params: cursor.map { .object(["cursor": .string($0)]) } ?? .object([:]))
                if case .array(let entries)? = page["tools"] { tools += entries.filter { $0["name"]?.stringValue != nil }.prefix(200 - tools.count) }
                cursor = page["nextCursor"]?.stringValue
                if cursor == nil || tools.count >= 200 { break }
            }
        } catch { disconnect(); throw error }
    }

    func call(name: String, arguments: JSONValue) async throws -> JSONValue {
        guard configuration.enabled, tools.contains(where: { $0["name"]?.stringValue == name }), arguments.objectValue != nil else { throw CloudError.configuration }
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
                pending.resume(throwing: CloudError.response)
            }
        }
    }
    private func send(_ value: JSONValue) throws {
        guard let input, process?.isRunning == true else { throw CloudError.response }
        try input.write(contentsOf: JSONEncoder().encode(value) + Data([10]))
    }
    private func receive(_ data: Data) {
        if data.isEmpty { disconnect(); return }
        buffer.append(data)
        guard buffer.count <= 1_000_000 else { disconnect(); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: line), value["jsonrpc"]?.stringValue == "2.0" else { continue }
            guard let rawID = value["id"], rawID != .null else { continue }
            if let id = rawID.stringValue, let pending = waiting.removeValue(forKey: id) {
                if let result = value["result"] { pending.resume(returning: result) }
                else { pending.resume(throwing: CloudError.response) }
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
        let pending = waiting; waiting.removeAll()
        for continuation in pending.values { continuation.resume(throwing: CloudError.response) }
    }
}

@MainActor
final class MCPComputer: TaskDriver {
    private let connection: MCPConnection
    private let id: String
    private let goal: String
    private var tools: [JSONValue] = []
    private var arguments: [Int: String] = [:]
    private var report = ""
    var enabled: () -> Bool
    init(configuration: MCPConfiguration, goal: String, enabled: @escaping () -> Bool) {
        connection = MCPConnection(configuration: configuration); id = configuration.id; self.goal = goal; self.enabled = enabled
    }
    func observe() async -> ScreenObservation? {
        guard enabled() else { return nil }
        do { try await connection.connect() } catch {
            return ScreenObservation(app: "MCP \(id)", bundleId: "mcp:\(id)", window: "", elements: [], screenText: "Connector could not start.")
        }
        if tools.isEmpty {
            let words = Set(Tokens.words(goal))
            tools = connection.tools.sorted {
                Set(Tokens.words($0["name"]?.stringValue ?? "")).intersection(words).count > Set(Tokens.words($1["name"]?.stringValue ?? "")).intersection(words).count
            }.prefix(10).map { $0 }
        }
        var elements: [UIElementSnapshot] = []
        var descriptions: [String] = []
        for (index, tool) in tools.enumerated() {
            let name = tool["name"]?.stringValue ?? ""
            elements.append(UIElementSnapshot(key: index * 2, role: "AXTextArea", title: "JSON arguments for \(name)",
                                               value: arguments[index, default: "{}"], valueSettable: true))
            elements.append(UIElementSnapshot(key: index * 2 + 1, role: "AXButton", title: "Execute \(name)", actions: ["AXPress"]))
            let schema = (try? JSONEncoder().encode(tool["inputSchema"] ?? .object([:]))) ?? Data()
            descriptions.append("\(name): \(tool["description"]?.stringValue ?? "")\nArguments schema: \(String(decoding: schema, as: UTF8.self))")
        }
        return ScreenObservation(app: "MCP \(id)", bundleId: "mcp:\(id)", window: id, elements: elements,
                                 screenText: descriptions.joined(separator: "\n") + "\nLast tool result:\n" + report)
    }
    func installedApps() -> [String] { [] }
    func offeredKeys(for observation: ScreenObservation) -> [KeyChord] { [] }
    func perform(_ action: DriverAction) async -> DriverResult {
        guard enabled() else { connection.disconnect(); return .failed("connectorDisabled") }
        switch action {
        case .type(let key, let text, let submit):
            guard !submit, key % 2 == 0, tools.indices.contains(key / 2), text.utf8.count <= 64_000,
                  let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), value.objectValue != nil else { return .stale }
            arguments[key / 2] = text; return .ok
        case .press(let key), .open(let key):
            let index = key / 2
            guard key % 2 == 1, tools.indices.contains(index), let name = tools[index]["name"]?.stringValue,
                  let values = try? JSONDecoder().decode(JSONValue.self, from: Data(arguments[index, default: "{}"].utf8)) else { return .stale }
            do {
                let result = try await connection.call(name: name, arguments: values)
                report = String(decoding: try JSONEncoder().encode(result), as: UTF8.self).prefix(12000).description
                return result["isError"]?.boolValue == true ? .failed("toolFailed") : .ok
            } catch { return .failed("toolUnavailable") }
        default: return .failed("unsupportedConnectorAction")
        }
    }
    func settle() async {}
    func undoLast() async -> Bool { false }
    func close() { connection.disconnect() }
}
