import AppKit
import SwiftUI
import BobbCore
import ScreenCaptureKit

/// Renders the real production views to PNG with fixture data, in English
/// and Italian, for the docs and the website. Draws into an off-screen
/// bitmap by default. `--render-native` captures only the process's own
/// fixture window through ScreenCaptureKit, against a synthetic backdrop,
/// to include native glass without a Screen Recording grant. Invoked only
/// via `BobbApp --render-docs [output-dir]`.
@MainActor
func renderDocsScreenshots() async {
    let output: URL
    if let dir = AppPaths.argument("--render-docs") {
        output = URL(fileURLWithPath: dir, isDirectory: true)
    } else {
        output = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs")
    }
    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    for dark in [false, true] {
        await render(MarkSheet(), size: nil, appearance: NSAppearance(named: dark ? .darkAqua : .aqua),
               to: output.appendingPathComponent("mark\(dark ? "-dark" : "").png"))
    }

    for language in ["en", "it"] {
        L10n.code = language
        for dark in [false, true] {
            let suffix = "\(language)\(dark ? "-dark" : "")"
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let fixtures = Fixtures(language: language)
            let state = fixtures.state()
            let client = IPCClient(socketPath: "/tmp/bobb-docs-render.sock")
            let coordinator = BobbCoordinator(state: state, client: client, eventSource: MockEventSource(scenario: []))
            state.entitlement = .community
            state.settings.bobb.boundaries.apps = [
                AppBoundary(id: "com.apple.mail", name: "Mail"),
                AppBoundary(id: "bobb.browser", name: "Bobb Browser"),
            ]
            let workspace = BobbWorkspace(state: state, coordinator: coordinator)
            let initiative: [String: Any] = [
                "id": "fixture-initiative", "app": "Project Studio", "window": "Cortile",
                "source_id": 101, "source_ts": Date().timeIntervalSince1970,
                "title": language == "it" ? "Prepara la richiesta delle misure del lotto" : "Prepare a request for the plot measurements",
                "reason": language == "it" ? "Servono le misure aggiornate prima di confrontare le due alternative." : "Updated measurements are needed before comparing the two alternatives.",
                "quote": language == "it" ? "Mancano le misure aggiornate del lotto, necessarie prima di preparare il confronto." : "The updated plot measurements are missing and are needed before preparing the comparison.",
                "draft": language == "it" ? "Buongiorno [nome], puoi condividere le misure aggiornate del lotto? Ci servono per confrontare le due alternative per il cortile. Grazie." : "Hello [name], could you share the updated plot measurements? We need them to compare the two courtyard alternatives. Thank you."
            ]
            let fixtureSnapshot: [String: Any] = ["agents": [], "jobs": [], "projects": [], "runs": [], "routines": [], "initiatives": [initiative]]
            if let data = try? JSONSerialization.data(withJSONObject: fixtureSnapshot) {
                workspace.snapshot = try? JSONDecoder().decode(WorkspaceStateFrame.self, from: data)
            }
            for page in ["today", "identity", "boundaries", "work", "activity", "brain", "computers"] {
                await render(BobbView(workspace: workspace, initialTab: page), size: NSSize(width: 1040, height: 800),
                       appearance: appearance, to: output.appendingPathComponent("bobb-\(page)-\(suffix).png"))
            }

            await render(OverlayView(suggestion: fixtures.suggestion, explanation: fixtures.explanation, onPrepare: {}, onDismiss: {}).tint(Theme.accent),
                   size: nil, appearance: appearance, background: .clear, to: output.appendingPathComponent("overlay-\(suffix).png"))

            await render(MenuBarPopoverView(state: state, actions: .empty),
                   size: nil, appearance: appearance, to: output.appendingPathComponent("menu-\(suffix).png"))

            let bar = CommandBarModel()
            bar.selection = nil
            bar.input = fixtures.question
            state.ask = fixtures.answer
            await render(CommandBarView(state: state, model: bar, submit: {}, close: {}, apply: { _ in }, stop: {}),
                   size: nil, appearance: appearance, background: .clear, to: output.appendingPathComponent("ask-\(suffix).png"))

            state.draft = fixtures.draft
            let editor = DraftEditor()
            editor.sync(with: state.draft)
            await render(DraftView(state: state, editor: editor, coordinator: coordinator, close: {}, replyInMail: { _, _ in }, insert: { _ in }),
                   size: nil, appearance: appearance, to: output.appendingPathComponent("draft-\(suffix).png"))

            await render(MindView(state: state, coordinator: coordinator, uiState: MindUIState(expandedIDs: ["evt_2"])),
                   size: NSSize(width: 1040, height: 860), appearance: appearance, to: output.appendingPathComponent("mind-\(suffix).png"))

            let noActions = TaskActions(stop: {}, allow: { _ in }, undo: {}, close: {})
            for (name, task) in fixtures.tasks {
                state.task = task
                await render(TaskView(state: state, actions: noActions),
                       size: nil, appearance: appearance, to: output.appendingPathComponent("task-\(name)-\(suffix).png"))
            }
            state.task = nil

            let memory = MemoryBrowserModel()
            memory.results = fixtures.memoryHits
            memory.stats = MemoryStatsFrame(rows: 1284, bytes: 9_400_000, apps: [
                AppMemoryCount(app: "Mail", rows: 512), AppMemoryCount(app: "Safari", rows: 388),
                AppMemoryCount(app: "Slack", rows: 241), AppMemoryCount(app: "Pages", rows: 143),
            ])
            await render(MemoryView(state: state, model: memory, coordinator: coordinator),
                   size: NSSize(width: 900, height: 560), appearance: appearance, to: output.appendingPathComponent("memory-\(suffix).png"))
        }
    }
}

