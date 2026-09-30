import Foundation

/// One thing the user did while showing Bobb how.
public enum ObservedAction: Sendable, Equatable {
    case pressed(label: String, role: String, app: String)
    case typed(label: String, text: String, app: String)
    case openedApp(String)
}

/// Turns what the user does while showing Bobb how into the steps of a
/// procedure: the same operations a task uses, named by the words on
/// screen. Repeated clicks on the same thing collapse; secure fields never
/// reach here.
public struct DemonstrationRecorder: Sendable {
    public private(set) var steps: [TaskStepLine] = []
    public let goal: String
    public var maxSteps = 25

    public init(goal: String) {
        self.goal = goal
    }

    public mutating func record(_ action: ObservedAction) {
        guard steps.count < maxSteps else { return }
        let line: TaskStepLine
        switch action {
        case .pressed(let label, _, let app):
            guard !label.isEmpty else { return }
            line = TaskStepLine(id: steps.count + 1, operation: .click, target: label, app: app, outcome: .user)
        case .typed(let label, let text, let app):
            guard !text.isEmpty else { return }
            if let last = steps.last, last.operation == .type, last.target == label, last.app == app {
                steps[steps.count - 1].text = text
                return
            }
            line = TaskStepLine(id: steps.count + 1, operation: .type, target: label, text: text, app: app, outcome: .user)
        case .openedApp(let name):
            guard !name.isEmpty else { return }
            if let last = steps.last, last.operation == .openApp, last.target == name { return }
            line = TaskStepLine(id: steps.count + 1, operation: .openApp, target: name, app: name, outcome: .user)
        }
        if let last = steps.last, last.operation == line.operation, last.target == line.target, last.app == line.app,
           line.operation == .click {
            return
        }
        steps.append(line)
    }

    public var frame: ProcedureRecordFrame {
        ProcedureRecordFrame(goal: goal, steps: steps.map { step in
            ProcedureStep(operation: step.operation == .type ? "TYPE" : step.operation.rawValue, target: step.target,
                          app: step.app, text: step.text)
        })
    }
}

public struct ProcedureStep: Codable, Sendable, Equatable {
    public var operation: String
    public var target: String
    public var app: String
    public var text: String?

    public init(operation: String, target: String, app: String, text: String? = nil) {
        self.operation = operation
        self.target = target
        self.app = app
        self.text = text
    }
}

/// App → daemon `procedure.record`: what the user showed.
public struct ProcedureRecordFrame: Codable, Sendable, Equatable {
    public var id: String
    public var goal: String
    public var steps: [ProcedureStep]

    public init(id: String = RequestFrame.newID(), goal: String, steps: [ProcedureStep]) {
        self.id = id
        self.goal = goal
        self.steps = steps
    }
}

/// A way of doing something that Bobb learned, as the daemon lists it.
public struct LearnedProcedure: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var ts: Double
    public var goal: String
    public var steps: [ProcedureStep]
    public var source: String
    public var uses: Int

    public init(id: String, ts: Double, goal: String, steps: [ProcedureStep], source: String, uses: Int = 0) {
        self.id = id
        self.ts = ts
        self.goal = goal
        self.steps = steps
        self.source = source
        self.uses = uses
    }
}

public struct ProceduresFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var requestId: String?
    public var items: [LearnedProcedure]

    enum CodingKeys: String, CodingKey {
        case ts, items
        case requestId = "request_id"
    }

    public init(ts: Double, requestId: String?, items: [LearnedProcedure]) {
        self.ts = ts
        self.requestId = requestId
        self.items = items
    }
}

public struct ProcedureDeleteFrame: Codable, Sendable, Equatable {
    public var id: String
    public var procedureId: String

    enum CodingKeys: String, CodingKey {
        case id
        case procedureId = "procedure_id"
    }

    public init(id: String = RequestFrame.newID(), procedureId: String) {
        self.id = id
        self.procedureId = procedureId
    }
}
