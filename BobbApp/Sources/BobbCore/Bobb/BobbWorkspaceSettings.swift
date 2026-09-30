import Foundation

public struct CloudConfiguration: Codable, Sendable, Equatable {
    public var enabled = false
    /// OpenAI-compatible chat-completions URL, set explicitly by the user.
    public var endpoint = ""
    public var model = ""
    public var privateTerms: [String] = []
    public init() {}
}

public struct MCPConfiguration: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var executable: String
    public var arguments: [String]
    public var enabled: Bool
    public init(id: String, executable: String, arguments: [String] = [], enabled: Bool = false) {
        self.id = id; self.executable = executable; self.arguments = arguments; self.enabled = enabled
    }
}

public struct BobbWorkspaceSettings: Codable, Sendable, Equatable {
    public var boundaries = BoundaryConfiguration()
    public var cloud = CloudConfiguration()
    public var backgroundEnabled = false
    public var activeAgent = "bobb"
    public var speakResponses = false
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
    public var estimatedWeightsGB: Double
    public static let options: [LocalModelOption] = [
        .init(parameters: "3B", minimumMemoryGB: 8, estimatedWeightsGB: 1.8),
        .init(parameters: "7–8B", minimumMemoryGB: 16, estimatedWeightsGB: 5),
        .init(parameters: "14B", minimumMemoryGB: 24, estimatedWeightsGB: 9),
        .init(parameters: "30–32B", minimumMemoryGB: 48, estimatedWeightsGB: 20),
        .init(parameters: "70B", minimumMemoryGB: 96, estimatedWeightsGB: 44),
    ]
    /// Conservative budgets, leaving memory for macOS, KV cache and apps.
    /// These are size estimates, not a guarantee for any checkpoint.
    public static func recommended(memoryBytes: UInt64) -> LocalModelOption {
        options.last { UInt64($0.minimumMemoryGB) * 1_073_741_824 <= memoryBytes } ?? options[0]
    }
}
