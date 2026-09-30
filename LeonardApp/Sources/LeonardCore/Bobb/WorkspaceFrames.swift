import Foundation

public struct WorkspaceCommandFrame: Codable, Sendable, Equatable {
    public var id: String
    public var op: String
    public var payload: JSONValue
    public init(op: String = "list", payload: JSONValue = .object([:]), id: String = RequestFrame.newID()) {
        self.id = id; self.op = op; self.payload = payload
    }
}

public struct WorkspaceStateFrame: Codable, Sendable, Equatable {
    public var requestId: String?
    public var result: JSONValue?
    public var agents: [BobbAgent]
    public var jobs: [JSONValue]
    public var projects: [JSONValue]
    public var runs: [WorkRun]
    public var routines: [JSONValue]
    enum CodingKeys: String, CodingKey { case result, agents, jobs, projects, runs, routines; case requestId = "request_id" }
}

public struct BobbAgent: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var character: String
    public var profile: String
    public init(id: String = "bobb", name: String = "Bobb", character: String = "Practical and concise.", profile: String = "general") {
        self.id = id; self.name = name; self.character = character; self.profile = profile
    }
    public var introduction: String {
        if L10n.code == "it" {
            return "Sono \(name). \(character) Posso lavorare sulle app che colleghi, preparare risposte e seguire progetti. Ti chiederò il permesso secondo i tuoi Confini."
        }
        return "I'm \(name). \(character) I can work in the apps you connect, prepare replies and follow projects. I'll ask according to your Boundaries."
    }
}

public struct WorkRun: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var agentId: String
    public var projectId: String?
    public var goal: String
    public var surface: String
    public var url: String
    public var status: String
    public var report: String
    public var taskId: String?
    public var created: Double
    enum CodingKeys: String, CodingKey {
        case id, goal, surface, url, status, report, created
        case agentId = "agent_id", projectId = "project_id", taskId = "task_id"
    }
}
