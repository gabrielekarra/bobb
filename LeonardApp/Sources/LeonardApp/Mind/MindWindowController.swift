import AppKit
import SwiftUI
import LeonardCore

@MainActor
final class MindWindowController: NSWindowController {
    init(state: AppState, coordinator: LeonardCoordinator) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mind"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 440)
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(rootView: MindView(state: state, coordinator: coordinator))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MindWindowController does not support NSCoding")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
