import AppKit

/// Tracks human input separately from Bobb's synthetic keyboard and mouse
/// events, so background desktop work does not interrupt itself.
@MainActor
final class DesktopActivity {
    static let shared = DesktopActivity()
    nonisolated static let eventMarker: Int64 = 0x424F4242
    private(set) var lastInput = Date()
    private var global: Any?
    private var local: Any?

    func start() {
        guard global == nil else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
        global = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.eventMarker else { return }
            Task { @MainActor in DesktopActivity.shared.lastInput = Date() }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.eventMarker {
                Task { @MainActor in DesktopActivity.shared.lastInput = Date() }
            }
            return event
        }
    }

    var isIdle: Bool {
        guard global != nil, local != nil else {
            return [CGEventType.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel].allSatisfy {
                CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) > 60
            }
        }
        return Date().timeIntervalSince(lastInput) > 60
    }
}
