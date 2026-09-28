import AppKit
import LeonardCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: LeonardCoordinator!
    private var statusItemController: StatusItemController!
    private var overlayController: OverlayController!
    private var mindWindowController: MindWindowController!
    private var auditWindowController: AuditWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let state = AppState()
        let socketPath = Self.argumentValue(for: "--socket") ?? (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/Leonard/leonardd.sock")
        let client = IPCClient(socketPath: socketPath)

        let useMock = CommandLine.arguments.contains("--mock-events")
        let eventSource: EventSource = useMock
            ? MockEventSource(scenario: MockEventSource.demoScenario())
            : WorkspaceEventSource()

        let coordinator = LeonardCoordinator(state: state, client: client, eventSource: eventSource)
        self.coordinator = coordinator

        let mindWindowController = MindWindowController(state: state, coordinator: coordinator)
        self.mindWindowController = mindWindowController

        let auditPath = Self.argumentValue(for: "--audit-db") ?? (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/Leonard/audit.db")
        let auditWindowController = AuditWindowController(auditPath: auditPath)
        self.auditWindowController = auditWindowController

        let overlayController = OverlayController(state: state, coordinator: coordinator)
        self.overlayController = overlayController

        statusItemController = StatusItemController(
            state: state,
            coordinator: coordinator,
            overlayController: overlayController,
            openMind: { [weak mindWindowController] in mindWindowController?.show() },
            openAudit: { [weak auditWindowController] in auditWindowController?.show() }
        )

        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
