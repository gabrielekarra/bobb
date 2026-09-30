import AppKit
import CoreGraphics
import Foundation
import BobbCore

/// Remembers what is on screen: the text of the window in front of the
/// user, read from the accessibility tree — never pixels — when the user
/// switches to it and then every few seconds while they are active in it.
/// Reading happens off the main thread with a node and time budget; the
/// policy decides before anything is read whether this window may be read
/// at all, and afterwards whether the text changed enough to be worth
/// sending.
@MainActor
final class ScreenMemorySensor {
    var onFrame: ((MemoryObserveFrame) -> Void)?
    /// Every read, before memory's own filtering: the conversation radar
    /// looks at the same text.
    var onWindowText: ((WindowText) -> Void)?
    var policy: ScreenMemoryPolicy
    var permitsApp: ((String?, String) -> Bool)?
    var interval: TimeInterval = 6
    var idleAfter: TimeInterval = 60
    /// Read text from pixels when a window exposes almost none (Settings).
    var readImages = false
    private var lastRecognized: [String: Date] = [:]

    private var timer: Timer?
    private var activation: NSObjectProtocol?
    private var reading = false
    private nonisolated static let queue = DispatchQueue(label: "app.bobb.screen-reader", qos: .utility)

    init(policy: ScreenMemoryPolicy) {
        self.policy = policy
    }

    func start() {
        guard timer == nil else { return }
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Let the new app draw its window before reading it.
            MainActor.assumeIsolated { self?.sample(after: 0.8) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
    }

    func updateProtectedApps(_ apps: [String]) {
        policy.extraProtected = Set(apps)
    }

    private func sample(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    private func sample() {
        guard !reading, AXIsProcessTrusted() else { return }
        let anyInput = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~UInt32(0))!)
        guard anyInput < idleAfter else { return }
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let name = front.localizedName ?? front.bundleIdentifier ?? ""
        let bundleId = front.bundleIdentifier
        // Decided before a single attribute is read.
        guard !policy.isProtected(bundleId: bundleId, appName: name), permitsApp?(bundleId, name) != false else { return }
        let pid = front.processIdentifier
        reading = true
        Task { [weak self] in
            var text = await Self.read(pid: pid, appName: name, bundleId: bundleId)
            guard let self else { return }
            guard self.permitsApp?(bundleId, name) != false else { self.reading = false; return }
            var source = "screen"
            if (text?.text.count ?? 0) < 80, let recognized = await self.recognize(pid: pid, app: name, bundleId: bundleId, window: text?.window) {
                text = recognized
                source = "ocr"
            }
            self.reading = false
            guard let text, self.permitsApp?(bundleId, name) != false else { return }
            self.onWindowText?(text)
            if var frame = self.policy.frame(app: text.app, bundleId: text.bundleId, window: text.window, text: text.text, url: text.url) {
                frame.source = source
                self.onFrame?(frame)
            }
        }
    }

    /// Text from the window's pixels, at most once a minute and a half per
    /// window, when the accessibility tree had almost nothing to say.
    private func recognize(pid: pid_t, app: String, bundleId: String?, window: String?) async -> WindowText? {
        guard readImages, ScreenTextRecognizer.isAllowed, permitsApp?(bundleId, app) != false else { return nil }
        let title = window ?? AX.element(AX.application(pid), "AXFocusedWindow").flatMap { AX.string($0, "AXTitle") } ?? ""
        guard policy.mayRead(bundleId: bundleId, appName: app, windowTitle: title) else { return nil }
        let key = "\(bundleId ?? app)|\(title)"
        if let last = lastRecognized[key], Date().timeIntervalSince(last) < 90 { return nil }
        lastRecognized[key] = Date()
        if lastRecognized.count > 300 { lastRecognized.removeAll() }
        guard let text = await ScreenTextRecognizer.read(pid: pid, windowTitle: title), text.count >= 40 else { return nil }
        return WindowText(app: app, bundleId: bundleId, window: title, text: text, url: nil, truncated: false)
    }

    private nonisolated static func read(pid: pid_t, appName: String, bundleId: String?) async -> WindowText? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: WindowReader.read(pid: pid, appName: appName, bundleId: bundleId, windowTitle: ""))
            }
        }
    }
}
