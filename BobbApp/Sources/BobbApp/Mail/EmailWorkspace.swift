import AppKit
import CoreGraphics
import Observation
import SwiftUI
import BobbCore

@MainActor
@Observable
final class EmailWorkspace {
    let state: AppState
    let coordinator: BobbCoordinator
    var query = ""
    var view = "all"
    var tab = "messages"
    var selectedId: String?
    var instruction = ""
    var text = ""
    var edited = false
    var notice: String?
    var syncing = false
    var syncProgress = ""
    var syncCancelled = false
    var mailbox = ""
    var account = ""
    var archiveAll = false
    var loadingMore = false
    private var archiveOffsets: [String: Int] = [:]
    private var nextOffset = 0
    var subject = ""
    var recipients = ""
    var translation = "English"
    var vipText = ""
    var signature = ""
    var style = "concise"
    var previousDrafts: [String] = []
    var onReminder: ((ProactiveInitiative, @escaping (String) -> Void) -> Void)?
    var onPermissionDenied: (() -> Void)?
    private var window: NSWindow?
    private let windowDelegate = EmailWindowDelegate()
    private var timer: Timer?
    private var refreshing = false
    private var lastSync = Date.distantPast
    private var transient: EmailItem?
    private var outputSource: EmailItem?
    private var outputKind = "reply"
    private var syncedRequest: String?

    var items: [EmailItem] { state.email?.items ?? [] }
    var selected: EmailItem? { transient?.id == selectedId ? transient : items.first { $0.id == selectedId } }
    var writing: Bool { state.emailWriting?.streaming == true }
    var output: EmailOutput? { state.emailWriting?.result }
    var isBody: Bool { ["reply", "body"].contains(output?.resultKind ?? "") || output?.resultKind == "translation" && outputKind != "reading" }

