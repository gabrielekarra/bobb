import AppKit
import ApplicationServices
import BobbCore

/// Typed native macOS access through CUA. Task policy stays in TaskLoop;
/// every element is addressed by the driver's current snapshot token.
@MainActor
final class CUANativeComputer: TaskDriver {
    private let connection: MCPConnection
    private let session = "bobb-native-" + UUID().uuidString.lowercased()
    private let settings: () -> BobbSettings
    private let ownsScreen: () -> Bool
    private var tokens: [Int: String] = [:]
    private var pid: pid_t = 0
    private var windowID = 0
    private var websiteURL: URL?
    init?(settings: @escaping () -> BobbSettings, ownsScreen: @escaping () -> Bool) {
        guard let executable = AppPaths.cuaDriver else { return nil }
        self.settings = settings; self.ownsScreen = ownsScreen
        connection = MCPConnection(configuration: MCPConfiguration(id: "cua-native", executable: executable.path,
            arguments: ["mcp", "--direct", "--embedded", "--host-bundle-id", "com.bobb.app"], enabled: true),
            environment: ["CUA_DRIVER_RS_TELEMETRY_ENABLED":"0", "CUA_TELEMETRY_ENABLED":"0"], protocolVersion: "2025-06-18")
    }
    private func allowed(_ app: NSRunningApplication) -> Bool {
        let s = settings(), name = app.localizedName ?? ""
        return s.bobb.boundaries.canWork() && s.bobb.boundaries.app(bundleId: app.bundleIdentifier, name: name) != nil
            && !ActionPolicy(extraProtected:s.extraProtectedApps).isProtected(bundleId: app.bundleIdentifier, appName:name)
    }
    private func call(_ name: String, _ arguments: [String:JSONValue] = [:]) async throws -> JSONValue {
        var arguments = arguments; arguments["session"] = .string(session)
        let result = try await connection.call(name:name,arguments:.object(arguments))
        guard result["isError"]?.boolValue != true, let content = result["structuredContent"],
              content["status"]?.stringValue != "error" else { throw ConnectorError.response }
        return content
    }
    func observe() async -> ScreenObservation? {
        guard ownsScreen(), AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier, allowed(app) else { return nil }
        tokens.removeAll(); pid = app.processIdentifier
        websiteURL = nil
        let nativeTitle = AX.element(AX.application(pid), "AXFocusedWindow").flatMap { AX.string($0, "AXTitle") } ?? ""
        guard !ScreenMemoryPolicy().isPrivateWindow(title: nativeTitle) else { return nil }
        if let page = AX.pageURL(pid: pid), ["http", "https"].contains(page.scheme ?? "") {
            guard settings().bobb.boundaries.webApp(host: page.host ?? "", browserBundleId: app.bundleIdentifier ?? "", browserName: app.localizedName ?? "") != nil else { return nil }
            websiteURL = page
        }
        do {
            try await connection.connect()
            let list = try await call("list_windows", ["pid":.number(Double(pid)), "on_screen_only":true])
            let windows = list["windows"]?.arrayValue?.filter {
                ($0["bounds"]?["height"]?.numberValue ?? 0)>100 && ($0["bounds"]?["width"]?.numberValue ?? 0)>100 && $0["layer"]?.numberValue==0
            } ?? []
            // CUA reports exact native ids in front-to-back order. No title
            // guessing or unscoped desktop capture is allowed.
            guard let first = windows.first, let number = first["window_id"]?.numberValue else { return nil }
            windowID = Int(number)
            let snapshot = try await call("get_window_state", ["pid":.number(Double(pid)), "window_id":.number(Double(windowID)),
                "include_screenshot":false, "include_accessibility_tree":true, "max_elements":500, "max_depth":20])
            guard ownsScreen(), allowed(app) else { return nil }
            var elements: [UIElementSnapshot] = []
            for (key, element) in (snapshot["elements"]?.arrayValue ?? []).enumerated() {
                let rawRole = element["role"]?.stringValue ?? "AXUnknown", label = element["label"]?.stringValue ?? ""
                let role = rawRole.hasPrefix("AX") ? rawRole : "AX" + rawRole.prefix(1).uppercased() + rawRole.dropFirst()
                guard !role.lowercased().contains("secure"), !(element["subrole"]?.stringValue ?? "").lowercased().contains("secure"),
                      element["secure"]?.boolValue != true, element["states"]?["protected"]?.boolValue != true,
                      let token = element["element_token"]?.stringValue else { continue }
                tokens[key] = token
                let actions = element["actions"]?.arrayValue?.compactMap(\.stringValue) ?? []
                elements.append(UIElementSnapshot(key:key, role:role, title:label, value:element["value"]?.stringValue ?? "",
                    enabled:element["enabled"]?.boolValue != false, actions:actions,
                    valueSettable:actions.contains("AXSetValue") || element["value_settable"]?.boolValue == true))
            }
            return ScreenObservation(app:app.localizedName ?? "", bundleId:app.bundleIdentifier,
                window:snapshot["window_title"]?.stringValue ?? "", elements:elements,
                screenText:String(elements.map { "\($0.role) \($0.title) \($0.value)" }.joined(separator:"\n").prefix(12000)),
                sourceURL: websiteURL?.absoluteString)
        } catch { return ScreenObservation(app:app.localizedName ?? "",bundleId:app.bundleIdentifier,window:"",elements:[],screenText:"CUA native observation unavailable.",unreadable:true) }
    }
    func installedApps() -> [String] {
        InstalledApps.shared.names().filter { name in
            let s = settings(), bundle = bundleIdentifier(forApp:name)
            return s.bobb.boundaries.app(bundleId:bundle,name:name) != nil && !ActionPolicy(extraProtected:s.extraProtectedApps).isProtected(bundleId:bundle,appName:name)
        }
    }
    func bundleIdentifier(forApp name: String) -> String? { InstalledApps.shared.url(for:name).flatMap { Bundle(url:$0)?.bundleIdentifier } }
    func perform(_ action: DriverAction) async -> DriverResult {
        guard ownsScreen(), AXIsProcessTrusted() else { return .failed("accessibilityRequired") }
        if case .openApp(let name) = action {
            guard installedApps().contains(name), let bundle = bundleIdentifier(forApp:name) else { return .stale }
            do {
                let result = try await call("launch_app",["bundle_id":.string(bundle)])
                return result["pid"]?.numberValue != nil ? .ok : .failed("CUA did not return an exact app target.")
            } catch { return .failed("CUA app launch unavailable.") }
        }
        guard let app = NSRunningApplication(processIdentifier:pid), allowed(app),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return .failed("unavailableApp") }
        if let websiteURL {
            guard AX.pageURL(pid: pid) == websiteURL,
                  settings().bobb.boundaries.webApp(host: websiteURL.host ?? "", browserBundleId: app.bundleIdentifier ?? "", browserName: app.localizedName ?? "") != nil else { return .stale }
        }
        var args: [String:JSONValue] = ["pid":.number(Double(pid)), "window_id":.number(Double(windowID))]
        do {
            switch action {
            case .press(let key), .open(let key):
                guard let token = tokens[key] else { return .stale }; args["element_token"] = .string(token)
                args["action"] = action == .open(key:key) ? "open" : "press"; args["delivery_mode"] = "background"
                _ = try await call("click",args)
            case .type(let key,let text,let submit):
                guard !submit, let token = tokens[key], text.utf8.count<=64000 else { return .stale }
                args["element_token"] = .string(token); args["value"] = .string(text)
                _ = try await call("set_value",args)
            case .scroll(let key,let down):
                guard let token = tokens[key] else { return .stale }; args["element_token"] = .string(token)
                args["direction"] = down ? "down":"up"; args["delivery_mode"] = "background"
                _ = try await call("scroll",args)
            case .key(let chord):
                let parts = chord.rawValue.split(separator:"_").map(String.init)
                args["delivery_mode"] = "background"
                if parts.count>1 { args["keys"] = .array(parts.map(JSONValue.string)); _ = try await call("hotkey",args) }
                else { args["key"] = .string(chord.rawValue); _ = try await call("press_key",args) }
            default:return .failed("unsupportedCUANativeAction")
            }
            tokens.removeAll(); return .ok
        } catch { return .failed("CUA refused a stale or unavailable native control.") }
    }
    func settle() async { try? await Task.sleep(for:.milliseconds(500)) }
    func undoLast() async -> Bool { false }
    func close() async { _ = try? await call("end_session"); connection.disconnect() }
}

