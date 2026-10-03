import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if CommandLine.arguments.contains("--diagnose-mail") {
    runMailDiagnostics()
    app.run()
    exit(0)
}

if CommandLine.arguments.contains("--check-mail-reply") {
    runMailReplySmokeCheck()
    app.run()
    exit(0)
}

if CommandLine.arguments.contains("--check-email") {
    runEmailSmokeCheck()
    app.run()
    exit(0)
}

if CommandLine.arguments.contains("--check-user-browser") {
    runUserBrowserSmokeCheck()
    app.run()
    exit(0)
}

if CommandLine.arguments.contains("--check-cua") {
    runCUASmokeCheck()
    app.run()
    exit(0)
}

if CommandLine.arguments.contains("--check-command") {
    runCommandSmokeCheck()
    app.run()
    exit(0)
}

if CommandLine.arguments.contains("--render-docs") {
    Task { @MainActor in await renderDocsScreenshots(); exit(0) }
    app.run()
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
