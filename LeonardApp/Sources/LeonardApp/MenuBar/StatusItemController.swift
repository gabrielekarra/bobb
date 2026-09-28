import AppKit
import SwiftUI
import Observation
import LeonardCore

/// Owns the `NSStatusItem`. This is Leonard's only always-visible surface —
/// a click opens a popover that leads with status, then anything waiting
/// for the user, rather than a settings-style `NSMenu`. The icon itself is
/// observed continuously (via `withObservationTracking`, since `NSView.draw`
/// is not SwiftUI-reactive) so it never lags what `AppState` actually knows.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let iconView: StatusIconView
    private let state: AppState
    private let popover: NSPopover
    private let makeActions: (StatusItemController) -> MenuBarActions

    init(state: AppState, makeActions: @escaping (StatusItemController) -> MenuBarActions) {
        self.state = state
        self.makeActions = makeActions

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        iconView = StatusIconView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        if let button = statusItem.button {
            iconView.frame = button.bounds
            iconView.autoresizingMask = [.width, .height]
            button.addSubview(iconView)
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityLabel("Leonard")
        }

        observeState()
        refreshIcon()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        popover.contentViewController = NSHostingController(rootView: MenuBarPopoverView(state: state, actions: makeActions(self)))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePopover() {
        popover.performClose(nil)
    }

    private func observeState() {
        withObservationTracking {
            _ = state.activityState
            _ = state.watching
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshIcon()
                self?.observeState()
            }
        }
    }

    private func refreshIcon() {
        iconView.activityState = state.activityState
        iconView.watching = state.watching
        statusItem.button?.toolTip = "Leonard"
    }
}
