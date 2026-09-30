import AppKit
import BobbCore

/// Optional stdio endpoint for Bobb installed inside a virtual Mac.
/// It exposes only a fresh observation and actions on that observation.
/// Host approval never overrides the guest's own boundaries.
@MainActor
final class GuestMCPServer {
    private let driver = AXDriver()
    private var buffer = Data()
    private var queue: [JSONValue] = []
    private var draining = false
    private var observation: ScreenObservation?
    private var candidates: CandidateTable?
    private var keys: [KeyChord] = []
    private var apps: [AppCandidate] = []
    private var nonce = ""
    private var observedAt = Date.distantPast

    private var settings: BobbSettings {
        (try? JSONDecoder().decode(BobbSettings.self, from: Data(contentsOf: AppPaths.settingsFile))) ?? BobbSettings()
    }

    func start() {
        AppPaths.prepare()
        guard ScreenLease.shared.acquire("guest-mcp") else { exit(3) }
        DesktopActivity.shared.start()
        driver.settings = { [weak self] in self?.settings ?? BobbSettings() }
        driver.stillOwnsScreen = { ScreenLease.shared.owner == "guest-mcp" }
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in self?.receive(data) }
        }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { ScreenLease.shared.release("guest-mcp"); exit(0) }
        buffer.append(data)
        guard buffer.count <= 1_000_000 else { exit(2) }
        while let end = buffer.firstIndex(of: 10) {
            guard queue.count < 64 else { exit(2) }
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            if let value = try? JSONDecoder().decode(JSONValue.self, from: line), value["jsonrpc"]?.stringValue == "2.0" {
                queue.append(value)
            }
        }
        if !draining {
            draining = true
            Task { [weak self] in
                guard let self else { return }
                while !self.queue.isEmpty { await self.handle(self.queue.removeFirst()) }
                self.draining = false
            }
        }
    }

    private func send(_ value: JSONValue) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }
    private func result(_ id: JSONValue, _ value: JSONValue) {
        send(.object(["jsonrpc": "2.0", "id": id, "result": value]))
    }
    private func toolResult(_ value: JSONValue, error: Bool = false) -> JSONValue {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return .object(["content": .array([.object(["type": "text", "text": .string(String(decoding: data, as: UTF8.self))])]), "isError": .bool(error)])
    }
    private func handle(_ request: JSONValue) async {
        guard let id = request["id"], id != .null else { return }
        switch request["method"]?.stringValue {
        case "initialize":
            result(id, .object(["protocolVersion": "2025-11-25", "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": "Bobb Virtual Mac", "version": "2.0.0"])]))
        case "ping": result(id, .object([:]))
        case "tools/list":
            result(id, .object(["tools": .array([
                .object(["name": "observe", "description": "Read connected apps in the guest. Returns a nonce and exact control IDs, apps and keys for the next act call.",
                    "inputSchema": .object(["type": "object", "properties": .object(["goal": .object(["type": "string"])]), "additionalProperties": false])]),
                .object(["name": "act", "description": "Perform one operation offered by observe. Requires its fresh nonce. Guest ask/deny boundaries block the action; configure them in the guest, never pass an approval token.",
                    "inputSchema": .object(["type": "object", "required": .array(["nonce", "operation", "candidate_id"]),
                        "properties": .object(["nonce": .object(["type": "string"]), "operation": .object(["type": "string"]),
                            "candidate_id": .object(["type": "string"]), "text": .object(["type": "string", "maxLength": 16000]), "submit": .object(["type": "boolean"])]), "additionalProperties": false])])
            ])]))
        case "tools/call":
            let name = request["params"]?["name"]?.stringValue
            let arguments = request["params"]?["arguments"] ?? .object([:])
            if name == "observe" { result(id, toolResult(await observe(arguments))) }
            else if name == "act" { result(id, toolResult(await act(arguments))) }
            else { result(id, toolResult(.object(["error": "unknownTool"]), error: true)) }
        default:
            send(.object(["jsonrpc": "2.0", "id": id, "error": .object(["code": -32601, "message": "Method not supported"])]))
        }
    }

    private func observe(_ args: JSONValue) async -> JSONValue {
        nonce = ""; observation = nil; candidates = nil
        guard AXIsProcessTrusted(), let screen = await driver.observe() else {
            return .object(["error": "Grant Accessibility and connect apps in Bobb inside the guest."])
        }
        let goal = String((args["goal"]?.stringValue ?? "").prefix(4000))
        let ranked = CandidateRanker(limits: .init(press: 22, text: 8, scroll: 4)).rank(screen.elements, goal: goal)
        let table = CandidateTable(ranked: ranked, observation: 1)
        candidates = table; observation = screen; keys = driver.offeredKeys(for: screen)
        apps = driver.installedApps().prefix(100).enumerated().map { AppCandidate(id: "app\($0.offset + 1)", label: $0.element) }
        nonce = UUID().uuidString; observedAt = Date()
        let controls = table.candidates.map { item in JSONValue.object(["id": .string(item.id), "label": .string(item.label),
            "role": .string(item.role), "kind": .string(item.kind.rawValue)]) }
        return .object(["nonce": .string(nonce), "app": .string(screen.app), "window": .string(screen.window),
            "controls": .array(controls), "keys": .array(keys.map { .string($0.rawValue) }),
            "apps": .array(apps.map { .object(["id": .string($0.id), "label": .string($0.label)]) }),
            "text": .string(String(screen.screenText.prefix(5000)))])
    }

    private func act(_ args: JSONValue) async -> JSONValue {
        guard !nonce.isEmpty, args["nonce"]?.stringValue == nonce, Date().timeIntervalSince(observedAt) < 120,
              DesktopActivity.shared.lastInput <= observedAt,
              let screen = observation, let table = candidates,
              let operation = args["operation"]?.stringValue.flatMap(ActOperation.init(rawValue:)),
              let candidateID = args["candidate_id"]?.stringValue else { return .object(["error": "staleObservation"] ) }
        let text = args["text"]?.stringValue ?? "", submit = args["submit"]?.boolValue ?? false
        guard text.utf8.count <= 16000 else { return .object(["error": "textTooLong"]) }
        let action: DriverAction
        var label = "", element: UIElementSnapshot?, key: KeyChord?
        if operation == .openApp {
            guard let app = apps.first(where: { $0.id == candidateID }) else { return .object(["error": "unknownApp"]) }
            label = app.label; action = .openApp(name: label)
        } else if operation == .key {
            guard let chord = KeyChord(rawValue: candidateID), keys.contains(chord) else { return .object(["error": "unknownKey"]) }
            key = chord; label = chord.symbol; action = .key(chord)
        } else {
            guard let control = table.candidates.first(where: { $0.id == candidateID }), let target = table.keys[candidateID],
                  let snapshot = table.byId[candidateID] else { return .object(["error": "unknownControl"]) }
            element = snapshot; label = control.label
            switch operation {
            case .click, .select: guard control.kind == .press else { return .object(["error": "wrongKind"]) }; action = .press(key: target)
            case .open: guard control.kind == .press else { return .object(["error": "wrongKind"]) }; action = .open(key: target)
            case .type, .typeText: guard control.kind == .text, !text.isEmpty else { return .object(["error": "wrongKind"]) }; action = .type(key: target, text: text, submit: submit)
            case .scrollDown, .scrollUp: guard control.kind == .scroll else { return .object(["error": "wrongKind"]) }; action = .scroll(key: target, down: operation == .scrollDown)
            default: return .object(["error": "unsupportedOperation"])
            }
        }
        let live = settings
        guard live.actingEnabled, live.bobb.boundaries.canWork() else { return .object(["error": "actingDisabled"]) }
        let policy = ActionPolicy(approval: live.actingApproval, extraProtected: live.extraProtectedApps, boundaries: live.bobb.boundaries)
        let verdict = policy.evaluate(operation: operation, label: label, role: element?.role ?? "",
            appBundleId: operation == .openApp ? driver.bundleIdentifier(forApp: label) : screen.bundleId,
            appName: operation == .openApp ? label : screen.app, secure: element?.isSecure ?? false, submit: submit,
            multiline: element?.role == "AXTextArea", window: screen.window, key: key,
            defaultButton: screen.defaultButton, context: screen.screenText, typedText: text)
        guard verdict == .allow else {
            switch verdict {
            case .ask(let reason): return .object(["blocked": "Guest approval is required. Review this action in the guest's Boundaries.", "reason": .string(reason)])
            case .deny(let reason): return .object(["blocked": "Guest boundaries denied this action.", "reason": .string(reason)])
            case .allow: break
            }
            return .object(["error": "blocked"])
        }
        nonce = "" // A side effect can never be replayed with the same observation.
        let outcome = await driver.perform(action)
        await driver.settle()
        return .object(["outcome": .string(outcome == .ok ? "ok" : "staleOrFailed")])
    }
}