@MainActor
private func render<V: View>(_ view: V, size: NSSize?, appearance: NSAppearance?, background: NSColor = .windowBackgroundColor, to url: URL) async {
    if let filter = AppPaths.argument("--render-filter"), !url.lastPathComponent.contains(filter) { return }
    // Resolve dynamic colors against the requested appearance, not the
    // renderer process's own: an off-screen window otherwise paints a light
    // background under dark-mode text.
    let dark = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let native = CommandLine.arguments.contains("--render-native")
    var resolved = background
    if background != .clear, let appearance {
        appearance.performAsCurrentDrawingAppearance {
            resolved = background.usingColorSpace(.sRGB) ?? background
        }
    }
    let hosting = NSHostingView(rootView: view.bobbWindowStyle()
        .environment(\.colorScheme, dark ? .dark : .light)
        .background(native || background == .clear ? Color.clear : Color(nsColor: resolved)))
    hosting.appearance = appearance
    let fitting = size ?? hosting.fittingSize
    hosting.frame = NSRect(origin: .zero, size: fitting)
    let surface: NSView = native ? BobbGlassHostingView(hosting, radius: 24, clear: background == .clear) : hosting
    surface.appearance = appearance
    surface.frame = hosting.frame

    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.appearance = appearance
    window.contentView = surface
    window.backgroundColor = native ? .clear : resolved
    window.isOpaque = !native && background != .clear
    var backdrop: NSWindow?
    if native {
        // Capture only our fixture window against an owned, synthetic
        // backdrop. No desktop/app contents or Screen Recording grant.
        let rect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 1000)
        let owned = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        owned.contentView = FixtureBackdrop(frame: NSRect(origin: .zero, size: rect.size))
        owned.orderFrontRegardless(); backdrop = owned
        window.center()
    }
    window.orderFrontRegardless()
    try? await Task.sleep(for: .milliseconds(500))
    surface.layoutSubtreeIfNeeded()
    defer { window.orderOut(nil); backdrop?.orderOut(nil) }

    if native, #available(macOS 14.4, *) {
        do {
            let content = try await SCShareableContent.currentProcess
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) && $0.owningApplication?.processID == getpid() }) else {
                print("render failed: fixture window unavailable"); return
            }
            let config = SCStreamConfiguration()
            let scale = window.backingScaleFactor
            config.width = Int(fitting.width * scale); config.height = Int(fitting.height * scale)
            config.showsCursor = false
            let captured = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: config)
            let rep = NSBitmapImageRep(cgImage: captured)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            try data.write(to: url); print("wrote native \(url.path)")
        } catch { print("native render failed: \(error)") }
        return
    }

    // Native glass is composed by WindowServer and is not captured by
    // NSView's bitmap cache. Cache the hosting content for fixture previews.
    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        print("render failed: no bitmap rep for \(url.lastPathComponent)")
        return
    }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        print("render failed: no PNG data for \(url.lastPathComponent)")
        return
    }
    do {
        try data.write(to: url)
        print("wrote \(url.path)")
    } catch {
        print("render failed writing \(url.path): \(error)")
    }
}