    init(state: AppState, coordinator: BobbCoordinator) {
        self.state = state; self.coordinator = coordinator
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                Task { @MainActor [weak self] in await self?.tick() }
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() { timer?.invalidate(); timer = nil; syncCancelled = true; coordinator.cancelEmailWriting() }

    func show(messageId: String? = nil) {
        if window == nil {
            let hosting = NSHostingView(rootView: EmailWorkspaceView(workspace: self, state: state))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 720),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Bobb · Email"
            window.contentView = hosting
            window.minSize = NSSize(width: 880, height: 600)
            window.isReleasedWhenClosed = false
            windowDelegate.onClose = { [weak self] in self?.coordinator.cancelEmailWriting() }
            window.delegate = windowDelegate
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        Task {
            if let messageId {
                _ = await coordinator.email("get", payload: .object(["message_id": .string(messageId)]))
                select(messageId)
            } else { await refresh() }
            loadPreferences()
        }
    }

    func select(_ id: String?) {
        guard selectedId != id else { return }
        coordinator.cancelEmailWriting()
        state.emailWriting = nil
        selectedId = id
        text = ""; edited = false; notice = nil; instruction = ""
        previousDrafts.removeAll()
        outputSource = nil; outputKind = "reading"
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        guard coordinator.permitsEmail else { state.email = nil; return }
        var filters = listingPayload
        while let page = await coordinator.email(payload: filters) {
            if filters == listingPayload { nextOffset = page.items.count; break }
            filters = listingPayload
            guard coordinator.permitsEmail else { break }
        }
    }

    private var listingPayload: JSONValue {
        .object(["query": .string(query), "view": .string(view), "mailbox": .string(mailbox), "account": .string(account)])
    }

    func loadMore() async {
        guard !loadingMore, !refreshing, state.email?.hasMore == true, let previous = state.email else { return }
        loadingMore = true
        defer { loadingMore = false }
        let filter = listingPayload
        var payload = filter.objectValue ?? [:]
        payload["offset"] = .number(Double(nextOffset))
        guard var next = await coordinator.email(payload: .object(payload)), filter == listingPayload else { await refresh(); return }
        nextOffset = (next.offset ?? nextOffset) + next.items.count
        let existing = Set(previous.items.map(\.id))
        next.items = previous.items + next.items.filter { !existing.contains($0.id) }
        state.email = next
    }

    func stopSynchronization() { syncCancelled = true }

    func changeInMail(_ operation: String) {
        guard let source = selected, coordinator.permitsEmailAction(.write, context: source.sender + " " + source.subject) else { return }
        do {
            guard let updated = try MailBridge.change(source.messageId, operation: operation) else {
                notice = EmailCopy.t("This message is no longer available in Mail.", "Il messaggio non è più disponibile in Mail."); return
            }
            transient = EmailItem(message: updated, direction: source.direction)
            if state.settings.memoryEnabled {
                Task { _ = await coordinator.email("ingest", payload: .object(["items": .array([MailBridge.snapshot(updated, sent: source.direction == "sent")])])); await refresh() }
            }
            notice = EmailCopy.t("Message updated in Mail.", "Messaggio aggiornato in Mail.")
        } catch { failed(error) }
    }

    func readCurrent() {
        guard coordinator.permitsEmail else { return }
        do {
            guard let message = try MailBridge.selected(), !message.messageId.isEmpty else {
                notice = EmailCopy.t("Select one email in Mail first.", "Seleziona prima una sola email in Mail."); return
            }
            transient = EmailItem(message: message)
            select(transient?.id)
            if state.settings.memoryEnabled {
                Task {
                    if await coordinator.email("ingest", payload: .object(["items": .array([MailBridge.snapshot(message)])])) != nil {
                        if !items.contains(where: { $0.id == selectedId }) {
                            _ = await coordinator.email("get", payload: .object(["message_id": .string(MailHeaders.canonicalID(message.messageId))]))
                        }
                        transient = nil
                    }
                }
            }
            tab = "messages"
        } catch { failed(error) }
    }

    func synchronize(automatic: Bool = false) async {
        guard !syncing, coordinator.permitsEmail, state.settings.memoryEnabled,
              !automatic || state.watching else { return }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty else {
            if !automatic { notice = EmailCopy.t("Open Mail to synchronize.", "Apri Mail per sincronizzare.") }
            return
        }
        syncing = true; syncCancelled = false; syncProgress = ""
        defer { syncing = false; syncProgress = "" }
        do {
            if automatic {
                let incoming = try MailBridge.batch(sent: false, limit: 20)
                let outgoing = try MailBridge.batch(sent: true, limit: 15)
                guard await ingest(incoming.map { MailBridge.snapshot($0) } + outgoing.map { MailBridge.snapshot($0, sent: true) }, automatic: true) else { return }
            } else {
                // Opting into a full import keeps old messages searchable;
                // ordinary screen-memory retention remains independent.
                guard await coordinator.email("preferences", payload: .object(["archive_all": .bool(true)])) != nil else { return }
                archiveAll = true
                let boxes = try MailBridge.mailboxes()
                var imported = 0
                var failures = 0
                let expected = boxes.reduce(0) { $0 + $1.count }
                for box in boxes {
                    var offset = min(archiveOffsets[box.id] ?? 0, box.count)
                    while offset < box.count {
                        guard !syncCancelled, coordinator.permitsEmail, state.settings.memoryEnabled else {
                            notice = EmailCopy.t("Synchronization stopped. Synchronize again to resume.", "Sincronizzazione fermata. Premi Sincronizza per riprendere."); return
                        }
                        syncProgress = "\(imported)/\(expected) · " + box.label
                        let page = try MailBridge.page(box, offset: offset)
                        guard page.next > offset else { throw AppleScriptRunner.Failure.run(-1, "Mail archive did not advance") }
                        let snapshots = page.messages.map { MailBridge.snapshot($0, sent: box.sent($0)) }
                        guard await ingest(snapshots, automatic: false) else { return }
                        imported += page.messages.count; failures += page.failures
                        offset = page.next; archiveOffsets[box.id] = offset
                        await Task.yield()
                    }
                    archiveOffsets.removeValue(forKey: box.id)
                }
                notice = failures == 0
                    ? EmailCopy.t("Full Mail archive synchronized: \(imported) messages.", "Archivio completo di Mail sincronizzato: \(imported) messaggi.")
                    : EmailCopy.t("Imported \(imported) messages; \(failures) unavailable. Synchronize again to retry.", "Importati \(imported) messaggi; \(failures) non disponibili. Ripeti la sincronizzazione per riprovare.")
            }
            lastSync = Date()
            await refresh()
        } catch { failed(error) }
    }

    private func ingest(_ snapshots: [JSONValue], automatic: Bool) async -> Bool {
        for offset in stride(from: 0, to: snapshots.count, by: 5) {
            guard !syncCancelled, coordinator.permitsEmail, state.settings.memoryEnabled, !automatic || state.watching else { return false }
            guard await coordinator.email("ingest", payload: .object(["items": .array(Array(snapshots[offset..<min(offset + 5, snapshots.count)]))])) != nil else { return false }
        }
        return true
    }

    func generate(_ operation: String, instruction override: String? = nil, kind: String? = nil) {
        guard !writing, coordinator.permitsEmail else { return }
        if !["new", "digest"].contains(operation), selected == nil,
           !(["rewrite", "translate"].contains(operation) && !text.isEmpty) { return }
        let writingInstruction = override ?? instruction
        if ["new", "questions", "rewrite"].contains(operation), writingInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notice = EmailCopy.t("Add an instruction first.", "Aggiungi prima un’istruzione."); return
        }
        var payload: [String: JSONValue] = ["instruction": .string(writingInstruction), "draft": .string(text), "target": .string(translation),
                                           "query": .string(query), "view": .string(view), "mailbox": .string(mailbox), "account": .string(account)]
        let source = operation == "rewrite" || operation == "translate" && !text.isEmpty ? outputSource ?? selected : selected
        if let source { payload["message_id"] = .string(source.messageId) }
        if let transient, transient.id == source?.id { payload["snapshot"] = transient.snapshot }
        if !["rewrite", "translate"].contains(operation) {
            outputSource = source
            outputKind = kind ?? (["reply", "followup", "forward", "new"].contains(operation) ? operation : "reading")
            payload["draft"] = .string("")
        }
        if ["rewrite", "translate"].contains(operation), !text.isEmpty {
            previousDrafts.append(text)
            if previousDrafts.count > 10 { previousDrafts.removeFirst() }
        }
        notice = nil; edited = false; text = ""
        coordinator.writeEmail(operation, payload: .object(payload))
    }

