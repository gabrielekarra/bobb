import AppKit
import QuartzCore
import SwiftUI
import Observation
import LeonardCore

/// Owns the single overlay panel. Never activates the app: the panel is
/// shown with `orderFrontRegardless()`, not `makeKeyAndOrderFront`, so
/// showing it does not touch the frontmost application at all. A click on
/// its buttons is what lets the (`.nonactivatingPanel`) panel become key,
/// per `OverlayPanel`'s doc comment — still without activating Leonard.
@MainActor
final class OverlayController {
    private let state: AppState
    private let coordinator: LeonardCoordinator
    private var panel: OverlayPanel?
    private var dismissTimer: Timer?
    private var currentDecision: DecisionFrame?
    private let autoDismissInterval: TimeInterval = 14

    init(state: AppState, coordinator: LeonardCoordinator) {
        self.state = state
        self.coordinator = coordinator
        observePendingOverlay()
    }

    private func observePendingOverlay() {
        withObservationTracking {
            _ = state.pendingOverlay
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingOverlayChanged()
                self?.observePendingOverlay()
            }
        }
    }

    private func pendingOverlayChanged() {
        guard let decision = state.pendingOverlay, let suggestion = decision.suggestion else { return }
        state.pendingOverlay = nil
        show(decision: decision, suggestion: suggestion)
    }

    private func show(decision: DecisionFrame, suggestion: Suggestion) {
        dismissTimer?.invalidate()
        currentDecision = decision
        state.overlayVisible = true
        state.activeSuggestion = decision

        let hosting = NSHostingView(rootView: OverlayView(
            suggestion: suggestion,
            onPrepare: { [weak self] in self?.approveCurrent() },
            onDismiss: { [weak self] in self?.dismissCurrent() }
        ))
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
        guard let decision = currentDecision else { return }
        coordinator.approve(decision)
        hide()
    }

    /// Called by the overlay's own "Ignora" button and by the popover.
    func dismissCurrent() {
        respondDismissAndHide()
    }

    private func timedOut() {
        respondDismissAndHide()
    }

    private func respondDismissAndHide() {
        dismissTimer?.invalidate()
        if let decision = currentDecision {
            coordinator.dismiss(decision)
        }
        hide()
    }

    private func hide() {
        currentDecision = nil
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
