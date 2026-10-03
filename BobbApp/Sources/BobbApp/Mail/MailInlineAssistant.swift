import AppKit
import BobbCore

/// Generates for the exact empty composer that produced the native gesture.
/// The workspace and inline generation use independent request IDs.
@MainActor
final class MailInlineAssistant {
    let state: AppState
    let coordinator: BobbCoordinator
    var onNotice: ((String) -> Void)?
    private var task: Task<Void, Never>?
    private var requestId: String?
    private var monitor: Timer?

    init(state: AppState, coordinator: BobbCoordinator) {
        self.state = state; self.coordinator = coordinator
    }

    func handle(_ event: EventFrame) -> Bool {
        let fields = event.payload.fields
        let context = (fields["sender"]?.stringValue ?? "") + " " + (fields["body"]?.stringValue ?? "")
        guard event.kind == .mailReplyStarted, coordinator.permitsAutomaticEmail(context: context),
              let composeId = fields["compose_id"]?.stringValue, !composeId.isEmpty,
              let messageId = fields["message_id"]?.stringValue, !messageId.isEmpty,
              fields["draft"]?.stringValue == "", fields["typing"]?.boolValue != true,
              fields["body"]?.stringValue?.isEmpty == false,
              case .ready(let ready) = state.connection, ready.supports("email") else { return false }
        stop()
        let id = "email_inline_" + UUID().uuidString
        requestId = id
        state.inlineEmailWorking = true
        record("reply.detected", id: id)
        onNotice?(EmailCopy.t("Preparing your reply in Mail…", "Preparo la risposta in Mail…"))
        monitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.coordinator.permitsAutomaticEmail(context: context),
                      MailComposer.canInsert(composeId: composeId, messageId: messageId) else { self.stop(); return }
            }
        }
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.requestId == id {
                    self.requestId = nil; self.monitor?.invalidate(); self.monitor = nil; self.task = nil
                    self.state.inlineEmailWorking = false
                }
            }
            var snapshot = fields
            snapshot["direction"] = .string("received")
            let payload = JSONValue.object(["message_id": .string(messageId), "snapshot": .object(snapshot), "automatic": .bool(true)])
            let result = await self.coordinator.generateInlineEmail(payload, id: id)
            guard !Task.isCancelled, self.requestId == id,
                  self.coordinator.permitsAutomaticEmail(context: context) else { return }
            guard let result,
                  result.error == nil, result.cancelled != true, result.composeId == composeId,
                  !(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else {
                self.onNotice?(EmailCopy.t("Automatic draft unavailable. You can prepare a reply from Email.", "Bozza automatica non disponibile. Puoi preparare una risposta dalla pagina Email.")); return
            }
            self.monitor?.invalidate(); self.monitor = nil
            self.record("reply.generated", id: id)
            let outcome = await MailComposer.insertAutomatically(composeId: composeId, messageId: messageId, body: result.text,
                permitted: { self.coordinator.permitsAutomaticEmail(context: context) && !Task.isCancelled })
            switch outcome {
            case .opened:
                self.record("reply.inserted_verified", id: id)
                self.onNotice?(EmailCopy.t("Reply draft inserted in Mail.", "Bozza di risposta inserita in Mail."))
            case .notFound:
                self.record("reply.changed", id: id)
                self.onNotice?(EmailCopy.t("Reply changed. Your text was preserved.", "La risposta è cambiata. Il tuo testo è stato conservato."))
            case .failed:
                self.record("reply.insertion_failed", id: id)
                self.onNotice?(EmailCopy.t("Could not insert the reply. Try preparing it from Email.", "Inserimento non riuscito. Puoi preparare la risposta dalla pagina Email."))
            }
        }
        return true
    }

    func settingsChanged() {
        if !state.watching || !state.settings.mailInlineReplies || !coordinator.permitsEmail { stop() }
    }

    func stop() {
        task?.cancel(); task = nil
        monitor?.invalidate(); monitor = nil
        if let requestId { record("reply.cancelled", id: requestId); coordinator.cancelInlineEmail(requestId) }
        requestId = nil
        state.inlineEmailWorking = false
    }

    /// Native verification evidence contains no email bodies, addresses,
    /// subjects or Message-IDs, and lets support distinguish Bobb from Siri.
    private func record(_ stage: String, id: String) {
        guard var data = try? JSONSerialization.data(withJSONObject: ["ts": Date().timeIntervalSince1970, "stage": stage, "request_id": id]) else { return }
        data.append(0x0A)
        let file = AppPaths.logsDirectory.appendingPathComponent("mail-inline.jsonl")
        if !FileManager.default.fileExists(atPath: file.path) {
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } else if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data)
        }
    }
}
