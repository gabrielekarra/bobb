import Foundation

/// App → daemon `hello`: the opening handshake, acked by `ready`.
public struct HelloFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var client: String
    public var version: String

    public init(ts: Double = Date().timeIntervalSince1970, client: String = "LeonardApp", version: String = "0.1") {
        self.ts = ts
        self.client = client
        self.version = version
    }
}

/// App → daemon `approve` / `dismiss`: the user's verdict on a `suggest`
/// decision. Shared shape; `OutgoingFrame` supplies the distinct `t`.
public struct DecisionResponseFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var decisionId: String

    enum CodingKeys: String, CodingKey {
        case ts
        case decisionId = "decision_id"
    }

    public init(ts: Double = Date().timeIntervalSince1970, decisionId: String) {
        self.ts = ts
        self.decisionId = decisionId
    }
}

/// App → daemon `policy`: changes the interruption floor at runtime.
public struct PolicyFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var floor: Double

    public init(ts: Double = Date().timeIntervalSince1970, floor: Double) {
        self.ts = ts
        self.floor = floor
    }
}

/// App → daemon `frame`: a screen capture offered to the frame gate. Not
/// emitted by either shipped `EventSource`; defined so the type is ready
/// for the screen-sensing seam and so the contract's wire shape round-trips
/// under test like every other frame.
public struct CaptureFrame: Codable, Sendable, Equatable {
    public var ts: Double
    public var id: String
    public var data: String

    public init(ts: Double = Date().timeIntervalSince1970, id: String, data: String) {
        self.ts = ts
        self.id = id
        self.data = data
    }
}

/// Every frame `LeonardApp` may send, tagged with its `t`.
public enum OutgoingFrame: Sendable, Equatable {
    case hello(HelloFrame)
    case event(EventFrame)
    case approve(DecisionResponseFrame)
    case dismiss(DecisionResponseFrame)
    case policy(PolicyFrame)
    case frame(CaptureFrame)
    /// Not emitted by anything in this target yet — the action loop's
    /// candidate enumeration is the `driver/` workstream's job. Modeled
    /// here so the wire shape exists and round-trips under test.
    case observe(ObserveFrame)

    public func encoded() throws -> Data {
        switch self {
        case .hello(let frame): try FrameCodec.data(type: "hello", payload: frame)
        case .event(let frame): try FrameCodec.data(type: "event", payload: frame)
        case .approve(let frame): try FrameCodec.data(type: "approve", payload: frame)
        case .dismiss(let frame): try FrameCodec.data(type: "dismiss", payload: frame)
        case .policy(let frame): try FrameCodec.data(type: "policy", payload: frame)
        case .frame(let frame): try FrameCodec.data(type: "frame", payload: frame)
        case .observe(let frame): try FrameCodec.data(type: "observe", payload: frame)
        }
    }
}
