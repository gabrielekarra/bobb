import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if CommandLine.arguments.contains("--render-docs") {
    renderDocsScreenshots()
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