@MainActor
private final class FixtureBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [NSColor(srgbRed: 0.02, green: 0.12, blue: 0.09, alpha: 1),
                            NSColor(srgbRed: 0.11, green: 0.43, blue: 0.25, alpha: 1),
                            NSColor(srgbRed: 0.07, green: 0.19, blue: 0.30, alpha: 1)])?.draw(in: bounds, angle: 25)
    }
}

/// A plausible morning, in either language.
@MainActor
private struct Fixtures {
    let language: String
    var it: Bool { language == "it" }
    let now = Date().timeIntervalSince1970

    var suggestion: Suggestion {
        it ? Suggestion(title: "Marco Rossi aspetta una tua risposta", actionId: "draft_reply",
                        detail: "Preventivo revisione — mi confermi entro venerdì? · oggi o domani", cta: "Prepara risposta")
           : Suggestion(title: "Marco Rossi is waiting for your reply", actionId: "draft_reply",
                        detail: "Quote revision — can you confirm by Friday? · today or tomorrow", cta: "Draft reply")
    }

    var explanation: String {
        it ? "Marco Rossi ti chiede qualcosa (oggi o domani). Merita la tua attenzione adesso."
           : "Marco Rossi is asking you for something (today or tomorrow). Worth your attention now."
    }

    var question: String { it ? "Quando scade la fattura di Atlas e quanto è?" : "When is the Atlas invoice due, and how much is it?" }

    var answer: AskSession {
        var session = AskSession()
        session.requestId = "ask_fixture"
        session.prompt = question
        session.text = it ? "La fattura INV-2041 di Atlas Cloud è di **312,40 €** e scade il **30 settembre** [1]. Giulia ha scritto che è già approvata per il pagamento [2]."
                           : "Atlas Cloud's invoice INV-2041 is **€312.40**, due on **30 September** [1]. Giulia said it's already approved for payment [2]."
        session.sources = [
            SourceRef(n: 1, id: 41, app: "Mail", window: it ? "Fattura Atlas Cloud INV-2041" : "Atlas Cloud invoice INV-2041", ts: now - 7200, lastSeen: now - 7200),
            SourceRef(n: 2, id: 77, app: "Slack", window: "#amministrazione", ts: now - 3600 * 5, lastSeen: now - 3600 * 5),
        ]
        return session
    }

    var draft: DraftSession {
        var session = DraftSession(decision: decision(id: "dec_1", event: "evt_1", action: .suggest, confidence: 0.83, suggestion: suggestion))
        session.streaming = false
        session.text = it
            ? "Ciao Marco,\n\nconfermo il preventivo di 4.800 euro: Giulia ha approvato il budget ieri, quindi possiamo procedere e bloccare la disponibilità del team.\n\nA presto,\nGabriele"
            : "Hi Marco,\n\nconfirming the €4,800 quote: Giulia approved the budget yesterday, so we can go ahead and book the team.\n\nBest,\nGabriele"
        session.result = PreparedFrame(
            ts: now, decisionId: "dec_1", actionId: "draft_reply",
            result: .object([
                "kind": .string("reply"), "body": .string(session.text), "message_id": .string("<m1@studiorossi.it>"),
                "sources": .array([.object(["n": .number(1), "id": .number(7), "app": .string("Slack"), "window": .string("#studio-rossi"),
                                            "ts": .number(now - 86400), "last_seen": .number(now - 86400)])]),
            ]),
            latencyMs: 2100
        )
        return session
    }

    var memoryHits: [MemoryHit] {
        [
            MemoryHit(id: 41, ts: now - 7200, lastSeen: now - 7200, app: "Mail", window: it ? "Fattura Atlas Cloud INV-2041" : "Atlas Cloud invoice INV-2041",
                      snippet: it ? "La fattura INV-2041 di 312,40 € scade il 30 settembre. Paga dal pannello di fatturazione." : "Invoice INV-2041 for €312.40 is due on 30 September. Pay from the billing dashboard."),
            MemoryHit(id: 77, ts: now - 18000, lastSeen: now - 18000, app: "Slack", window: "#amministrazione",
                      snippet: it ? "Giulia: la fattura Atlas è approvata, la paghiamo questa settimana." : "Giulia: the Atlas invoice is approved, we'll pay it this week."),
            MemoryHit(id: 12, ts: now - 86400 * 3, lastSeen: now - 86400 * 3, app: "Safari", window: it ? "Contratto quadro — Google Docs" : "Master agreement — Google Docs",
                      snippet: it ? "Clausola 7: vesting di 4 anni con cliff di 12 mesi per i fondatori." : "Clause 7: four-year vesting with a twelve-month cliff for founders."),
        ]
    }

