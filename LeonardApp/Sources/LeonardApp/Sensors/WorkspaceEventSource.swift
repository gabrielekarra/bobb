import AppKit
import CoreGraphics
import Foundation
import LeonardCore

/// Everything Leonard can observe about desktop activity with **no**
/// Accessibility permission: which app is frontmost, from `NSWorkspace`,
/// and whether the user is typing or away, from the HID idle clock in
/// `CGEventSource`. `mail.opened`, `mail.composing`, `text.selected` and
/// `window.changed` all need the accessibility tree or ScreenCaptureKit and
/// are deliberately not emitted here — that is the seam `EventSource`
/// exists for.
@MainActor
public final class WorkspaceEventSource: EventSource {
    public let events: AsyncStream<EventFrame>
    private let continuation: AsyncStream<EventFrame>.Continuation

    public var idleThreshold: TimeInterval
    public var typingThreshold: TimeInterval
    public var pollInterval: TimeInterval
    public var permittedApp: ((String?, String) -> Bool)?

    private var activationObserver: NSObjectProtocol?
    private var idleTimer: Timer?
    private var isIdle = false
    private var previousAppName = ""
    private var previousBundleID: String?

    public init(idleThreshold: TimeInterval = 90, typingThreshold: TimeInterval = 2, pollInterval: TimeInterval = 1) {
        self.idleThreshold = idleThreshold
        self.typingThreshold = typingThreshold
        self.pollInterval = pollInterval
        var continuation: AsyncStream<EventFrame>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func start() {
        guard activationObserver == nil else { return }
        let front = NSWorkspace.shared.frontmostApplication
        previousAppName = front?.localizedName ?? ""
        previousBundleID = front?.bundleIdentifier
        if permittedApp?(previousBundleID, previousAppName) != true { previousAppName = ""; previousBundleID = nil }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let name = app?.localizedName ?? app?.bundleIdentifier ?? "unknown"
            let bundleID = app?.bundleIdentifier
            // `queue: .main` guarantees this always runs on the main thread;
            // the notification-center API itself predates actor isolation
            // and cannot express that in its type, so only the already-
            // extracted, Sendable `name` crosses into actor-isolated code.
            MainActor.assumeIsolated { self?.handleActivation(appName: name, bundleID: bundleID) }
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollIdle() }
        }
        if let idleTimer {
            RunLoop.main.add(idleTimer, forMode: .common)
        }
    }

    public func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func handleActivation(appName name: String, bundleID: String?) {
        guard permittedApp?(bundleID, name) == true else { previousAppName = ""; previousBundleID = nil; return }
        if permittedApp?(previousBundleID, previousAppName) != true { previousAppName = "" }
        let snapshot = activitySnapshot()
        let payload = EventPayload(
            typing: snapshot.typing, idle: snapshot.idle,
            fields: ["previous_app": .string(previousAppName), "title": "", "bundle_id": bundleID.map(JSONValue.string) ?? .null]
        )
        previousAppName = name
        previousBundleID = bundleID
        continuation.yield(EventFrame(kind: .appActivated, app: name, payload: payload))
    }

    private func pollIdle() {
        let snapshot = activitySnapshot()
        guard snapshot.idle != isIdle else { return }
        isIdle = snapshot.idle
        let kind: EventKind = snapshot.idle ? .idleEntered : .idleLeft
        let payload = EventPayload(typing: snapshot.typing, idle: snapshot.idle, fields: [:])
        continuation.yield(EventFrame(kind: kind, app: "", payload: payload))
    }

    private func activitySnapshot() -> (typing: Bool, idle: Bool) {
        let anyInputIdleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~UInt32(0))!
        )
        let keyboardIdleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .keyDown
        )
        return (typing: keyboardIdleSeconds < typingThreshold, idle: anyInputIdleSeconds >= idleThreshold)
    }
}