    func syncText() {
        guard let session = state.emailWriting else { return }
        if syncedRequest != session.requestId { syncedRequest = session.requestId; edited = false }
        if !edited { text = session.text }
    }

    func openDraft(replyAll: Bool = false) {
        guard coordinator.permitsEmail, !writing, output?.cancelled != true, isBody, !text.isEmpty else { return }
        let body = text
        let source = outputSource
        let mode = outputKind
        guard coordinator.permitsEmailAction(.write, context: (source?.to ?? recipients) + " " + (source?.sender ?? "") + " " + body) else {
            notice = EmailCopy.t("Writing in Mail is disabled by your settings or Boundaries.", "La scrittura in Mail è disabilitata nelle impostazioni o nei Confini."); return
        }
        Task {
            let result: MailComposer.Outcome
            if mode == "new" {
                let raw = recipients
                let addresses = raw.components(separatedBy: CharacterSet(charactersIn: ",;\n")).compactMap { raw -> String? in
                    var address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let start = address.lastIndex(of: "<"), let end = address.lastIndex(of: ">"), start < end {
                        address = String(address[address.index(after: start)..<end])
                    }
                    return address.isEmpty ? nil : address
                }
                guard addresses.allSatisfy({ $0.contains("@") && !$0.contains(where: { $0.isWhitespace }) }) else {
                    notice = EmailCopy.t("Enter valid email addresses separated by commas.", "Inserisci indirizzi email validi separati da virgole."); return
                }
                result = MailComposer.newDraft(subject: subject, body: body, recipients: addresses)
            } else if let source {
                result = await MailComposer.reply(messageId: source.messageId, body: body, composeId: output?.composeId,
                    replyAll: replyAll || mode == "replyall", forward: mode == "forward",
                    followupTo: mode == "followup" ? source.to : nil,
                    permitted: { self.coordinator.permitsEmailAction(.write, context: source.sender + " " + source.to + " " + body) })
            } else { result = .notFound }
            switch result {
            case .opened: notice = EmailCopy.t("Draft opened in Mail.", "Bozza aperta in Mail.")
            case .notFound, .failed:
                Clipboard.copy(body)
                notice = EmailCopy.t("Copied. Open the correct draft in Mail and paste it.", "Testo copiato. Apri la bozza corretta in Mail e incollalo.")
            }
        }
    }

    func original() {
        guard let selected, coordinator.permitsEmailAction(.navigate, context: selected.subject) else { return }
        let encoded = "<" + selected.messageId + ">"
        var parts = URLComponents(); parts.scheme = "message"; parts.host = ""; parts.path = encoded
        if let url = parts.url { NSWorkspace.shared.open(url) }
    }

