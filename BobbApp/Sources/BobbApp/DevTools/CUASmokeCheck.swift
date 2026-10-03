import AppKit
import BobbCore

/// Runs the actual bundled CUA child and typed browser adapter against a
/// synthetic page. No user browser profile or private window is observed.
@MainActor
func runCUASmokeCheck() {
    Task {
        guard let raw = AppPaths.argument("--check-cua"), let url = URL(string: raw),
              let computer = CUABrowserComputer(url: url, boundaries: { BoundaryConfiguration() }) else { exit(1) }
        let query = "Bobb local test & verification"
        var passed = false, detail = "unavailable"
        if let before = await computer.observe(), let field = before.elements.first(where: { $0.title == "Search query" && $0.valueSettable }) {
            let typed = await computer.perform(.type(key: field.key, text: query, submit: false))
            await computer.settle()
            if typed == .ok, let filled = await computer.observe(),
               filled.elements.contains(where: { $0.title == "Search query" && $0.value == query }),
               let button = filled.elements.first(where: { $0.title == "Search" }) {
                let clicked = await computer.perform(.press(key: button.key))
                await computer.settle()
                if clicked == .ok, let result = await computer.observe() {
                    passed = result.screenText.contains("Results for: " + query)
                    detail = passed ? "Typed, submitted and independently read the resulting page." : "No matching result observed."
                }
            }
        }
        await computer.close()
        let report: [String:Any] = ["passed":passed,"verification":detail,"driver":"CUA 0.31.0","profile":"isolated_new"]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            print(String(decoding:data,as:UTF8.self))
            if let output = AppPaths.argument("--report") { try? data.write(to: URL(fileURLWithPath:output)) }
        }
        exit(passed ? 0 : 1)
    }
}
