import AppKit
import ApplicationServices
import Foundation

/// Puts a drafted reply into a chat app's message box — Slack, WhatsApp,
/// Messages, Teams — the way a person would: bring the app forward, focus
/// the box, paste. It never presses Return: the user reads it and sends it.
@MainActor
enum ChatInserter {
    static func insert(_ text: String, bundleId: String) async -> Bool {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return false }
        app.activate()
        try? await Task.sleep(nanoseconds: 250_000_000)
        let element = AX.application(app.processIdentifier)
        AX.enableFullTree(element, pid: app.processIdentifier)
        if let box = messageBox(in: element) {
            _ = AXUIElementSetAttributeValue(box, "AXFocused" as CFString, kCFBooleanTrue)
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        await Clipboard.paste(text)
        return true
    }

    /// The focused text element if there is one; otherwise the lowest text
    /// box in the window, which is where chat apps put the message box.
    static func messageBox(in app: AXUIElement) -> AXUIElement? {
        let textRoles: Set<String> = ["AXTextArea", "AXTextField"]
        if let focused = AX.focusedElement(in: app), textRoles.contains(AX.string(focused, "AXRole") ?? ""), !AX.isSecure(focused) {
            return focused
        }
        guard let window = AX.element(app, "AXFocusedWindow") else { return nil }
        var queue: [AXUIElement] = [window]
        var head = 0
        var best: (AXUIElement, CGFloat)?
        while head < queue.count, head < 1500 {
            let node = queue[head]
            head += 1
            let values = AX.batch(node, ["AXRole", "AXSubrole", "AXPosition", "AXSize"])
            let role = values["AXRole"] as? String ?? ""
            if textRoles.contains(role), (values["AXSubrole"] as? String) != "AXSecureTextField",
               let frame = AXDriver.frame(values), frame.height > 8 {
                if best == nil || frame.maxY > best!.1 { best = (node, frame.maxY) }
                continue
            }
            queue += AX.children(node)
        }
        return best?.0
    }
}
