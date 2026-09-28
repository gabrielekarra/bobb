import AppKit
import SwiftUI
import LeonardCore

/// Renders the real production views to PNG with fixture data, in English
/// and Italian, for the docs and the website. Draws into an off-screen
/// bitmap (`NSView.cacheDisplay`), so it needs no Screen Recording grant;
/// the window it renders from is parked off every screen and never
/// activated. Invoked only via `LeonardApp --render-docs [output-dir]`.
@MainActor
func renderDocsScreenshots() {
    let output: URL
    if let dir = AppPaths.argument("--render-docs") {
        output = URL(fileURLWithPath: dir, isDirectory: true)
    } else {
        output = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs")
    }
    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    for language in ["en", "it"] {
        L10n.code = language
        for dark in [false, true] {
            let suffix = "\(language)\(dark ? "-dark" : "")"
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let fixtures = Fixtures(language: language)
            let state = fixtures.state()
            let client = IPCClient(socketPath: "/tmp/leonard-docs-render.sock")
            let coordinator = LeonardCoordinator(state: state, client: client, eventSource: MockEventSource(scenario: []))

            render(OverlayView(suggestion: fixtures.suggestion, explanation: fixtures.explanation, onPrepare: {}, onDismiss: {}).tint(Theme.accent),
                   size: nil, appearance: appearance, background: .clear, to: output.appendingPathComponent("overlay-\(suffix).png"))

            render(MenuBarPopoverView(state: state, actions: .empty).background(.regularMaterial),
                   size: nil, appearance: appearance, to: output.appendingPathComponent("menu-\(suffix).png"))

            let bar = CommandBarModel()
            bar.selection = nil
            bar.input = fixtures.question
            state.ask = fixtures.answer
            render(CommandBarView(state: state, model: bar, submit: {}, close: {}, apply: { _ in }, stop: {}),
                   size: nil, appearance: appearance, background: .clear, to: output.appendingPathComponent("ask-\(suffix).png"))

            state.draft = fixtures.draft
            let editor = DraftEditor()
            editor.sync(with: state.draft)
            render(DraftView(state: state, editor: editor, coordinator: coordinator, close: {}, replyInMail: { _, _ in }, insert: { _ in })
                .background(.regularMaterial),
                   size: nil, appearance: appearance, to: output.appendingPathComponent("draft-\(suffix).png"))

            render(MindView(state: state, coordinator: coordinator, uiState: MindUIState(expandedIDs: ["evt_2"])),
                   size: NSSize(width: 1040, height: 860), appearance: appearance, to: output.appendingPathComponent("mind-\(suffix).png"))

            let memory = MemoryBrowserModel()
            memory.results = fixtures.memoryHits
            memory.stats = MemoryStatsFrame(rows: 1284, bytes: 9_400_000, apps: [
                AppMemoryCount(app: "Mail", rows: 512), AppMemoryCount(app: "Safari", rows: 388),
                AppMemoryCount(app: "Slack", rows: 241), AppMemoryCount(app: "Pages", rows: 143),
            ])
            render(MemoryView(state: state, model: memory, coordinator: coordinator),
                   size: NSSize(width: 900, height: 560), appearance: appearance, to: output.appendingPathComponent("memory-\(suffix).png"))
        }
    }
}

