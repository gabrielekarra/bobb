import AppKit
import SwiftUI
import BobbCore

@MainActor
final class AuditWindowController: NSWindowController {
    init(auditPath: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.t(.auditTitle)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.minSize = NSSize(width: 600, height: 380)
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(rootView: AuditView(auditPath: auditPath).bobbWindowStyle())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AuditWindowController does not support NSCoding")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
