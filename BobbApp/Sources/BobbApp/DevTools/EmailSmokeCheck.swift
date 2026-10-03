import AppKit
import BobbCore

/// Real Email view, IPC and generation with synthetic account data. Script
/// compilation is separate from live Mail execution; no drafts are inserted.
@MainActor
func runEmailSmokeCheck() {
    Task {
        L10n.code = "it"
        let state = AppState()
        state.entitlement = .community
        state.settings.language = .it
        state.settings.contextProactive = false
        state.settings.trackPromises = false
        let client = IPCClient(socketPath: AppPaths.argument("--socket") ?? "/private/tmp/bobb-email-ui.sock")
        let coordinator = BobbCoordinator(state: state, client: client, eventSource: MockEventSource(scenario: [], loop: false))
        let workspace = EmailWorkspace(state: state, coordinator: coordinator)
        coordinator.start()
        let deadline = Date().addingTimeInterval(120)
        while !state.connection.isReady && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        guard state.connection.isReady else { print("Email check: daemon not ready"); exit(1) }
        let scripts = [MailBridge.script, MailComposer.replyScript, MailComposer.newScript]
        let compileResults = scripts.map { source -> Bool in
            var error: NSDictionary?
            let success = NSAppleScript(source: source)?.compileAndReturnError(&error) == true
            if !success { print("Email script compile: \(String(describing: error))") }
            return success
        }
        let message = MailMessage(id: "synthetic", messageId: "email-ui@example.test", sender: "Marco Rossi <marco@example.test>",
            subject: "Consegna preventivo", body: "Ciao Gabriele, puoi confermare il preventivo di 450 euro entro domani alle 15:30? Qual è la data prevista di consegna? Grazie, Marco",
            read: false, mailbox: "Synthetic Inbox", to: "gabriele@example.test", date: Date(), attachments: ["preventivo.pdf"])
        let ingested = await coordinator.email("ingest", payload: .object(["items": .array([EmailItem(message: message).snapshot])])) != nil
        workspace.show()
        workspace.select(message.messageId)
        workspace.generate("summary")
        while workspace.writing && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        workspace.syncText()
        let summarized = workspace.output?.resultKind == "brief" && !(workspace.text.isEmpty) && workspace.output?.emailSources?.first?.messageId == message.messageId
        workspace.generate("reply")
        while workspace.writing && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        workspace.syncText()
        let drafted = workspace.output?.resultKind == "reply" && workspace.output?.messageId == message.messageId && !workspace.text.isEmpty
        let draft = workspace.text
        workspace.text = "Ciao Marco, grazie. La data proposta è il 15 ottobre. Gabriele"
        workspace.edited = true
        workspace.generate("rewrite", instruction: "Correggi solo la grammatica e conserva la data del 15 ottobre.")
        while workspace.writing && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        workspace.syncText()
        let rewritten = workspace.output?.resultKind == "body" && !workspace.text.isEmpty
        workspace.undoRewrite()
        let undoPreservedEdits = workspace.text.contains("15 ottobre") && workspace.edited
        var captured = true
        if let directory = AppPaths.argument("--screenshots") {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? await Task.sleep(for: .milliseconds(350))
            if let window = NSApp.windows.first(where: { $0.title == "Bobb · Email" }) {
                captured = await captureMailSmokeWindow(window, to: directory + "/email-workspace-it.png")
                workspace.tab = "reminders"
                try? await Task.sleep(for: .milliseconds(200))
                captured = await captureMailSmokeWindow(window, to: directory + "/email-reminders-it.png") && captured
                workspace.tab = "preferences"
                workspace.loadPreferences()
                try? await Task.sleep(for: .milliseconds(200))
                captured = await captureMailSmokeWindow(window, to: directory + "/email-preferences-it.png") && captured
            } else { captured = false }
        }
        let passed = compileResults.allSatisfy { $0 } && ingested && summarized && drafted && rewritten && undoPreservedEdits && captured
        let report: [String: Any] = ["passed": passed, "scope": "Native Email workspace, real daemon and synthetic data; no live Mail insertion or sending.",
            "scriptsCompile": compileResults, "ingested": ingested, "summary": summarized, "drafted": drafted,
            "rewritten": rewritten, "undoPreservedEdits": undoPreservedEdits, "captured": captured, "draft": draft]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            if let path = AppPaths.argument("--report") { try? data.write(to: URL(fileURLWithPath: path)) }
            print(String(decoding: data, as: UTF8.self))
        }
        coordinator.stop()
        withExtendedLifetime(workspace) { exit(passed ? 0 : 1) }
    }
}
