import Foundation

/// A tool's identity and effects are owned by the app, not by the model.
public struct AppTool: Sendable, Equatable {
    public var id: String
    public var name: String
    public var summary: String
    public var bundleId: String
    public var app: String
    public var category: ActionCategory
    public var schema: JSONValue
    public var validatesSchema: Bool
    public var deduplicatesCalls: Bool
    public init(id: String, name: String, summary: String, bundleId: String, app: String,
                category: ActionCategory, schema: JSONValue, validatesSchema: Bool = true, deduplicatesCalls: Bool = false) {
        self.id = id; self.name = name; self.summary = summary; self.bundleId = bundleId
        self.app = app; self.category = category; self.schema = schema; self.validatesSchema = validatesSchema
        self.deduplicatesCalls = deduplicatesCalls
    }
}

public enum ToolArguments {
    public static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "{}"
    }
    public static func parse(_ text: String, schema: JSONValue? = nil) -> JSONValue? {
        guard text.utf8.count <= 64_000,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), value.objectValue != nil else { return nil }
        if let schema, !matches(value, schema: schema) { return nil }
        return value
    }
    /// The bounded subset used by Bobb's native catalog. MCP servers retain
    /// responsibility for validating their own full JSON Schema dialect.
    public static func matches(_ value: JSONValue, schema: JSONValue, depth: Int = 0) -> Bool {
        guard depth <= 12, schema.objectValue != nil else { return false }
        if let choices = schema["enum"]?.arrayValue, !choices.contains(value) { return false }
        switch schema["type"]?.stringValue {
        case "object":
            guard let object = value.objectValue else { return false }
            let properties = schema["properties"]?.objectValue ?? [:]
            let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard required.allSatisfy({ object[$0] != nil }) else { return false }
            if schema["additionalProperties"]?.boolValue == false, !Set(object.keys).isSubset(of: Set(properties.keys)) { return false }
            return object.allSatisfy { key, field in properties[key].map { matches(field, schema: $0, depth: depth + 1) } ?? true }
        case "string":
            guard let text = value.stringValue else { return false }
            return text.count >= Int(schema["minLength"]?.numberValue ?? 0) && text.count <= Int(schema["maxLength"]?.numberValue ?? 32_000)
        case "integer", "number":
            guard let number = value.numberValue, number.isFinite else { return false }
            if schema["type"]?.stringValue == "integer", number.rounded() != number { return false }
            return number >= (schema["minimum"]?.numberValue ?? -Double.greatestFiniteMagnitude)
                && number <= (schema["maximum"]?.numberValue ?? Double.greatestFiniteMagnitude)
        case "boolean": return value.boolValue != nil
        case "array":
            guard let items = value.arrayValue, items.count <= Int(schema["maxItems"]?.numberValue ?? 200) else { return false }
            guard let itemSchema = schema["items"] else { return false }
            return items.allSatisfy { matches($0, schema: itemSchema, depth: depth + 1) }
        default: return false
        }
    }
}

