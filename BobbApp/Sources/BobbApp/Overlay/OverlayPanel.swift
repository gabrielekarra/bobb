import AppKit

/// A floating panel that can take clicks without ever making Bobb the
/// active application. `.nonactivatingPanel` is what makes that possible:
/// per `NSWindow.StyleMask` documentation, a panel with this mask can
/// become the key window — so its buttons work — without its owning app
/// becoming the frontmost app. `BobbApp/README.md` documents how this
/// was verified against a real foreground app rather than trusted on the
/// strength of the flag alone.
final class OverlayPanel: NSPanel {
    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        self.contentView = BobbGlassHostingView(contentView, radius: 24)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
