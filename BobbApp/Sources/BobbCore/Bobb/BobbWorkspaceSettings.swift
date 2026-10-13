import Foundation

public struct MCPConfiguration: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var executable: String
    public var arguments: [String]
    public var enabled: Bool
    public var environmentReferences: [String: String]
    public var excludedTools: [String]
    public var workingDirectory: String?
    public init(id: String, executable: String, arguments: [String] = [], enabled: Bool = false,
                environmentReferences: [String: String] = [:], excludedTools: [String] = [], workingDirectory: String? = nil) {
        self.id = id; self.executable = executable; self.arguments = arguments; self.enabled = enabled
        self.environmentReferences = environmentReferences; self.excludedTools = excludedTools; self.workingDirectory = workingDirectory
    }
    private enum CodingKeys: String, CodingKey { case id, executable, arguments, enabled, environmentReferences, excludedTools, workingDirectory }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); executable = try c.decode(String.self, forKey: .executable)
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        environmentReferences = try c.decodeIfPresent([String: String].self, forKey: .environmentReferences) ?? [:]
        excludedTools = try c.decodeIfPresent([String].self, forKey: .excludedTools) ?? []
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
    }
}

/// Common BoBe/Vox/desktop MCP stdio format. Parse first; the app resolves
/// executable names and moves env values into Keychain before persistence.
public struct MCPImportedServer: Decodable, Sendable {
    public var command: String
    public var args: [String]
    public var env: [String: String]
    public var excludedTools: [String]
    public var workingDirectory: String?
    private enum CodingKeys: String, CodingKey { case command, args, env, excluded_tools, excludedTools, workingDirectory, url }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.url) { throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "Only local stdio connectors can be imported.") }
        command = try c.decode(String.self, forKey: .command)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        excludedTools = try c.decodeIfPresent([String].self, forKey: .excludedTools) ?? c.decodeIfPresent([String].self, forKey: .excluded_tools) ?? []
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        guard !command.isEmpty, command.utf8.count <= 4096, args.count <= 100, env.count <= 100,
              env.allSatisfy({ Self.allowedEnvironmentKey($0.key) && $0.value.utf8.count <= 16_000 }) else {
            throw DecodingError.dataCorruptedError(forKey: .env, in: c, debugDescription: "Invalid or unsafe connector environment.")
        }
    }
    public static func allowedEnvironmentKey(_ key: String) -> Bool {
        let upper = key.uppercased()
        guard let first = key.first, first.isASCII && (first.isLetter || first == "_"),
              key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return false }
        return !["PATH", "HOME", "ENV", "BASH_ENV", "PYTHONPATH", "PYTHONHOME", "NODE_OPTIONS", "RUBYOPT", "PERL5OPT", "SHELLOPTS", "BASHOPTS"].contains(upper)
            && !upper.hasPrefix("LD_") && !upper.hasPrefix("DYLD_")
    }
    public static func parse(_ data: Data) throws -> [String: MCPImportedServer] {
        struct Configuration: Decodable { var mcpServers: [String: MCPImportedServer] }
        guard data.count <= 1_000_000 else { throw CocoaError(.fileReadTooLarge) }
        let servers = try JSONDecoder().decode(Configuration.self, from: data).mcpServers
        guard servers.count <= 50, servers.keys.allSatisfy({ !$0.isEmpty && $0.count <= 100 && !$0.contains(where: { $0.isNewline || $0 == "\0" }) }) else { throw CocoaError(.fileReadCorruptFile) }
        return servers
    }
}

public struct BobbWorkspaceSettings: Codable, Sendable, Equatable {
    public var boundaries = BoundaryConfiguration()
    public var backgroundEnabled = false
    public var activeAgent = "bobb"
    public var iMessageEnabled = false
    /// A single exact iMessage address belonging to the user; never a group.
    public var selfAddress = ""
    public var localModelPath = ""
    public var connectors: [MCPConfiguration] = []
    public init() {}
}

public struct LocalModelOption: Sendable, Equatable {
    public var parameters: String
    public var minimumMemoryGB: Int
    /// Generation weights plus the shared 4.5 GB Kev checkpoint.
    public var estimatedWeightsGB: Double
    public static let options: [LocalModelOption] = [
        .init(parameters: "4B", minimumMemoryGB: 16, estimatedWeightsGB: 7.5),
        .init(parameters: "7–8B", minimumMemoryGB: 24, estimatedWeightsGB: 9.5),
        .init(parameters: "14B", minimumMemoryGB: 32, estimatedWeightsGB: 13.5),
        .init(parameters: "30–32B", minimumMemoryGB: 64, estimatedWeightsGB: 24.5),
        .init(parameters: "70B", minimumMemoryGB: 128, estimatedWeightsGB: 48.5),
    ]
    /// Conservative budgets, leaving memory for macOS, KV cache and apps.
    /// These are size estimates, not a guarantee for any checkpoint.
    public static func recommended(memoryBytes: UInt64) -> LocalModelOption {
        options.last { UInt64($0.minimumMemoryGB) * 1_073_741_824 <= memoryBytes } ?? options[0]
    }

    /// Leave room for the user's apps. All profiles share Qwen and Kev.
    public static func backgroundConcurrency(memoryBytes: UInt64) -> Int {
        memoryBytes <= 16 * 1_073_741_824 ? 1 : 3
    }
}