@MainActor
private func render<V: View>(_ view: V, size: NSSize?, appearance: NSAppearance?, background: NSColor = .windowBackgroundColor, to url: URL) {
    let hosting = NSHostingView(rootView: view)
    hosting.appearance = appearance
    let fitting = size ?? hosting.fittingSize
    hosting.frame = NSRect(origin: .zero, size: fitting)

    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.appearance = appearance
    window.contentView = hosting
    window.backgroundColor = background
    window.isOpaque = background != .clear
    window.orderFrontRegardless()

    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    hosting.layoutSubtreeIfNeeded()

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
    window.orderOut(nil)
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
            SourceRef(n: 1, id: 41, app: "Mail", window: "Fattura Atlas Cloud INV-2041", ts: now - 86400 * 2, lastSeen: now - 86400 * 2),
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

    func decision(id: String, event: String, action: DecisionAction, confidence: Double, suggestion: Suggestion? = nil,
                  explanation: String? = nil, abstained: Bool = false, readouts: [Readout] = [], latency: Double = 612) -> DecisionFrame {
        DecisionFrame(
            ts: now - 300, id: id, eventId: event, action: action, confidence: confidence, schemaMass: 0.99, latencyMs: latency,
            hypotheses: [Hypothesis(intent: "reply_to_email", p: confidence)], readouts: readouts, suggestion: suggestion,
            why: "message_type=personal_request p=0.93, urgency=3 p=0.83, user_state=reading, policy=suggest basis=urgency+message_type, floor=0.60",
            abstained: abstained, explanation: explanation, floor: 0.60
        )
    }

    func state() -> AppState {
        let state = AppState()
        state.connection = .ready(ReadyFrame(ts: now, model: "mlx-community/Llama-3.2-3B-Instruct-4bit", primeMs: 477, decideMs: 612, floor: 0.6, protocolVersion: 1))
        state.settings.onboardingCompleted = true
        state.entitlement = .licensed(LicensePayload(id: "lic", name: "Studio Rossi", email: "", edition: "pro", seats: 3, issued: "2026-09-28", updatesUntil: "2027-09-28"))
        state.stats = StatsFrame(
            ts: now,
            decisions: DecisionSummary(decisions: 412, suggested: 9, prepared: 14, abstained: 31, approved: 7, dismissed: 2, expired: 0, silent: 403, meanDecisionMs: 598),
            learning: LearningSnapshot(baseFloor: 0.6, kinds: [], mutedSenders: [
                MutedSender(ruleId: "sender:news@techmeme.com", sender: "news@techmeme.com", dismissed: 3, since: now - 86400 * 4, manual: false),
            ])
        )

        let messageType = Readout(q: "message_type", value: .string("personal_request"), p: 0.93, schemaMass: 0.99,
                                  probabilities: ["personal_request": 0.93, "personal_no_ask": 0.04, "transactional": 0.02, "broadcast": 0.01])
        let urgency = Readout(q: "urgency", value: .number(3), p: 0.55, schemaMass: 0.99,
                              probabilities: ["0": 0.03, "1": 0.04, "2": 0.10, "3": 0.55, "4": 0.28])

        func add(_ kind: EventKind, _ app: String, _ fields: [String: JSONValue], _ decision: DecisionFrame) {
            state.recordEvent(EventFrame(ts: now - 300, id: decision.eventId, kind: kind, app: app, payload: EventPayload(typing: false, idle: false, fields: fields)))
            state.recordDecision(decision)
        }
        add(.mailOpened, "Mail", ["sender": "Techmeme <news@techmeme.com>", "subject": "Techmeme Daily"],
            decision(id: "dec_0", event: "evt_0", action: .ignore, confidence: 0.97,
                     explanation: it ? "Una newsletter o un invio di massa. Niente da fare." : "A newsletter or mass mailing. Nothing to do.", latency: 588))
        add(.mailOpened, "Mail", ["sender": "Dana Whitfield <dana@apexsearch.co>", "subject": "Quick chat?"],
            decision(id: "dec_2", event: "evt_2", action: .wait, confidence: 0.54,
                     explanation: it ? "Dana Whitfield ti chiede qualcosa (entro la settimana). Leonard era sicuro al 54%, sotto la tua soglia del 60%: è rimasto in silenzio."
                                     : "Dana Whitfield is asking you for something (this week). Leonard was 54% sure, below your 60% threshold, so it stayed quiet.",
                     abstained: true, readouts: [messageType, urgency], latency: 641))
        add(.mailOpened, "Mail", ["sender": "Marco Rossi <marco@studiorossi.it>", "subject": "Preventivo revisione", "thread_len": 2],
            decision(id: "dec_1", event: "evt_1", action: .suggest, confidence: 0.83, suggestion: suggestion, explanation: explanation,
                     readouts: [messageType, urgency], latency: 604))
        state.pendingOverlay = nil
        return state
    }
}
