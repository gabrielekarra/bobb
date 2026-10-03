import AppKit
import QuartzCore
import SwiftUI
import Observation
import BobbCore

/// Owns the single overlay panel. Never activates the app: the panel is
/// shown with `orderFrontRegardless()`, not `makeKeyAndOrderFront`, so
/// showing it does not touch the frontmost application at all. A click on
/// its buttons is what lets the (`.nonactivatingPanel`) panel become key,
/// per `OverlayPanel`'s doc comment — still without activating Bobb.
@MainActor
final class OverlayController {
    private let state: AppState
    private let coordinator: BobbCoordinator
    private var panel: OverlayPanel?
    private var dismissTimer: Timer?
    private var currentDecision: DecisionFrame?
    private var initiativeResponse: ((String) -> Void)?
    private var autoDismissInterval: TimeInterval { TimeInterval(state.settings.overlaySeconds) }

    init(state: AppState, coordinator: BobbCoordinator) {
        self.state = state
        self.coordinator = coordinator
        observePendingOverlay()
    }

    private func observePendingOverlay() {
        withObservationTracking {
            _ = state.pendingOverlay
            _ = state.settings.watching
            _ = state.settings.contextProactive
        } onChange: { [weak self] in
            // Observation calls onChange before the new value is stored.
            // Read on the next main-actor turn or the first card is lost.
            Task { @MainActor [weak self] in
                self?.pendingOverlayChanged()
                self?.observePendingOverlay()
            }
        }
    }

    private func pendingOverlayChanged() {
        if !state.settings.watching || (initiativeResponse != nil && !state.settings.contextProactive) {
            dismissTimer?.invalidate(); hide(); return
        }
        guard let decision = state.pendingOverlay, let suggestion = decision.suggestion else { return }
        state.pendingOverlay = nil
        show(decision: decision, suggestion: suggestion)
    }

    func presentInitiative(_ initiative: ProactiveInitiative, response: @escaping (String) -> Void) {
        guard !state.overlayVisible else { return }
        show(decision: nil, suggestion: Suggestion(title: initiative.title, actionId: "initiative.prepare",
            detail: initiative.reason, cta: BobbCopy.t("Prepare with me", "Prepara con me")),
            explanation: BobbCopy.t("From your work in ", "Dal tuo lavoro in ") + initiative.app)
        initiativeResponse = response
    }

    private func show(decision: DecisionFrame?, suggestion: Suggestion, explanation: String? = nil) {
        dismissTimer?.invalidate()
        panel?.orderOut(nil)
        currentDecision = decision
        initiativeResponse = nil
        state.overlayVisible = true
        state.activeSuggestion = decision

        let hosting = NSHostingView(rootView: OverlayView(
            suggestion: suggestion,
            explanation: decision?.explanation ?? explanation,
            onPrepare: { [weak self] in self?.approveCurrent() },
            onDismiss: { [weak self] in self?.dismissCurrent() }
        ).tint(Theme.accent))
        let size = hosting.intrinsicContentSize
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = OverlayPanel(contentView: hosting)
        panel.setContentSize(size)
        self.panel = panel

        let screen = activeScreen()
        let target = topRightOrigin(for: panel.frame.size, on: screen)
        panel.setFrameOrigin(NSPoint(x: target.x, y: target.y + 10))
        panel.alphaValue = 0

        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(target)
        }

        dismissTimer = Timer.scheduledTimer(withTimeInterval: autoDismissInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timedOut() }
        }
    }

    /// Called by the overlay's own "Prepara" button and by the menu bar
    /// popover's copy of the same suggestion — whichever the user clicked,
    /// the response and the resulting teardown are identical.
    func approveCurrent() {
        dismissTimer?.invalidate()
        if let response = initiativeResponse { hide(); response("prepare"); return }
        guard let decision = currentDecision else { return }
        coordinator.approve(decision)
        hide()
    }

    /// Called by the overlay's own "Ignore" button and by the popover.
    func dismissCurrent() {
        respondDismissAndHide(reason: .user)
    }

    /// Nobody answered. The suggestion stays in "For you" and the daemon
    /// learns only a little from it: the user may simply not have looked.
    private func timedOut() {
        respondDismissAndHide(reason: .timeout)
    }

    private func respondDismissAndHide(reason: DismissReason) {
        dismissTimer?.invalidate()
        if let response = initiativeResponse { hide(); if reason == .user { response("dismiss") }; return }
        if let decision = currentDecision {
            coordinator.dismiss(decision, reason: reason)
        }
        hide()
    }

    private func hide() {
        currentDecision = nil
        initiativeResponse = nil
        state.overlayVisible = false
        state.activeSuggestion = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    private func activeScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func topRightOrigin(for size: NSSize, on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        let margin: CGFloat = 16
        return NSPoint(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin)
    }
}