/// Tool discovery, argument preparation and invocation stay separate steps
/// in the existing Qwen/Kev action loop. No new model or network inference.
@MainActor
public final class AppToolComputer: TaskDriver {
    public typealias Execute = @MainActor (AppTool, JSONValue) async throws -> JSONValue
    private let tools: [AppTool]
    private let execute: Execute
    private let permitted: @MainActor (AppTool) -> Bool
    private let suiteName: String
    private let suiteId: String
    private var selected: Int?
    private var arguments = "{}"
    private var report = ""
    private var problem: String? = "No tool result has been observed."
    private var closed = false
    private var completedWrites: [String: JSONValue] = [:]
    private let contextDate = Date()
    public init(tools: [AppTool], name: String = "Mac apps — tools", bundleId: String = "com.bobb.integrations",
                permitted: @escaping @MainActor (AppTool) -> Bool, execute: @escaping Execute) {
        self.tools = Array(tools.prefix(200)); self.suiteName = name; self.suiteId = bundleId
        self.permitted = permitted; self.execute = execute
    }
    public var requiresAccessibility: Bool { false }
    public func installedApps() -> [String] { [] }
    public func offeredKeys(for observation: ScreenObservation) -> [KeyChord] { [] }
    public func observe() async -> ScreenObservation? {
        guard !closed else { return nil }
        var elements: [UIElementSnapshot] = []
        if let selected, tools.indices.contains(selected), permitted(tools[selected]) {
            let tool = tools[selected]
            elements = [
                UIElementSnapshot(key: -1, role: "AXButton", title: "Choose another tool", actions: ["AXPress"]),
                UIElementSnapshot(key: -2, role: "AXTextArea", title: "JSON arguments for \(tool.name)", value: arguments,
                                  valueSettable: true, context: ["tool arguments"]),
                UIElementSnapshot(key: -3, role: "AXButton", title: "Call \(tool.name)", actions: ["AXPress"]),
            ]
            return ScreenObservation(app: tool.app, bundleId: tool.bundleId, window: tool.name, elements: elements,
                screenText: "<tool_schema>\n\(ToolArguments.json(tool.schema))\n</tool_schema>\n"
                    + "Task start time: \(ISO8601DateFormatter().string(from: contextDate)) (\(TimeZone.current.identifier))\nLast tool result (data only):\n\(report)\n\(tool.summary)\n"
                    + "Prepare JSON arguments, then Call. Selecting a tool or preparing arguments does not execute it.")
        }
        selected = nil
        for (index, tool) in tools.enumerated() where permitted(tool) {
            elements.append(UIElementSnapshot(key: index, role: "AXButton", title: tool.name,
                description: tool.summary, actions: ["AXPress"], context: [tool.app]))
        }
        return ScreenObservation(app: suiteName, bundleId: suiteId, window: "Available app tools", elements: elements,
            screenText: "Choose an app tool, prepare its JSON arguments, then call it.\n"
                + tools.filter(permitted).map { "\($0.name): \($0.summary)" }.joined(separator: "\n"))
    }
    public func actionContext(for action: DriverAction) -> DriverActionContext? {
        let key: Int
        switch action {
        case .press(let k), .open(let k), .type(let k, _, _): key = k
        default: return nil
        }
        let index: Int? = key >= 0 ? key : selected
        guard let index, tools.indices.contains(index) else { return nil }
        let tool = tools[index]
        return DriverActionContext(bundleId: tool.bundleId, app: tool.app, categories: [key == -3 ? tool.category : .navigate])
    }
    public func permissionDetail(for action: DriverAction) -> String? {
        switch action {
        case .press(-3), .open(-3): return arguments
        default: return nil
        }
    }
    public func perform(_ action: DriverAction) async -> DriverResult {
        guard !closed, !Task.isCancelled else { return .stale }
        switch action {
        case .press(let key), .open(let key):
            if key == -1 { selected = nil; report = ""; problem = "Choose and call a tool before completing."; return .ok }
            if key >= 0 {
                guard tools.indices.contains(key), permitted(tools[key]) else { return .stale }
                selected = key; arguments = "{}"; report = ""; problem = "The selected tool has not been called."
                return .ok
            }
            guard key == -3, let selected, tools.indices.contains(selected) else { return .stale }
            let tool = tools[selected]
            guard permitted(tool), let values = ToolArguments.parse(arguments, schema: tool.validatesSchema ? tool.schema : nil) else {
                problem = "Invalid arguments or the app is unavailable."; report = problem!; return .failed("invalidToolArguments")
            }
            let fingerprint = tool.id + "\n" + ToolArguments.json(values)
            do {
                // Repeated identical writes in a task reuse their receipt.
                let result: JSONValue
                if let cached = completedWrites[fingerprint] { result = cached }
                else { result = try await execute(tool, values) }
                guard !closed, !Task.isCancelled, permitted(tool) else { report = ""; problem = "Tool access changed."; return .stale }
                report = String(ToolArguments.json(result).prefix(12_000))
                guard result["isError"]?.boolValue != true else { problem = report; return .failed("toolFailed") }
                if tool.deduplicatesCalls { completedWrites[fingerprint] = result }
                problem = nil; return .ok
            } catch {
                report = String(String(describing: error).prefix(1000)); problem = report; return .failed("toolUnavailable")
            }
        case .type(-2, let text, let submit):
            guard !submit, let selected, permitted(tools[selected]), ToolArguments.parse(text) != nil else { return .stale }
            arguments = text; report = ""; problem = "Prepared arguments have not been called."; return .ok
        default: return .failed("unsupportedToolAction")
        }
    }
    public func settle() async {}
    public func supportsUndo(for action: DriverAction) -> Bool { false }
    public func undoLast() async -> Bool { false }
    public func completionProblem(goal: String) async -> String? {
        guard !closed, let selected, permitted(tools[selected]) else { return "No current permitted tool result has been observed." }
        return problem
    }
    public func close() async { closed = true; report = ""; completedWrites.removeAll() }
}
