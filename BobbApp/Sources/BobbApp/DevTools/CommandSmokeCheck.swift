import AppKit
import SwiftUI
import BobbCore

/// Exercises the production command field, IPC routing, task controller and
/// WebKit driver against a public page. Uses a separate daemon data directory.
@MainActor
func runCommandSmokeCheck() {
    Task {
        let state = AppState()
        state.entitlement = .community
        state.settings.watching = false
        state.settings.memoryEnabled = false
        let socket = AppPaths.argument("--socket") ?? "/private/tmp/bobb-command-smoke.sock"
        let client = IPCClient(socketPath: socket)
        let coordinator = BobbCoordinator(state: state, client: client, eventSource: MockEventSource(scenario: [], loop: false))
        let tasks = TaskController(state: state, coordinator: coordinator)
        let computer = WebComputer(agentId: "command-smoke-" + UUID().uuidString, boundaries: { state.settings.bobb.boundaries })
        var cua: CUABrowserComputer?
        var routedURL = ""
        if AppPaths.flag("--use-cua") {
            tasks.isolatedBrowserFactory = { url in
                routedURL = url.absoluteString
                cua = CUABrowserComputer(url:url,boundaries:{ state.settings.bobb.boundaries })
                return cua
            }
        }
        if !AppPaths.flag("--use-cua") { tasks.isolatedBrowserFactory = { url in
            guard computer.open(url) else { return nil }
            computer.inspect(); return computer
        } }
        let bar = CommandBarController(state: state, coordinator: coordinator)
        bar.startTask = { goal, url, app in tasks.start(goal: goal, browserURL: url, preferredApp: app) }
        coordinator.start()
        let deadline = Date().addingTimeInterval(90)
        while !state.connection.isReady && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        let goal = AppPaths.argument("--check-command") ?? "Cerca su YouTube lofi hip hop. Fermati quando vedi i risultati."
        guard state.connection.isReady else { print("Command smoke: engine not ready"); exit(1) }
        bar.request(goal)
        print("Command smoke: submitted through the unified command field")
        var result = "timeout"
        while Date() < deadline {
            if let error = state.ask.error { result = error; break }
            if case .finished(let status, let detail) = state.task?.phase {
                result = status.rawValue + ": " + detail; break
            }
            if case .waitingForPermission = state.task?.phase {
                result = "website requires user approval"; break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        @MainActor func glassCount(_ view: NSView) -> Int {
            (String(describing: type(of: view)) == "NSGlassEffectView" ? 1 : 0) + view.subviews.reduce(0) { $0 + glassCount($1) }
        }
        let glass = NSApp.windows.compactMap(\.contentView).reduce(0) { $0 + glassCount($1) }
        let active: any TaskDriver = cua ?? computer
        let observation = await active.observe()
        let problem = await active.completionProblem(goal: goal)
        let currentURL = cua?.currentURL ?? computer.webView.url
        let expectedQuery = AppPaths.argument("--expect-query")
        let queryKey = AppPaths.argument("--query-key") ?? "q"
        let actualQuery = currentURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == queryKey }?.value?.replacingOccurrences(of: "+", with: " ")
        let queryMatches = expectedQuery == nil || actualQuery == expectedQuery
        let passed = result.hasPrefix("done:") && problem == nil && currentURL != nil && glass > 0 && queryMatches
        let report: [String: Any] = ["passed": passed, "status": result,
            "url": currentURL?.absoluteString ?? "", "initialURL":routedURL, "controls": observation?.elements.count ?? 0,
            "nativeGlassViews": glass, "queryMatches": queryMatches, "verification": problem ?? "No driver observation error"]
        if let output = AppPaths.argument("--report"), let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: output))
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let json = String(data: data, encoding: .utf8) { print(json) }
        tasks.stop(); coordinator.stop()
        exit(passed ? 0 : 1)
    }
}
