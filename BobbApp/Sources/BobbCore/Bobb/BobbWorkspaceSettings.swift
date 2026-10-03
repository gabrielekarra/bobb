import Foundation

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
