import Carbon
import Foundation
import BobbCore

/// A system-wide shortcut through Carbon's `RegisterEventHotKey`: the one
/// API that delivers a global key combination without Accessibility or
/// Input Monitoring permission, and without seeing any other keystroke.
@MainActor
final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: @MainActor () -> Void
    private static let signature: OSType = 0x4C45_4F4E  // 'LEON'
    private static var nextId: UInt32 = 1
    /// Each shortcut has its own id, so several can be registered and each
    /// handler answers only its own.
    private let id: UInt32

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
        self.id = Self.nextId
        Self.nextId += 1
        installHandler()
    }

    /// Replaces any previous registration. Returns false when the
    /// combination is taken by another app.
    @discardableResult
    func register(_ hotkey: Hotkey) -> Bool {
        unregister()
        let id = EventHotKeyID(signature: Self.signature, id: self.id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == OSStatus(noErr) else { return false }
        hotKeyRef = ref
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            // Carbon dispatches application-target events on the main thread.
            let mine = MainActor.assumeIsolated { status == OSStatus(noErr) && pressed.id == hotkey.id }
            guard mine else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { hotkey.action() }
            return OSStatus(noErr)
        }, 1, &eventType, context, &handlerRef)
    }
}
