import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if CommandLine.arguments.contains("--render-docs") {
    renderDocsScreenshots()
    exit(0)
}

if CommandLine.arguments.contains("--mcp-guest") {
    let server = GuestMCPServer()
    server.start()
    withExtendedLifetime(server) { app.run() }
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
