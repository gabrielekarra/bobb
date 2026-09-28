import AppKit
import ApplicationServices
import LeonardCore

/// "Show me how": while the user does the job themselves, Leonard watches
/// the way it watches everything — through the accessibility tree. A click
/// is named by the element under the pointer; a field the user filled in is
/// read when they move on; an app they switch to is an "open". Nothing in
/// Leonard's own windows, protected apps or password fields is recorded.
@MainActor
final class DemonstrationWatcher {
    private(set) var recorder: DemonstrationRecorder
    var onChange: ((DemonstrationRecorder) -> Void)?

    private var monitors: [Any] = []
    private var activation: NSObjectProtocol?
    private var field: (element: AXUIElement, label: String, value: String, app: String)?
    private let policy: ScreenMemoryPolicy

    init(goal: String, protectedApps: [String]) {
        recorder = DemonstrationRecorder(goal: goal)
        policy = ScreenMemoryPolicy(extraProtected: protectedApps)
    }

    func start() {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clicked(at: NSEvent.mouseLocation) }
        }) {
            monitors.append(monitor)
        }
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let name = app?.localizedName ?? ""
            let bundle = app?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, bundle != Bundle.main.bundleIdentifier, !self.policy.isProtected(bundleId: bundle, appName: name) else { return }
                self.flushField()
                self.recorder.record(.openedApp(name))
                self.onChange?(self.recorder)
            }
        }
    }

    func stop() -> DemonstrationRecorder {
        flushField()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        return recorder
    }

    private func clicked(at location: NSPoint) {
        flushField()
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !policy.isProtected(bundleId: front.bundleIdentifier, appName: front.localizedName ?? "") else { return }
        // AppKit's origin is bottom-left of the main screen; accessibility's is top-left.
        let height = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: location.x, y: height - location.y)
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, var element = hit else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        // The thing clicked is the nearest ancestor a task could act on.
        for _ in 0..<5 {
            let snapshot = Self.snapshot(element)
            if snapshot.isSecure { return }
            if let kind = ElementClassifier.kind(of: snapshot) {
                let label = ElementClassifier.label(of: snapshot)
                let app = front.localizedName ?? ""
                if kind == .text {
                    field = (element, label, snapshot.value, app)
                } else {
                    recorder.record(.pressed(label: label.isEmpty ? AXDriver.descendantText(element) : label,
                                             role: ElementClassifier.roleName(snapshot), app: app))
                    onChange?(recorder)
                }
                return
            }
            guard let parent = AX.element(element, "AXParent") else { return }
            element = parent
        }
    }

    /// A field the user was in: if its text changed, that was a TYPE.
    private func flushField() {
        guard let current = field else { return }
        field = nil
        guard !AX.isSecure(current.element) else { return }
        let value = AXDriver.stringValue(AX.attribute(current.element, "AXValue"))
        guard value != current.value, !value.isEmpty else { return }
        recorder.record(.typed(label: current.label, text: String(value.prefix(200)), app: current.app))
        onChange?(recorder)
    }

    private static func snapshot(_ element: AXUIElement) -> UIElementSnapshot {
        let v = AX.batch(element, ["AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXValue", "AXPlaceholderValue", "AXHelp"])
        return UIElementSnapshot(
            key: 0, role: v["AXRole"] as? String ?? "", subrole: v["AXSubrole"] as? String ?? "",
            title: v["AXTitle"] as? String ?? "", description: v["AXDescription"] as? String ?? "",
            value: AXDriver.stringValue(v["AXValue"]), placeholder: v["AXPlaceholderValue"] as? String ?? "",
            help: v["AXHelp"] as? String ?? "", actions: AXDriver.actionNames(element)
        )
    }
}