    func undoRewrite() {
        guard !writing, let previous = previousDrafts.popLast() else { return }
        text = previous; edited = true
    }

    func status(_ value: String) {
        guard let selected else { return }
        transient = nil
        Task { _ = await coordinator.email("status", payload: .object(["message_id": .string(selected.messageId), "status": .string(value)])); await refresh() }
    }

    func remind(days: Double) {
        guard let selected else { return }
        Task { _ = await coordinator.email("remind", payload: .object(["message_id": .string(selected.messageId),
            "kind": .string(selected.direction == "sent" ? "waiting" : "reply"), "due": .number(Date().addingTimeInterval(days * 86400).timeIntervalSince1970)])) }
    }

    func reminder(_ reminder: EmailReminder, action: String) {
        Task { _ = await coordinator.email("reminder", payload: .object(["id": .string(reminder.id), "action": .string(action),
                    "due": .number(Date().addingTimeInterval(86400).timeIntervalSince1970)])) }
    }

    func loadPreferences() {
        let preferences = state.email?.preferences ?? EmailPreferences()
        vipText = preferences.vip.joined(separator: ", "); signature = preferences.signature; style = preferences.style; archiveAll = preferences.archiveAll == true
    }

    func savePreferences() {
        let vip = vipText.components(separatedBy: CharacterSet(charactersIn: ",;\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        Task {
            if await coordinator.email("preferences", payload: .object(["vip": .array(vip.map { .string($0) }), "signature": .string(signature), "style": .string(style), "archive_all": .bool(archiveAll)])) != nil {
                notice = EmailCopy.t("Email preferences saved.", "Preferenze email salvate.")
            }
        }
    }

    private func failed(_ error: Error) {
        if let failure = error as? AppleScriptRunner.Failure, failure.isPermissionDenied { onPermissionDenied?() }
        if let failure = error as? AppleScriptRunner.Failure, failure.isPermissionDenied {
            notice = EmailCopy.t("Allow Mail Automation in Bobb’s settings, then try again.", "Consenti Automazione di Mail nelle impostazioni di Bobb, poi riprova.")
        } else {
            notice = EmailCopy.t("Mail could not complete synchronization. Your imported messages are kept; try again.", "Mail non ha completato la sincronizzazione. I messaggi importati sono conservati; riprova.")
        }
    }

    private func tick() async {
        guard state.watching, state.settings.memoryEnabled, coordinator.permitsEmail,
              case .ready(let ready) = state.connection, ready.supports("email") else { return }
        if Date().timeIntervalSince(lastSync) >= 300 { await synchronize(automatic: true) }
        else if window?.isVisible != true { await refresh() }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let keysIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let inputIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~UInt32(0))!)
        guard state.settings.mailProactive, InitiativePresentationPolicy.mayPresent(settings: state.settings,
            busy: state.overlayVisible || state.ask.streaming || state.draft != nil || writing || state.task != nil || window?.isVisible == true,
            keysIdle: keysIdle, inputIdle: inputIdle, frontApp: front, hour: Calendar.current.component(.hour, from: Date())),
            onReminder != nil, let reminder = state.email?.reminders.first(where: { $0.ready && $0.announced == 0 && !$0.muted }) else { return }
        let frame = await coordinator.email("reminder", payload: .object(["id": .string(reminder.id), "action": .string("present")]))
        guard frame != nil, coordinator.permitsEmail, state.watching, !state.overlayVisible else { return }
        let title = reminder.kind == "waiting" ? EmailCopy.t("Time to follow up?", "È il momento di un follow-up?") : EmailCopy.t("An email needs your attention", "Un’email richiede la tua attenzione")
        let initiative = ProactiveInitiative(id: reminder.id, title: title, reason: reminder.subject,
            quote: "", app: "Mail", window: reminder.subject, sourceId: -1, sourceTs: reminder.due)
        onReminder?(initiative) { [weak self] response in
            guard let self else { return }
            if response == "prepare" {
                self.show(messageId: reminder.messageId)
            } else if response == "dismiss" { self.reminder(reminder, action: "dismiss") }
        }
    }
}

enum EmailCopy {
    static func t(_ en: String, _ it: String) -> String { L10n.code == "it" ? it : en }
}

@MainActor
private final class EmailWindowDelegate: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    func windowWillClose(_ notification: Notification) { onClose?() }
}