    var tasks: [(String, TaskRunState)] {
        let goal = it ? "Metti la mia playlist Focus su Spotify e manda a Giulia su Slack che arrivo tra dieci minuti"
                      : "Put on my Focus playlist on Spotify and tell Giulia on Slack I'll be ten minutes late"
        var running = TaskRunState(id: "task_1", goal: goal)
        running.plan = it ? ["Apri Spotify", "Cerca “Focus”", "Avvia la playlist", "Apri Slack", "Scrivi a Giulia"]
                          : ["Open Spotify", "Search for “Focus”", "Play the playlist", "Open Slack", "Message Giulia"]
        running.steps = [
            TaskStepLine(id: 1, operation: .openApp, target: "Spotify", app: "Finder", outcome: .ok),
            TaskStepLine(id: 2, operation: .type, target: it ? "Cosa vuoi ascoltare?" : "What do you want to play?", text: "Focus", app: "Spotify", outcome: .ok),
            TaskStepLine(id: 3, operation: .click, target: "Focus Flow", app: "Spotify", outcome: .ok),
            TaskStepLine(id: 4, operation: .openApp, target: "Slack", app: "Spotify", outcome: .ok),
            TaskStepLine(id: 5, operation: .click, target: "Giulia Bianchi", app: "Slack"),
        ]
        running.phase = .acting

        var asking = running
        asking.steps[4].outcome = .ok
        asking.phase = .waitingForPermission(PermissionRequest(
            operation: .type, label: it ? "Messaggio a Giulia Bianchi" : "Message Giulia Bianchi", role: "text area", app: "Slack",
            reason: "sendsMessage", text: it ? "Ciao Giulia, arrivo tra dieci minuti." : "Hi Giulia, I'll be there in ten minutes."
        ))

        var done = asking
        done.steps.append(TaskStepLine(id: 6, operation: .type, target: it ? "Messaggio a Giulia Bianchi" : "Message Giulia Bianchi",
                                       app: "Slack", outcome: .ok))
        done.phase = .finished(.done, detail: "")
        done.canUndo = true
        return [("acting", running), ("asking", asking), ("done", done)]
    }

    func decision(id: String, event: String, action: DecisionAction, confidence: Double, suggestion: Suggestion? = nil,
                  explanation: String? = nil, abstained: Bool = false, readouts: [Readout] = [], latency: Double = 612,
                  why: String = "message_type=personal_request p=0.93, urgency=3 p=0.83, user_state=reading, policy=suggest basis=urgency+message_type, floor=0.60",
                  tier: String = "general") -> DecisionFrame {
        DecisionFrame(
            ts: now - 300, id: id, eventId: event, action: action, confidence: confidence, schemaMass: 0.99, latencyMs: latency,
            hypotheses: [Hypothesis(intent: "reply_to_email", p: confidence)], readouts: readouts, suggestion: suggestion,
            why: why,
            abstained: abstained, explanation: explanation, floor: 0.60, tier: tier
        )
    }

