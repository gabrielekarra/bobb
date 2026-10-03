import AppKit
import BobbCore

/// Isolated CUA browser for explicit developer checks. Production tasks use
/// UserBrowserComputer and the user's native browser session.
@MainActor
final class CUABrowserComputer: TaskDriver {
    var usesSharedDesktop: Bool { false }
    var requiresAccessibility: Bool { false }
    private let connection: MCPConnection
    private let session = "bobb-" + UUID().uuidString.lowercased()
    private let initialURL: URL
    private let boundaries: () -> BoundaryConfiguration
    private var target = "", tab = ""
    private var pid = 0, windowID = 0
    private var refs: [Int: JSONValue] = [:]
    private(set) var currentURL: URL?
    private var error = ""
    private var closed = false
    private var stage = "initialization"
    init?(url: URL, boundaries: @escaping () -> BoundaryConfiguration) {
        guard let executable = AppPaths.cuaDriver else { return nil }
        initialURL = url; self.boundaries = boundaries
        connection = MCPConnection(configuration: MCPConfiguration(id: "cua", executable: executable.path,
            arguments: ["mcp", "--direct", "--embedded", "--host-bundle-id", "com.bobb.app"], enabled: true),
            environment: ["CUA_DRIVER_RS_TELEMETRY_ENABLED": "0", "CUA_TELEMETRY_ENABLED": "0"], protocolVersion: "2025-06-18")
    }
    private func permits(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme ?? ""), let host = url.host,
              url.user == nil, url.password == nil else { return false }
        let config = boundaries()
        return config.canWork() && config.webApp(host: host)?.mode(.navigate) != .deny && config.webApp(host: host) != nil
    }
    private func call(_ name: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard !closed else { throw ConnectorError.response }
        var arguments = arguments; arguments["session"] = .string(session)
        let result = try await connection.call(name: name, arguments: .object(arguments))
        guard result["isError"]?.boolValue != true, let value = result["structuredContent"],
              value["status"]?.stringValue != "error", value["status"]?.stringValue != "refused" else { throw ConnectorError.response }
        return value
    }
    private var address: [String: JSONValue] { ["target_id": .string(target), "tab_id": .string(tab)] }
    private func prepare() async throws {
        guard permits(initialURL) else { throw ConnectorError.configuration }
        try await connection.connect()
        stage = "browser launch"
        let prepared = try await call("browser_prepare", ["allow_launch": true, "profile": .object(["mode": "isolated_new"])])
        guard prepared["prepared"]?.boolValue == true, let number = prepared["prepared_pid"]?.numberValue else { throw ConnectorError.response }
        pid = Int(number)
        stage = "window discovery"
        // Exclude menu bars, tooltips and helper panels. Only this newly
        // launched, driver-owned process is eligible, never personal Chrome.
        var candidates: [JSONValue] = []
        for _ in 0..<12 {
            let listed = try await call("list_windows", ["pid": .number(Double(pid))])
            candidates = (listed["windows"]?.arrayValue ?? []).filter {
                $0["pid"]?.numberValue == Double(pid) && ($0["bounds"]?["height"]?.numberValue ?? 0) > 200 && ($0["bounds"]?["width"]?.numberValue ?? 0) > 500
            }
            if !candidates.isEmpty { break }
            try await Task.sleep(for:.milliseconds(250))
        }
        guard candidates.count == 1, let id = candidates[0]["window_id"]?.numberValue else { throw ConnectorError.response }
        windowID = Int(id)
        stage = "exact window binding"
        let bound = try await call("get_browser_state", ["pid": .number(Double(pid)), "window_id": .number(Double(windowID))])
        guard bound["binding_quality"]?.stringValue == "exact", bound["mutation_allowed"]?.boolValue == true,
              bound["endpoint_access_class"]?.stringValue == "driver_owned",
              let targetID = bound["target_id"]?.stringValue, case .array(let tabs)? = bound["tabs"],
              tabs.count == 1, let tabID = tabs[0]["tab_id"]?.stringValue else { throw ConnectorError.response }
        target = targetID; tab = tabID
        stage = "navigation"
        var navigation = address; navigation["url"] = .string(initialURL.absoluteString)
        _ = try await call("browser_navigate", navigation)
        currentURL = initialURL
    }
    func observe() async -> ScreenObservation? {
        guard !closed else { return nil }
        do {
            if target.isEmpty { try await prepare(); await settle() }
            stage = "page observation"
            var arguments = address; arguments["snapshot_format"] = "semantic_v2"
            let snapshot = try await call("get_browser_state", arguments)
            guard let rawURL = snapshot["page"]?["url"]?.stringValue, let url = URL(string: rawURL), permits(url) else { return nil }
            currentURL = url; refs.removeAll()
            guard case .array(let entries)? = snapshot["refs"] else { throw ConnectorError.response }
            var elements: [UIElementSnapshot] = []
            for (key, entry) in entries.prefix(500).enumerated() {
                let role = entry["role"]?.stringValue ?? "generic"
                let name = entry["name"]?.stringValue ?? ""
                let actions = entry["actions"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let secure = role == "password" || entry["states"]?["protected"]?.boolValue == true
                guard !secure, entry["ref"]?.stringValue != nil else { continue }
                refs[key] = entry
                let text = actions.contains("type")
                let scroll = actions.contains("scroll")
                let mapped = text ? "AXTextField" : scroll ? "AXScrollArea" : role == "link" ? "AXLink" : "AXButton"
                elements.append(UIElementSnapshot(key: key, role: mapped, title: name.isEmpty ? (scroll ? "Page" : role) : name,
                    value: entry["value"]?.stringValue ?? "", enabled: entry["states"]?["disabled"]?.boolValue != true,
                    focused: entry["states"]?["focused"]?.boolValue == true,
                    actions: actions.contains("click") ? ["AXPress"] : [], valueSettable: text))
            }
            error = ""
            let host = url.host ?? ""
            let specific = boundaries().app(bundleId:"web:" + host,name:host) != nil
            return ScreenObservation(app: specific ? host : "Bobb Browser", bundleId: specific ? "web:" + host : "bobb.browser",
                window: url.absoluteString, elements: elements,
                screenText: "Source URL: \(url.absoluteString)\n" + String((snapshot["outline"]?.stringValue ?? "").prefix(18000)))
        } catch {
            self.error = "CUA: \(stage). \(error.localizedDescription)"
            return ScreenObservation(app: "Bobb Browser", bundleId: "bobb.browser", window: "", elements: [], screenText: self.error, unreadable: true)
        }
    }
    func perform(_ action: DriverAction) async -> DriverResult {
        guard let currentURL, permits(currentURL), !closed else { return .failed("unavailableWebsite") }
        var args = address
        let key: Int
        switch action {
        case .press(let k), .open(let k), .type(let k, _, _), .scroll(let k, _): key = k
        default: return .failed("unsupportedCUABrowserAction")
        }
        guard let element = refs[key], let ref = element["ref"]?.stringValue else { return .stale }
        args["ref"] = .string(ref)
        // Request CUA's documented DOM delivery explicitly. Native global
        // mouse/keyboard injection is never a fallback for this browser.
        args["input_route"] = "dom_event"
        let supported = element["actions"]?.arrayValue?.compactMap(\.stringValue) ?? []
        do {
            switch action {
            case .press, .open:
                guard supported.contains("click") else { return .stale }
                _ = try await call("browser_click", args)
            case .type(_, let text, let submit):
                guard supported.contains("type"), text.utf8.count <= 64000 else { return .stale }
                guard !submit else { return .failed("Use the page's Search or Continue button to submit.") }
                args.removeValue(forKey: "input_route")
                args["text"] = .string(text); args["replace"] = true
                _ = try await call("browser_type", args)
            case .scroll(_, let down):
                guard supported.contains("scroll") else { return .stale }
                args["action"] = "scroll"; args["delta_y"] = .number(down ? 600 : -600)
                _ = try await call("browser_pointer", args)
            default: return .failed("unsupportedCUABrowserAction")
            }
            refs.removeAll(); return .ok
        } catch { return .failed("CUA refused a stale or unavailable page control.") }
    }
    func installedApps() -> [String] { [] }
    func offeredKeys(for observation: ScreenObservation) -> [KeyChord] { [] }
    func settle() async { try? await Task.sleep(for: .milliseconds(800)) }
    func undoLast() async -> Bool { false }
    func completionProblem(goal: String) async -> String? { error.isEmpty ? nil : error }
    func close() async {
        if !closed {
            _ = try? await call("end_session"); closed = true; connection.disconnect()
            // Only a pid attested by browser_prepare as newly driver-owned
            // can be cleaned up. Never quit an existing personal browser.
            if pid > 0 { NSRunningApplication(processIdentifier:pid_t(pid))?.terminate() }
        }
    }
}
