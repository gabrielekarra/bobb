import AppKit
import BobbCore
import ScreenCaptureKit

/// Native card and draft panel, real IPC and models, synthetic reply input.
/// Reports OS permission state separately; never reads a real email.
@MainActor
func runMailReplySmokeCheck() {
    Task {
        L10n.code = "it"
        let state = AppState()
        state.entitlement = .community
        state.settings.language = .it
        state.settings.memoryEnabled = false
        state.settings.contextProactive = false
        state.settings.quietHoursEnabled = false
        state.settings.overlaySeconds = 120
        let client = IPCClient(socketPath: AppPaths.argument("--socket") ?? "/private/tmp/bobb-mail-ui.sock")
        let coordinator = BobbCoordinator(state: state, client: client, eventSource: MockEventSource(scenario: [], loop: false))
        let overlay = OverlayController(state: state, coordinator: coordinator)
        let draftPanel = DraftPanelController(state: state, coordinator: coordinator)
        let diagnostics = MailSensor().diagnostics()
        coordinator.start()
        let deadline = Date().addingTimeInterval(90)
        while !state.connection.isReady && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        guard state.connection.isReady else { print("Mail reply smoke: daemon not ready"); exit(1) }
        let message = MailMessage(id: "synthetic", messageId: "<synthetic@example.test>",
            sender: "Marco Rossi <marco@example.test>", subject: "Preventivo",
            body: "Ciao Gabriele, mi confermi il preventivo di 450 euro? Grazie, Marco", read: true, mailbox: "Synthetic")
        let compose = MailComposeSnapshot(id: "synthetic-draft-" + UUID().uuidString, subject: "Re: Preventivo", recipients: ["marco@example.test"], content: "")
        guard ReplyStartWatcher().shouldOffer(compose, original: message, keyboardIdle: 1) else { exit(1) }
        let event = MailEvents.replyStarted(message, composeId: compose.id, to: compose.recipients)
        coordinator.submit(event)
        while !state.overlayVisible && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        let offered = state.overlayVisible && state.activeSuggestion?.suggestion?.cta == "Genera bozza"
        let noDraftBeforeApproval = state.draft == nil
        var offerCaptured = AppPaths.argument("--screenshots") == nil
        if let directory = AppPaths.argument("--screenshots"), let card = NSApp.windows.first(where: { $0 is OverlayPanel }) {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? await Task.sleep(for: .milliseconds(350))
            offerCaptured = await captureMailSmokeWindow(card, to: directory + "/mail-reply-offer.png")
        }
        overlay.approveCurrent()
        while (state.draft == nil || state.draft?.streaming == true) && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        let text = state.draft?.text ?? ""
        let prepared = state.draft?.isReply == true && state.draft?.result?.messageId == message.messageId && !text.isEmpty && state.draft?.error == nil
        let panelVisible = NSApp.windows.contains { !($0 is OverlayPanel) && $0.isVisible }
        var draftCaptured = AppPaths.argument("--screenshots") == nil
        if let directory = AppPaths.argument("--screenshots"), let panel = NSApp.windows.first(where: { !($0 is OverlayPanel) && $0.isVisible }) {
            try? await Task.sleep(for: .milliseconds(250))
            draftCaptured = await captureMailSmokeWindow(panel, to: directory + "/mail-reply-draft.png")
        }
        let passed = offered && noDraftBeforeApproval && prepared && panelVisible && offerCaptured && draftCaptured && diagnostics["scriptsCompile"] as? Bool == true
        let report: [String: Any] = ["passed": passed,
            "scope": "Native overlay and draft panel with real daemon and synthetic reply event; not native Mail click detection.",
            "offerVisible": offered, "requiresApproval": noDraftBeforeApproval, "draftPanelVisible": panelVisible,
            "draftPrepared": prepared, "draft": text, "mailDiagnostics": diagnostics,
            "offerCaptured": offerCaptured, "draftCaptured": draftCaptured]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            if let output = AppPaths.argument("--report") { try? data.write(to: URL(fileURLWithPath: output)) }
            print(String(data: data, encoding: .utf8) ?? "")
        }
        withExtendedLifetime(draftPanel) { coordinator.stop() }
        exit(passed ? 0 : 1)
    }
}

@MainActor
func captureMailSmokeWindow(_ window: NSWindow, to path: String) async -> Bool {
    guard #available(macOS 14.4, *) else { return false }
    do {
        let content = try await SCShareableContent.currentProcess
        guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) && $0.owningApplication?.processID == getpid() }) else { return false }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * window.backingScaleFactor)
        config.height = Int(window.frame.height * window.backingScaleFactor)
        config.showsCursor = false
        let captured = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: config)
        let bitmap = NSBitmapImageRep(cgImage: captured)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        try data.write(to: URL(fileURLWithPath: path))
        return true
    } catch { print("Mail smoke capture failed: \(error)"); return false }
}