    func state() -> AppState {
        let state = AppState()
        state.connection = .ready(ReadyFrame(ts: now, model: "mlx-community/Qwen3.5-4B-4bit", primeMs: 477, decideMs: 612, floor: 0.6, protocolVersion: 1))
        state.entitlement = .licensed(LicensePayload(id: "lic", name: "Studio Rossi", email: "", edition: "pro", seats: 3, issued: "2026-09-28", updatesUntil: "2027-09-28"))
        state.stats = StatsFrame(
            ts: now,
            decisions: DecisionSummary(decisions: 412, suggested: 9, prepared: 14, abstained: 31, approved: 7, dismissed: 2, expired: 0, silent: 403, meanDecisionMs: 598),
            learning: LearningSnapshot(baseFloor: 0.6, kinds: [], mutedSenders: [
                MutedSender(ruleId: "sender:news@techmeme.com", sender: "news@techmeme.com", dismissed: 3, since: now - 86400 * 4, manual: false),
            ]),
            specialist: SpecialistSnapshot(
                state: "active",
                metrics: .init(trainedAt: now - 3600, examples: 412, personalLabels: 96, validation: 24, accuracy: 0.92,
                               teacherAccuracy: 0.79, quietPrecision: 1.0, quietCoverage: 0.41, trainMs: 180, enabled: true, reason: "active"),
                decisions: 412, decidedAlone: 131, aloneMs: 0.4, generalMs: 610, agreementWithGeneral: 0.9, compared: 281
            )
        )

        let messageType = Readout(q: "message_type", value: .string("personal_request"), p: 0.93, schemaMass: 0.99,
                                  probabilities: ["personal_request": 0.93, "personal_no_ask": 0.04, "transactional": 0.02, "broadcast": 0.01])
        let urgency = Readout(q: "urgency", value: .number(3), p: 0.83, schemaMass: 0.99,
                              probabilities: ["0": 0.01, "1": 0.02, "2": 0.08, "3": 0.83, "4": 0.06])
        let weekUrgency = Readout(q: "urgency", value: .number(2), p: 0.55, schemaMass: 0.99,
                                  probabilities: ["0": 0.04, "1": 0.12, "2": 0.55, "3": 0.26, "4": 0.03])

        func add(_ kind: EventKind, _ app: String, _ fields: [String: JSONValue], _ decision: DecisionFrame) {
            state.recordEvent(EventFrame(ts: now - 300, id: decision.eventId, kind: kind, app: app, payload: EventPayload(typing: false, idle: false, fields: fields)))
            state.recordDecision(decision)
        }
        add(.mailOpened, "Mail", ["sender": "Techmeme <news@techmeme.com>", "subject": "Techmeme Daily"],
            decision(id: "dec_0", event: "evt_0", action: .ignore, confidence: 0.98,
                     explanation: it ? "Bobb ha imparato da te che messaggi così possono aspettare, quindi è rimasto in silenzio senza interpellare il modello."
                                     : "Bobb has learned from you that messages like this can wait, so it stayed quiet without asking the model.",
                     latency: 0.4, why: "personal specialist: p_surface=0.021 <= 0.08", tier: "specialist"))
        add(.mailOpened, "Mail", ["sender": "Dana Whitfield <dana@apexsearch.co>", "subject": "Quick chat?"],
            decision(id: "dec_2", event: "evt_2", action: .wait, confidence: 0.54,
                     explanation: it ? "Dana Whitfield ti chiede qualcosa (entro la settimana). Bobb era sicuro al 54%, sotto la tua soglia del 60%: è rimasto in silenzio."
                                     : "Dana Whitfield is asking you for something (this week). Bobb was 54% sure, below your 60% threshold, so it stayed quiet.",
                     abstained: true, readouts: [messageType, weekUrgency], latency: 641,
                     why: "message_type=personal_request p=0.93, urgency=2 p=0.55, user_state=reading, policy=suggest basis=urgency+message_type, floor=0.60"))
        add(.mailOpened, "Mail", ["sender": "Marco Rossi <marco@studiorossi.it>", "subject": "Preventivo revisione", "thread_len": 2],
            decision(id: "dec_1", event: "evt_1", action: .suggest, confidence: 0.83, suggestion: suggestion, explanation: explanation,
                     readouts: [messageType, urgency], latency: 604))
        state.commitments = [
            Commitment(id: "c1", ts: now - 86400, person: "Marco Rossi",
                       what: it ? "Mandare il contratto firmato" : "Send the signed contract", dueTs: now + 3600 * 5),
        ]
        state.pendingOverlay = nil
        return state
    }
}

/// Every state of the mark, at menu bar size and larger, beside the app icon:
/// a visual check that the glasses read at 16 pt and that the eyes carry state.
private struct MarkSheet: View {
    private let states: [(String, Glasses.Eyes, Double)] = [
        ("watching", .up, 1), ("thinking", .look(CGVector(dx: 0.9, dy: -0.6)), 1),
        ("speaking", .look(CGVector(dx: -0.4, dy: 0.9)), 1), ("paused", .closed, 0.6),
        ("starting", .up, 0.55), ("offline", .none, 0.45),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            BobbAppIcon(size: 128)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 18) {
                        BobbMark(size: 20.6, eyes: item.1).opacity(item.2)
                        BobbMark(size: 44, eyes: item.1).opacity(item.2)
                        Text(item.0).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(24)
    }
}
