import AppKit
import ApplicationServices
import Foundation
import LeonardCore

/// Operates applications from outside, the way a person does, through the
/// accessibility tree: reads what can be pressed, typed into and scrolled
/// in the app in front (and its menu bar), and acts on the element the task
/// loop names. Never a plugin, never an app's private API (VISION rule 1).
///
/// Every action re-resolves the live element it was handed in the last
/// observation and refuses one that has gone or turned secure; nothing is
/// ever done at a remembered coordinate except the rare synthesized click
/// on an element that exposes no action, at its current frame.
@MainActor
final class AXDriver: TaskDriver {
    private var elements: [Int: AXUIElement] = [:]
    private var frames: [Int: CGRect] = [:]
    private var nextKey = 1
    private var menuCache: (pid: pid_t, at: Date, items: [(UIElementSnapshot, AXUIElement)])?
    private var lastTyped: (element: AXUIElement, previous: String)?
    private var lastApp: pid_t?
    var settings: (() -> LeonardSettings)?
    var stillOwnsScreen: (() -> Bool)?
    private var fingerprints: [Int: String] = [:]
    private var windowTitle = ""

    static let maxNodes = 2600
    static let maxDepth = 40
    static let timeBudget: TimeInterval = 0.7

    // MARK: Observing

    func observe() async -> ScreenObservation? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        lastApp = front.processIdentifier
        if let settings {
            let s = settings()
            guard s.bobb.boundaries.app(bundleId: front.bundleIdentifier, name: front.localizedName ?? "") != nil,
                  !ScreenMemoryPolicy(extraProtected: s.extraProtectedApps).isProtected(bundleId: front.bundleIdentifier, appName: front.localizedName ?? "") else {
                return ScreenObservation(app: front.localizedName ?? "", bundleId: front.bundleIdentifier, window: "", elements: [])
            }
        }
        let app = AX.application(front.processIdentifier)
        AX.enableFullTree(app, pid: front.processIdentifier)
        elements.removeAll(keepingCapacity: true)
        frames.removeAll(keepingCapacity: true)
        let window = AX.element(app, "AXFocusedWindow") ?? AX.element(app, "AXMainWindow")
        let title = window.flatMap { AX.string($0, "AXTitle") } ?? ""
        windowTitle = title
        var snapshots: [UIElementSnapshot] = []
        var visible: ScreenRect?
        if let window {
            visible = Self.rect(of: window).map(Self.screenRect)
            snapshots = walk(window)
        }
        snapshots += menuItems(app: app, pid: front.processIdentifier)
        // Editors, terminals and spreadsheet selections may expose only a
        // focused cursor rather than a settable text field.
        if let focused = AX.focusedElement(in: app), !AX.isSecure(focused),
           !snapshots.contains(where: { $0.focused && ElementClassifier.kind(of: $0) == .text }) {
            let key = register(focused)
            snapshots.append(UIElementSnapshot(key: key, role: AX.string(focused, "AXRole") ?? "AXUnknown",
                                               title: "Focused cursor", focused: true, cursor: true))
        }
        fingerprints = Dictionary(uniqueKeysWithValues: elements.map { ($0.key, Self.fingerprint($0.value)) })
        var text = WindowReader.read(pid: front.processIdentifier, appName: front.localizedName ?? "",
                                      bundleId: front.bundleIdentifier, windowTitle: title)?.text ?? ""
        if text.count < 40, settings?().readImages == true {
            text = await ScreenTextRecognizer.read(pid: front.processIdentifier, windowTitle: title) ?? text
        }
        let defaultButton = window.flatMap { AX.element($0, "AXDefaultButton") }.flatMap { AX.string($0, "AXTitle") } ?? ""
        return ScreenObservation(app: front.localizedName ?? front.bundleIdentifier ?? "", bundleId: front.bundleIdentifier,
                                 window: title, elements: snapshots, screen: visible, screenText: text,
                                 defaultButton: defaultButton, unreadable: text.isEmpty && snapshots.isEmpty)
    }

    private func register(_ element: AXUIElement) -> Int {
        let key = nextKey
        nextKey += 1
        elements[key] = element
        return key
    }

    private static let attributes = [
        "AXRole", "AXSubrole", "AXRoleDescription", "AXTitle", "AXDescription", "AXValue", "AXPlaceholderValue",
        "AXHelp", "AXIdentifier", "AXEnabled", "AXFocused", "AXSelected", "AXPosition", "AXSize",
    ]
    private static let containerRoles: Set<String> = [
        "AXGroup", "AXToolbar", "AXSplitGroup", "AXList", "AXOutline", "AXTable", "AXTabGroup", "AXScrollArea",
        "AXWebArea", "AXSheet", "AXPopover", "AXLayoutArea", "AXBrowser", "AXRadioGroup", "AXDrawer",
    ]
    private static let needsActionCheck: Set<String> = ["AXImage", "AXStaticText", "AXGroup", "AXUnknown", "AXGenericElement"]

    /// Breadth-first over the window, bounded in nodes, depth and time, so
    /// a huge web page or a hung app cannot stall a task.
    private func walk(_ root: AXUIElement) -> [UIElementSnapshot] {
        let started = Date()
        var out: [UIElementSnapshot] = []
        var queue: [(AXUIElement, Int, [String])] = [(root, 0, [])]
        var head = 0
        while head < queue.count {
            if head >= Self.maxNodes || Date().timeIntervalSince(started) > Self.timeBudget { break }
            let (element, depth, context) = queue[head]
            head += 1
            let values = AX.batch(element, Self.attributes)
            let role = values["AXRole"] as? String ?? ""
            let subrole = values["AXSubrole"] as? String ?? ""
            if role == "AXSecureTextField" || subrole == "AXSecureTextField" { continue }

            var actions: [String] = []
            if Self.needsActionCheck.contains(role) {
                actions = Self.actionNames(element)
            }
            let frame = Self.frame(values)
            var snapshot = UIElementSnapshot(
                key: 0, role: role, subrole: subrole,
                roleDescription: values["AXRoleDescription"] as? String ?? "",
                title: values["AXTitle"] as? String ?? "",
                description: values["AXDescription"] as? String ?? "",
                value: Self.stringValue(values["AXValue"]),
                placeholder: values["AXPlaceholderValue"] as? String ?? "",
                help: values["AXHelp"] as? String ?? "",
                identifier: values["AXIdentifier"] as? String ?? "",
                enabled: (values["AXEnabled"] as? Bool) ?? true,
                focused: (values["AXFocused"] as? Bool) ?? false,
                selected: (values["AXSelected"] as? Bool) ?? false,
                frame: frame.map(Self.screenRect),
                actions: actions,
                valueSettable: false,
                context: context
            )
            if let kind = ElementClassifier.kind(of: snapshot) {
                if kind == .press, ElementClassifier.label(of: snapshot).isEmpty {
                    // Web and Electron controls often carry their name in a child.
                    snapshot.description = Self.descendantText(element)
                }
                if kind == .text {
                    var settable = DarwinBoolean(false)
                    AXUIElementIsAttributeSettable(element, "AXValue" as CFString, &settable)
                    snapshot.valueSettable = settable.boolValue
                }
                let key = register(element)
                snapshot.key = key
                if let frame { frames[key] = frame }
                out.append(snapshot)
                // A text area's children are its text runs; a button's are
                // its image and label. Neither is a separate target.
                if kind == .text || kind == .press, role != "AXRow", role != "AXOutlineRow", role != "AXCell" { continue }
            }
            guard depth < Self.maxDepth else { continue }
            var childContext = context
            if Self.containerRoles.contains(role) || role == "AXWindow" {
                if let name = Self.containerName(role: role, subrole: subrole, values: values) {
                    childContext = Array((context + [name]).suffix(3))
                }
            }
            for child in AX.children(element) {
                queue.append((child, depth + 1, childContext))
            }
        }
        return out
    }

    private static func containerName(role: String, subrole: String, values: [String: AnyObject]) -> String? {
        if subrole == "AXSourceList" { return "sidebar" }
        switch role {
        case "AXToolbar": return "toolbar"
        case "AXSheet": return "dialog"
        case "AXPopover": return "popover"
        case "AXTabGroup": return "tabs"
        default: break
        }
        for key in ["AXTitle", "AXDescription"] {
            if let text = values[key] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed.count <= 40 { return trimmed }
            }
        }
        return nil
    }

    /// Menu items, two levels deep, cached briefly: menus are large and
    /// change little between steps.
    private func menuItems(app: AXUIElement, pid: pid_t) -> [UIElementSnapshot] {
        if let cache = menuCache, cache.pid == pid, Date().timeIntervalSince(cache.at) < 8 {
            return cache.items.map { item in
                var snapshot = item.0
                snapshot.key = register(item.1)
                return snapshot
            }
        }
        guard let bar = AX.element(app, "AXMenuBar") else { return [] }
        var items: [(UIElementSnapshot, AXUIElement)] = []
        // The first menu is the Apple menu: restart, shut down, log out.
        for top in AX.children(bar).dropFirst() {
            let title = AX.string(top, "AXTitle") ?? ""
            guard !title.isEmpty else { continue }
            for menu in AX.children(top) {
                collectMenu(menu, path: [title], depth: 0, into: &items)
            }
            if items.count > 400 { break }
        }
        menuCache = (pid, Date(), items)
        return items.map { item in
            var snapshot = item.0
            snapshot.key = register(item.1)
            return snapshot
        }
    }

    private func collectMenu(_ menu: AXUIElement, path: [String], depth: Int, into items: inout [(UIElementSnapshot, AXUIElement)]) {
        for item in AX.children(menu) {
            let values = AX.batch(item, ["AXRole", "AXTitle", "AXEnabled"])
            guard (values["AXRole"] as? String) == "AXMenuItem" else { continue }
            let title = (values["AXTitle"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            let submenus = AX.children(item)
            if !submenus.isEmpty, depth < 1 {
                for sub in submenus { collectMenu(sub, path: path + [title], depth: depth + 1, into: &items) }
                continue
            }
            let snapshot = UIElementSnapshot(key: 0, role: "AXMenuItem", title: title, enabled: (values["AXEnabled"] as? Bool) ?? true,
                                             actions: ["AXPress"], menuPath: path)
            items.append((snapshot, item))
        }
    }

    // MARK: Acting

    func perform(_ action: DriverAction) async -> DriverResult {
        guard !Task.isCancelled, stillOwnsScreen?() != false else { return .stale }
        if case .openApp = action {} else {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == lastApp else { return .stale }
            if let lastApp, let current = AX.element(AX.application(lastApp), "AXFocusedWindow"),
               (AX.string(current, "AXTitle") ?? "") != windowTitle { return .stale }
        }
        switch action {
        case .openApp(let name):
            return await openApp(name)
        case .press(let key):
            guard let element = live(key) else { return .stale }
            return await press(element, key: key)
        case .open(let key):
            guard let element = live(key), !AX.isSecure(element) else { return .stale }
            if Self.actionNames(element).contains("AXOpen"), AXUIElementPerformAction(element, "AXOpen" as CFString) == .success { return .ok }
            guard let frame = Self.rect(of: element) else { return .stale }
            Pointer.click(at: CGPoint(x: frame.midX, y: frame.midY), count: 2); return .ok
        case .key(let chord):
            guard let lastApp, let focused = AX.focusedElement(in: AX.application(lastApp)), !AX.isSecure(focused) else { return .stale }
            Keyboard.press(key: chord.keyCode, command: chord.command, shift: chord.shift); return .ok
        case .type(let key, let text, let submit):
            guard let element = live(key) else { return .stale }
            if AX.isSecure(element) { return .failed("secure") }
            return await type(text, into: element, submit: submit)
        case .scroll(let key, let down):
            guard let element = live(key) else { return .stale }
            return scroll(element, key: key, down: down)
        }
    }

    /// The element for `key`, if it still exists.
    private func live(_ key: Int) -> AXUIElement? {
        guard let element = elements[key] else { return nil }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &role) == .success else { return nil }
        guard !AX.isSecure(element), fingerprints[key] == Self.fingerprint(element) else { return nil }
        return element
    }

    private static func fingerprint(_ element: AXUIElement) -> String {
        ["AXRole", "AXTitle", "AXDescription", "AXIdentifier"].map { AX.string(element, $0) ?? "" }.joined(separator: "|")
    }

    private func press(_ element: AXUIElement, key: Int) async -> DriverResult {
        let actions = Self.actionNames(element)
        for action in ["AXPress", "AXPick", "AXConfirm", "AXOpen"] where actions.contains(action) {
            if AXUIElementPerformAction(element, action as CFString) == .success { return .ok }
        }
        let role = AX.string(element, "AXRole") ?? ""
        if role == "AXRow" || role == "AXOutlineRow" || role == "AXCell" {
            // Pressing a row selects it, as a single click would.
            if AXUIElementSetAttributeValue(element, "AXSelected" as CFString, kCFBooleanTrue) == .success {
                return .ok
            }
        }
        if let frame = Self.rect(of: element) ?? frames[key], frame.width > 0 {
            Pointer.click(at: CGPoint(x: frame.midX, y: frame.midY), count: 1)
            return .ok
        }
        return .failed("no action")
    }

    private func type(_ text: String, into element: AXUIElement, submit: Bool) async -> DriverResult {
        _ = AXUIElementSetAttributeValue(element, "AXFocused" as CFString, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled, stillOwnsScreen?() != false, NSWorkspace.shared.frontmostApplication?.processIdentifier == lastApp else { return .stale }
        let role = AX.string(element, "AXRole") ?? ""
        let previous = Self.stringValue(AX.attribute(element, "AXValue"))
        let multiline = role == "AXTextArea" || role == "AXWebArea"
        lastTyped = (element, previous)
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, "AXValue" as CFString, &settable)
        if settable.boolValue, AXUIElementSetAttributeValue(element, "AXValue" as CFString, text as CFString) == .success {
            if submit { Keyboard.press(key: 36, command: false) }
            return .ok
        }
        if !multiline || previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Replace what is there: select all, then paste, as a person would.
            Keyboard.press(key: 0, command: true)  // A
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        guard !Task.isCancelled, stillOwnsScreen?() != false, NSWorkspace.shared.frontmostApplication?.processIdentifier == lastApp else { return .stale }
        await Clipboard.paste(text)
        if submit {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, stillOwnsScreen?() != false, NSWorkspace.shared.frontmostApplication?.processIdentifier == lastApp else { return .stale }
            Keyboard.press(key: 36, command: false)  // Return
        }
        return .ok
    }

    private func scroll(_ element: AXUIElement, key: Int, down: Bool) -> DriverResult {
        let names = Self.actionNames(element)
        let action = down ? "AXScrollDownByPage" : "AXScrollUpByPage"
        if names.contains(action), AXUIElementPerformAction(element, action as CFString) == .success { return .ok }
        guard let frame = Self.rect(of: element) ?? frames[key] else { return .failed("no frame") }
        Pointer.scroll(at: CGPoint(x: frame.midX, y: frame.midY), lines: down ? -8 : 8)
        return .ok
    }

    private func openApp(_ label: String) async -> DriverResult {
        guard let url = InstalledApps.shared.url(for: label) else { return .failed("not installed") }
        if let settings, settings().bobb.boundaries.app(bundleId: Bundle(url: url)?.bundleIdentifier, name: label) == nil { return .failed("unconnectedApp") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let pid: pid_t? = await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
                continuation.resume(returning: app?.processIdentifier)
            }
        }
        guard let pid else { return .failed("open failed") }
        for _ in 0..<60 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
               AX.element(AX.application(pid), "AXFocusedWindow") != nil {
                return .ok
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid ? .ok : .failed("did not come forward")
    }

    // MARK: Settling and undoing

    func settle() async {
        try? await Task.sleep(nanoseconds: 250_000_000)
        var last = signature()
        var stable = 0
        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            let now = signature()
            if now == last {
                stable += 1
                if stable >= 2 { return }
            } else {
                stable = 0
                last = now
            }
        }
    }

    /// A cheap fingerprint of the front window: its title, its children
    /// count and what has focus. Enough to tell "still changing".
    private func signature() -> String {
        guard let front = NSWorkspace.shared.frontmostApplication else { return "" }
        let app = AX.application(front.processIdentifier)
        guard let window = AX.element(app, "AXFocusedWindow") else { return "\(front.processIdentifier)" }
        let title = AX.string(window, "AXTitle") ?? ""
        let children = AX.children(window).count
        let focused = AX.focusedElement(in: app).map { AX.string($0, "AXRole") ?? "" } ?? ""
        return "\(front.processIdentifier)|\(title)|\(children)|\(focused)"
    }

    func undoLast() async -> Bool {
        guard stillOwnsScreen?() != false, NSWorkspace.shared.frontmostApplication?.processIdentifier == lastApp else { return false }
        if let typed = lastTyped {
            lastTyped = nil
            var settable = DarwinBoolean(false)
            AXUIElementIsAttributeSettable(typed.element, "AXValue" as CFString, &settable)
            if settable.boolValue,
               AXUIElementSetAttributeValue(typed.element, "AXValue" as CFString, typed.previous as CFString) == .success {
                return true
            }
        }
        // The app's own Undo: the menu item bound to ⌘Z, whatever its name in
        // this language.
        if let pid = lastApp ?? NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let undo = Self.undoMenuItem(in: AX.application(pid)) {
            return AXUIElementPerformAction(undo, "AXPress" as CFString) == .success
        }
        Keyboard.press(key: 6, command: true)  // Z
        return true
    }

    private static func undoMenuItem(in app: AXUIElement) -> AXUIElement? {
        guard let bar = AX.element(app, "AXMenuBar") else { return nil }
        for top in AX.children(bar).dropFirst() {
            for menu in AX.children(top) {
                for item in AX.children(menu) {
                    let values = AX.batch(item, ["AXMenuItemCmdChar", "AXMenuItemCmdModifiers", "AXEnabled"])
                    let char = (values["AXMenuItemCmdChar"] as? String)?.uppercased()
                    let modifiers = (values["AXMenuItemCmdModifiers"] as? NSNumber)?.intValue ?? -1
                    if char == "Z", modifiers == 0, (values["AXEnabled"] as? Bool) ?? false { return item }
                }
            }
        }
        return nil
    }

    // MARK: Apps

    func installedApps() -> [String] {
        InstalledApps.shared.names().filter { name in
            guard let settings else { return true }
            return settings().bobb.boundaries.app(bundleId: InstalledApps.shared.url(for: name).flatMap { Bundle(url: $0)?.bundleIdentifier }, name: name) != nil
        }
    }

    // MARK: Helpers

    /// The first words inside an element, for controls that name themselves
    /// through a child: a web button whose text is a span.
    static func descendantText(_ element: AXUIElement, budget: Int = 24) -> String {
        var queue = AX.children(element).map { ($0, 1) }
        var head = 0
        var parts: [String] = []
        while head < queue.count, head < budget {
            let (child, depth) = queue[head]
            head += 1
            let values = AX.batch(child, ["AXTitle", "AXValue", "AXDescription"])
            for key in ["AXTitle", "AXValue", "AXDescription"] {
                if let text = values[key] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append(text)
                    break
                }
            }
            if parts.joined(separator: " ").count > 60 { break }
            if depth < 3 { queue += AX.children(child).map { ($0, depth + 1) } }
        }
        return parts.joined(separator: " ")
    }

    static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let array = names as? [String] else { return [] }
        return array
    }

    static func stringValue(_ value: AnyObject?) -> String {
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    static func frame(_ values: [String: AnyObject]) -> CGRect? {
        guard let position = values["AXPosition"], let size = values["AXSize"],
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    static func rect(of element: AXUIElement) -> CGRect? {
        frame(AX.batch(element, ["AXPosition", "AXSize"]))
    }

    static func screenRect(_ rect: CGRect) -> ScreenRect {
        ScreenRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }
}

/// Synthesized pointer events, for the rare element that exposes no
/// accessibility action. Coordinates are global, top-left origin, as the
/// accessibility API reports them.
enum Pointer {
    static func click(at point: CGPoint, count: Int) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for index in 1...max(1, count) {
            let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
            let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    static func scroll(at point: CGPoint, lines: Int32) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { return }
        event.location = point
        event.post(tap: .cghidEventTap)
    }
}

/// The applications on this Mac, by the names a person would use: the
/// localized name, and the file name when it differs ("Calendario
/// (Calendar)"), so a request in either language finds it.
@MainActor
final class InstalledApps {
    static let shared = InstalledApps()
    private var byName: [String: URL] = [:]
    private var scannedAt: Date?

    func names() -> [String] {
        refreshIfNeeded()
        return byName.keys.sorted()
    }

    func url(for name: String) -> URL? {
        refreshIfNeeded()
        return byName[name]
    }

    private func refreshIfNeeded() {
        if let scannedAt, Date().timeIntervalSince(scannedAt) < 300 { return }
        scannedAt = Date()
        var found: [String: URL] = [:]
        let fm = FileManager.default
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                     fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let url = URL(fileURLWithPath: root).appendingPathComponent(entry)
                let file = String(entry.dropLast(4))
                let display = fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                let name = display == file ? file : "\(display) (\(file))"
                if Bundle(url: url)?.bundleIdentifier == Bundle.main.bundleIdentifier { continue }
                found[name] = found[name] ?? url
            }
        }
        byName = found
    }
}
