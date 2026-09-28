import AppKit
import ApplicationServices
import Foundation

/// Thin, typed access to the accessibility tree. Everything here follows
/// `docs/SENSOR-MAIL.md`: a messaging timeout on every application element
/// so a hung app cannot hang Leonard, attributes fetched in one batched call
/// where possible, secure text fields never read, and every walk bounded in
/// nodes and in time, reporting truncation instead of hanging.
enum AX {
    static let messagingTimeout: Float = 0.6

    static func application(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let value = attribute(element, "AXChildren") as? [AnyObject] else { return [] }
        return value.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        }
    }

    /// Several attributes in one cross-process round trip.
    static func batch(_ element: AXUIElement, _ names: [String]) -> [String: AnyObject] {
        var values: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(), &values)
        guard status == .success, let array = values as? [AnyObject] else { return [:] }
        var out: [String: AnyObject] = [:]
        for (name, value) in zip(names, array) {
            // Missing attributes come back as AXValue-wrapped errors.
            if CFGetTypeID(value) == AXValueGetTypeID() { continue }
            out[name] = value
        }
        return out
    }

    static func focusedApplication() -> (pid: pid_t, bundleId: String?, name: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return (app.processIdentifier, app.bundleIdentifier, app.localizedName ?? app.bundleIdentifier ?? "")
    }

    static func focusedElement(in app: AXUIElement) -> AXUIElement? {
        element(app, "AXFocusedUIElement")
    }

    static func isSecure(_ element: AXUIElement) -> Bool {
        let role = string(element, "AXRole") ?? ""
        let subrole = string(element, "AXSubrole") ?? ""
        return role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    /// The whole text of a WebKit area in two calls, via text markers — how
    /// VoiceOver reads a page — instead of walking thousands of nodes.
    static func webAreaText(_ element: AXUIElement) -> String? {
        var range: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXTextMarkerRangeForUIElement" as CFString, element, &range
        ) == .success, let range else { return nil }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXStringForTextMarkerRange" as CFString, range, &text
        ) == .success else { return nil }
        return text as? String
    }
}

/// Reads the text of the window in front of the user, for screen memory.
struct WindowText {
    var app: String
    var bundleId: String?
    var window: String
    var text: String
    var url: String?
    var truncated: Bool
}

enum WindowReader {
    static let maxNodes = 1500
    static let maxDepth = 30
    static let timeBudget: TimeInterval = 0.35
    private static let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink", "AXCell"]

    /// Runs off the main thread; AX calls are thread-safe C calls.
    static func read(pid: pid_t, appName: String, bundleId: String?, windowTitle: String) -> WindowText? {
        let app = AX.application(pid)
        guard let window = AX.element(app, "AXFocusedWindow") else { return nil }
        let title = AX.string(window, "AXTitle") ?? windowTitle
        let started = Date()

        // Fast path: a web area (Mail's message view, every browser, Electron
        // apps) yields its whole text in two calls.
        var url: String?
        var webTexts: [String] = []
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        var truncated = false
        var lines: [String] = []

        while !queue.isEmpty {
            if visited >= maxNodes || Date().timeIntervalSince(started) > timeBudget {
                truncated = true
                break
            }
            let (element, depth) = queue.removeFirst()
            visited += 1
            let values = AX.batch(element, ["AXRole", "AXValue", "AXTitle", "AXDescription", "AXSubrole"])
            let role = values["AXRole"] as? String ?? ""
            if role == "AXSecureTextField" || (values["AXSubrole"] as? String) == "AXSecureTextField" { continue }
            if role == "AXWebArea" {
                if url == nil, let value = AX.attribute(element, "AXURL") {
                    url = (value as? URL)?.absoluteString ?? (value as? String)
                }
                if let text = AX.webAreaText(element), !text.isEmpty {
                    webTexts.append(text)
                    continue
                }
            }
            if textRoles.contains(role) {
                for key in ["AXValue", "AXTitle", "AXDescription"] {
                    if let text = values[key] as? String, text.count > 1 {
                        lines.append(text)
                        break
                    }
                }
            }
            if depth < maxDepth {
                for child in AX.children(element) { queue.append((child, depth + 1)) }
            }
        }
        let text = (webTexts + lines).joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        return WindowText(app: appName, bundleId: bundleId, window: title, text: text, url: url, truncated: truncated)
    }
}

