import AppKit
import SwiftUI
import Observation
import LeonardCore

/// Owns the `NSStatusItem`. This is Leonard's only always-visible surface —
/// a click opens a popover that leads with status and, when there is one,
/// the live suggestion, rather than a settings-style `NSMenu`. The icon
/// itself is observed continuously (via `withObservationTracking`, since
/// `NSView.draw` is not SwiftUI-reactive) so it never lags what `AppState`
/// actually knows.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let iconView: StatusIconView
    private let state: AppState
    private let coordinator: LeonardCoordinator
    private let overlayController: OverlayController
    private let popover: NSPopover
    private let openMind: () -> Void
    private let openAudit: () -> Void

    init(
        state: AppState,
        coordinator: LeonardCoordinator,
        overlayController: OverlayController,
        openMind: @escaping () -> Void,
        openAudit: @escaping () -> Void
    ) {
        self.state = state
        self.coordinator = coordinator
        self.overlayController = overlayController
        self.openMind = openMind
        self.openAudit = openAudit

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
        popover.contentViewController = NSHostingController(rootView: makePopoverView())
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func makePopoverView() -> MenuBarPopoverView {
        MenuBarPopoverView(
            state: state,
            onPrepare: { [weak self] in
                self?.overlayController.approveCurrent()
                self?.popover.performClose(nil)
            },
            onDismiss: { [weak self] in
                self?.overlayController.dismissCurrent()
                self?.popover.performClose(nil)
            },
            onFloorChanged: { [weak self] floor in
                self?.coordinator.setFloor(floor)
            },
            openMind: { [weak self] in
                self?.openMind()
                self?.popover.performClose(nil)
            },
            openAudit: { [weak self] in
                self?.openAudit()
                self?.popover.performClose(nil)
            },
            quit: { NSApp.terminate(nil) }
        )
    }

    private func observeState() {
        withObservationTracking {
            _ = state.activityState
            _ = state.watching
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshIcon()
                self?.observeState()
            }
        }
    }

    private func refreshIcon() {
        iconView.activityState = state.activityState
        iconView.watching = state.watching
    }
}
