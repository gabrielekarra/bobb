import AppKit
import SwiftUI
import LeonardCore

/// Renders `OverlayView` and `MindView` to PNG using fixture data, for
/// `LeonardApp/docs/`. Draws the real production views directly into an
/// off-screen bitmap (`NSView.cacheDisplay`) rather than capturing the
/// display, so it needs no Screen Recording grant. The window it renders
/// from is parked off every physical screen and never activated. Invoked
/// only via `LeonardApp --render-docs`.
@MainActor
func renderDocsScreenshots() {
    let docsDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("docs")
    try? FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)

    renderOverlay(into: docsDir)
    renderMind(into: docsDir)
}

@MainActor
private func renderOverlay(into docsDir: URL) {
    let suggestion = Suggestion(
        title: "Vuoi che prepari una risposta a Marco Rossi?",
        actionId: "draft_reply",
        detail: "3 messaggi nel thread, ultimo di 2 giorni fa"
    )
    let view = OverlayView(suggestion: suggestion, onPrepare: {}, onDismiss: {})
    let hosting = NSHostingView(rootView: view)
    let size = hosting.intrinsicContentSize
    render(hosting, size: size, to: docsDir.appendingPathComponent("overlay.png"))
}

@MainActor
private func renderMind(into docsDir: URL) {
    let state = fixtureState()
    let client = IPCClient(socketPath: "/tmp/leonard-docs-render.sock")
    let coordinator = LeonardCoordinator(state: state, client: client, eventSource: WorkspaceEventSource())
    let view = MindView(state: state, coordinator: coordinator, uiState: MindUIState(expandedIDs: ["evt_2"]))
    let hosting = NSHostingView(rootView: view)
    render(hosting, size: NSSize(width: 1040, height: 920), to: docsDir.appendingPathComponent("mind.png"))
}

@MainActor
private func render(_ hosting: NSView, size: NSSize, to url: URL) {
    hosting.frame = NSRect(origin: .zero, size: size)

    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.appearance = NSAppearance(named: .aqua)
    hosting.appearance = NSAppearance(named: .aqua)
    window.contentView = hosting
    window.backgroundColor = .windowBackgroundColor
    window.orderFrontRegardless()

    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
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

@MainActor
private func fixtureState() -> AppState {
    let state = AppState()
    state.connection = .ready(ReadyFrame(ts: Date().timeIntervalSince1970, model: "mlx-community/Llama-3.2-3B-Instruct-4bit", primeMs: 477.0, decideMs: 149.8, floor: 0.60))
    state.floor = 0.60

    func add(kind: EventKind, app: String, payload: [String: JSONValue], decision: DecisionFrame, traces: [TraceFrame] = []) {
        let event = EventFrame(id: decision.eventId, kind: kind, app: app, payload: EventPayload(typing: false, idle: false, fields: payload))
        state.recordEvent(event)
        for trace in traces { state.recordTrace(trace) }
        state.recordDecision(decision)
    }

    add(
        kind: .mailOpened, app: "Mail",
        payload: ["sender": "Marco Rossi <marco@example.com>", "subject": "Preventivo revisione", "thread_len": 3, "unread": true],
        decision: DecisionFrame(
            ts: Date().timeIntervalSince1970, id: "dec_1", eventId: "evt_1", action: .suggest, confidence: 0.83,
            schemaMass: 0.997, latencyMs: 142.1,
            hypotheses: [Hypothesis(intent: "reply_to_email", p: 0.88), Hypothesis(intent: "look_for_attachment", p: 0.41)],
            readouts: [
                Readout(q: "reply_needed", value: .bool(true), p: 0.91, schemaMass: 1.0, probabilities: ["true": 0.91, "false": 0.09], rawProbabilities: ["true": 0.91, "false": 0.09]),
                Readout(q: "urgency", value: .number(3), p: 0.74, schemaMass: 0.99, probabilities: ["0": 0.02, "1": 0.05, "2": 0.11, "3": 0.74, "4": 0.08], rawProbabilities: [:]),
                Readout(q: "interrupt", value: .string("suggest"), p: 0.83, schemaMass: 0.99, probabilities: ["ignore": 0.03, "wait": 0.09, "prepare": 0.05, "suggest": 0.83], rawProbabilities: [:]),
            ],
            suggestion: Suggestion(title: "Vuoi che prepari una risposta a Marco?", actionId: "draft_reply", detail: "3 messaggi nel thread, ultimo di 2 giorni fa"),
            why: "reply_needed true a 0.91, costo di interruzione basso (non sta scrivendo)"
        ),
        traces: [TraceFrame(ts: 1, eventId: "evt_1", stage: .gate, rawStage: "gate", detail: "skip 0.0014 < 0.005", ms: 0.4),
                 TraceFrame(ts: 1, eventId: "evt_1", stage: .attention, rawStage: "attention", detail: "suggest", ms: 142.1)]
    )

    add(
        kind: .mailOpened, app: "Mail",
        payload: ["sender": "Ada Lovelace <ada@example.com>", "subject": "Aggiornamento breve", "thread_len": 1, "unread": true],
        decision: DecisionFrame(
            ts: Date().timeIntervalSince1970, id: "dec_2", eventId: "evt_2", action: .wait, confidence: 0.57,
            schemaMass: 0.991, latencyMs: 118.4,
            hypotheses: [Hypothesis(intent: "reply_to_email", p: 0.52)],
            readouts: [
                Readout(q: "reply_needed", value: .bool(true), p: 0.58, schemaMass: 0.99, probabilities: ["true": 0.58, "false": 0.42], rawProbabilities: [:]),
                Readout(q: "interrupt", value: .string("wait"), p: 0.57, schemaMass: 0.99, probabilities: ["ignore": 0.1, "wait": 0.57, "prepare": 0.08, "suggest": 0.25], rawProbabilities: [:]),
            ],
            why: "reply_needed true a 0.58, confidenza sotto la soglia", abstained: true
        )
    )

    add(
        kind: .appActivated, app: "Safari",
        payload: ["previous_app": "Mail", "title": "Documentazione fattura elettronica"],
        decision: DecisionFrame(ts: Date().timeIntervalSince1970, id: "dec_3", eventId: "evt_3", action: .ignore, confidence: 0.94, schemaMass: 0.99, latencyMs: 9.2, why: "cambio app di routine")
    )

    add(
        kind: .mailComposing, app: "Mail",
        payload: ["to": "marco@example.com", "subject": "Re: Preventivo revisione", "idle_seconds": 14],
        decision: DecisionFrame(
            ts: Date().timeIntervalSince1970, id: "dec_4", eventId: "evt_4", action: .prepare, confidence: 0.71,
            schemaMass: 0.98, latencyMs: 96.0,
            hypotheses: [Hypothesis(intent: "continue_draft", p: 0.71)],
            readouts: [Readout(q: "stuck", value: .bool(true), p: 0.71, schemaMass: 0.98, probabilities: ["true": 0.71, "false": 0.29], rawProbabilities: [:])],
            why: "pausa nella bozza"
        )
    )

    add(
        kind: .mailArrived, app: "Mail",
        payload: ["sender": "newsletter@example.com", "subject": "Novità di settembre"],
        decision: DecisionFrame(ts: Date().timeIntervalSince1970, id: "dec_5", eventId: "evt_5", action: .ignore, confidence: 0.99, schemaMass: 0.999, latencyMs: 3.1, why: "evento di apprendimento")
    )

    return state
}