/// The user's current selection, from any app.
struct Selection {
    var text: String
    var app: String
    var bundleId: String?
    var window: String
    /// The focused element, kept so the result can replace the selection
    /// even after Leonard's panel has come and gone.
    var element: AXUIElement?
}

enum SelectionReader {
    /// Reads the selection through accessibility; when an app does not
    /// expose it (many Electron apps), copies it with ⌘C and restores the
    /// clipboard afterwards so the user's clipboard is left as it was.
    @MainActor
    static func current() async -> Selection? {
        guard let front = AX.focusedApplication(), front.bundleId != Bundle.main.bundleIdentifier else { return nil }
        let app = AX.application(front.pid)
        let focused = AX.focusedElement(in: app)
        let window = AX.element(app, "AXFocusedWindow").flatMap { AX.string($0, "AXTitle") } ?? ""
        if let focused, AX.isSecure(focused) { return nil }
        if let focused, let text = AX.string(focused, "AXSelectedText"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Selection(text: text, app: front.name, bundleId: front.bundleId, window: window, element: focused)
        }
        guard AXIsProcessTrusted() else { return nil }
        let copied = await Clipboard.copySelection()
        guard let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Selection(text: copied, app: front.name, bundleId: front.bundleId, window: window, element: focused)
    }
}

enum Clipboard {
    /// Everything on the general pasteboard, to put back afterwards.
    @MainActor
    static func snapshot() -> [NSPasteboardItem] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    @MainActor
    static func restore(_ items: [NSPasteboardItem]) {
        NSPasteboard.general.clearContents()
        if !items.isEmpty { NSPasteboard.general.writeObjects(items) }
    }

    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @MainActor
    static func copySelection() async -> String? {
        let saved = snapshot()
        let before = NSPasteboard.general.changeCount
        Keyboard.press(key: 8, command: true)  // C
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            if NSPasteboard.general.changeCount != before { break }
        }
        let text = NSPasteboard.general.changeCount != before ? NSPasteboard.general.string(forType: .string) : nil
        restore(saved)
        return text
    }

    /// Types `text` into whatever has focus by pasting it, then restores the
    /// clipboard.
    @MainActor
    static func paste(_ text: String) async {
        let saved = snapshot()
        copy(text)
        Keyboard.press(key: 9, command: true)  // V
        try? await Task.sleep(nanoseconds: 400_000_000)
        restore(saved)
    }
}

enum Keyboard {
    static func press(key: CGKeyCode, command: Bool) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        if command {
            down?.flags = .maskCommand
            up?.flags = .maskCommand
        }
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

enum TextInserter {
    enum Outcome {
        case replaced
        case pasted
        case copiedOnly
    }

    /// Puts `text` where the user was: replaces the selection through
    /// accessibility when the app allows it, otherwise pastes, otherwise
    /// leaves it on the clipboard and says so.
    @MainActor
    static func insert(_ text: String, into selection: Selection?) async -> Outcome {
        if let element = selection?.element, !AX.isSecure(element) {
            let status = AXUIElementSetAttributeValue(element, "AXSelectedText" as CFString, text as CFTypeRef)
            if status == .success { return .replaced }
        }
        guard AXIsProcessTrusted() else {
            Clipboard.copy(text)
            return .copiedOnly
        }
        if let bundleId = selection?.bundleId,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            app.activate()
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        await Clipboard.paste(text)
        return .pasted
    }
}