/// Preserve the mature native AX route; CUA supplies an additional route
/// for surfaces it cannot read. Actions always use the last observed driver.
@MainActor
final class NativeComputer: TaskDriver {
    private let primary: AXDriver
    private let fallback: CUANativeComputer?
    private var active: any TaskDriver
    init(primary: AXDriver, fallback: CUANativeComputer?) { self.primary=primary; self.fallback=fallback; active=primary }
    func observe() async -> ScreenObservation? {
        if let screen = await primary.observe(), !screen.elements.isEmpty, !screen.unreadable { active=primary; return screen }
        if let fallback, let screen = await fallback.observe() { active=fallback; return screen }
        active=primary; return await primary.observe()
    }
    func installedApps() -> [String] { primary.installedApps() }
    func bundleIdentifier(forApp name: String) -> String? { primary.bundleIdentifier(forApp:name) }
    func offeredKeys(for observation: ScreenObservation) -> [KeyChord] { active.offeredKeys(for:observation) }
    func permissionDetail(for action: DriverAction) -> String? { active.permissionDetail(for:action) }
    func perform(_ action: DriverAction) async -> DriverResult {
        if case .openApp = action { active = primary; return await primary.perform(action) }
        return await active.perform(action)
    }
    func settle() async { await active.settle() }
    func undoLast() async -> Bool { await active.undoLast() }
    func completionProblem(goal: String) async -> String? { await active.completionProblem(goal:goal) }
    func close() async { await fallback?.close() }
}
