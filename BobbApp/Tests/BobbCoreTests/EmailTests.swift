import Foundation
import Testing
@testable import BobbCore

@Suite("Email workspace")
struct EmailTests {
    @MainActor @Test func automaticRepliesRespectPauseBoundariesAndApprovalMode() {
        let state = AppState()
        let coordinator = BobbCoordinator(state: state, client: IPCClient(socketPath: "/tmp/unused.sock"), eventSource: MockEventSource(scenario: []))
        #expect(coordinator.permitsAutomaticEmail(context: "reply"))
        state.settings.mailInlineReplies = false
        #expect(!coordinator.permitsAutomaticEmail(context: "reply"))
        state.settings.mailInlineReplies = true
        state.settings.actingApproval = .everyStep
        #expect(!coordinator.permitsAutomaticEmail(context: "reply"))
        state.settings.actingApproval = .important
        state.settings.bobb.boundaries.apps = [AppBoundary(id: "com.apple.mail", name: "Mail", actions: ["write": .ask])]
        #expect(!coordinator.permitsAutomaticEmail(context: "reply"))
        state.settings.bobb.boundaries.apps = []
        state.settings.watching = false
        #expect(!coordinator.permitsAutomaticEmail(context: "reply"))
        state.settings.watching = true
        state.settings.extraProtectedApps = ["com.apple.mail"]
        #expect(!coordinator.permitsAutomaticEmail(context: "reply"))
    }

    @Test func accountMetadataDoesNotBecomePartOfTheBody() {
        let raw = ["42", "<one@x>", "Marco <m@x.it>", "Quote", "false", "Archive", "help@x.it",
                   "2026-10-03T10:00:00", "user@x.it", "", "", "", "Work", "body"].joined(separator: MailScriptFormat.unit)
        let message = MailScriptFormat.parseSelected(raw, includesMetadata: true, includesAccount: true)
        #expect(message?.account == "Work" && message?.body == "body")
        #expect(EmailItem(message: message!).snapshot["account"]?.stringValue == "Work")
        let flaggedRaw = ["42", "<one@x>", "Marco <m@x.it>", "Quote", "false", "Archive", "help@x.it",
                          "2026-10-03T10:00:00", "user@x.it", "", "", "", "Work", "true", "body"].joined(separator: MailScriptFormat.unit)
        #expect(MailScriptFormat.parseSelected(flaggedRaw, includesMetadata: true, includesAccount: true, includesFlag: true)?.flagged == true)
    }

    @Test func replyGestureKeepsTheOriginalRecipientsSeparate() {
        let original = MailMessage(id: "1", messageId: "original", sender: "marco@x.it", subject: "Quote", body: "Ciao", read: true,
                                   mailbox: "Inbox", to: "user@x.it")
        let gesture = MailEvents.replyStarted(original, composeId: "draft", to: ["marco@x.it"])
        #expect(gesture.payload.fields["to"]?.stringValue == "user@x.it")
        #expect(gesture.payload.fields["reply_recipients"]?.arrayValue == [.string("marco@x.it")])
    }

    @Test func archivePagesDecodeAndOldSettingsKeepInlineDefault() throws {
        let old = try JSONDecoder().decode(BobbSettings.self, from: Data(#"{"mailProactive":true}"#.utf8))
        #expect(old.mailInlineReplies)
        var settings = old
        settings.mailInlineReplies = false
        #expect(try JSONDecoder().decode(BobbSettings.self, from: JSONEncoder().encode(settings)).mailInlineReplies == false)
        let raw = #"{"t":"email.state","items":[],"reminders":[],"counts":{},"preferences":{"vip":[],"signature":"","style":"concise","archive_all":true},"offset":60,"total":137,"has_more":true,"mailboxes":["Archive"],"accounts":["Work"]}"#
        if case .email(let page) = try IncomingFrame.decode(from: Data(raw.utf8)) {
            #expect(page.offset == 60 && page.total == 137 && page.hasMore == true)
            #expect(page.mailboxes == ["Archive"] && page.preferences.archiveAll == true)
        } else { Issue.record("Incorrect archive frame") }
    }

    @Test func parsesFoldedHeadersWithoutMergingSubjects() {
        let headers = MailHeaders(raw: "In-Reply-To: <parent@x>\r\nReferences: <root@x>\r\n\t<parent@x>\r\nList-ID: <team@x>\r\nAuto-Submitted: auto-generated\r\n")
        #expect(headers.inReplyTo == "parent@x")
        #expect(headers.references == ["root@x", "parent@x"])
        #expect(headers.listId == "<team@x>" && headers.automatic)
        #expect(MailHeaders.canonicalID(" <AbC@x> ") == "AbC@x")
        #expect(MailHeaders(raw: "Subject: Re: same\n").references.isEmpty)
        #expect(!MailHeaders(raw: "Auto-Submitted: no\n").automatic)
    }

    @Test func parsesExtendedMailMetadataAndPreservesBody() {
        let unit = MailScriptFormat.unit
        let raw = ["42", "<one@x>", "Marco <m@x.it>", "Quote", "false", "Inbox", "help@x.it",
                   "2026-10-03T10:00:00", "user@x.it", "cc@x.it", "quote.pdf\n", "In-Reply-To: <parent@x>\n", "body" + unit + "more"].joined(separator: unit)
        let message = MailScriptFormat.parseSelected(raw, includesMetadata: true)
        #expect(message?.date != nil)
        #expect(message?.to == "user@x.it" && message?.cc == "cc@x.it")
        #expect(message?.attachments == ["quote.pdf"])
        #expect(message?.headers.inReplyTo == "parent@x")
        #expect(message?.body == "body" + unit + "more")
        let payload = EmailItem(message: message!).snapshot
        #expect(payload["message_id"]?.stringValue == "one@x")
        #expect(payload["in_reply_to"]?.stringValue == "parent@x")
        #expect(payload["attachments"]?.arrayValue?.count == 1)
    }

    @Test func checksOnlyAuthoredTextAndHandlesUnknownAttachments() {
        let compose = MailComposeSnapshot(id: "one", subject: "Quote", recipients: ["m@x.it"],
            content: "Ciao Marco, in allegato trovi il contratto.\n\nFirma\nOn October 2 Marco wrote:\n> older text", signature: "Firma", attachmentCount: 0)
        #expect(MailDraftChecks.issues(draft: compose.authoredText, subject: compose.subject, recipients: compose.recipients, attachmentCount: 0) == ["attachment"])
        #expect(MailDraftChecks.issues(draft: "Non ho allegato il file.", subject: "Hi", recipients: ["m@x.it"], attachmentCount: 0).isEmpty)
        #expect(MailDraftChecks.issues(draft: "Please find attached the quote.", subject: "Hi", recipients: ["m@x.it"], attachmentCount: -1).isEmpty)
        #expect(MailDraftChecks.issues(draft: "TODO: [name]", subject: "", recipients: [], attachmentCount: 2) == ["subject", "recipient", "placeholder"])
        let forwarded = MailComposeSnapshot(id: "two", subject: "Fwd: Quote", recipients: [], content: "\nFirma\nBegin forwarded message:\nFrom: Marco\nBody", signature: "Firma")
        #expect(forwarded.authoredText.isEmpty)
    }

    @Test func extendedComposeRecordCarriesAttachmentCount() {
        let raw = ["1", "Re: Quote", "m@x.it\n", "Firma", "1", "Testo"].joined(separator: MailScriptFormat.unit)
        let snapshot = MailScriptFormat.parseCompose(raw, includesAttachmentCount: true)
        #expect(snapshot?.attachmentCount == 1 && snapshot?.content == "Testo")
    }

    @Test func framesRoundTripWithoutLosingRequestIdentity() throws {
        let command = EmailCommandFrame(op: "reply", payload: .object(["message_id": .string("one@x")]), id: "email_one")
        let data = try OutgoingFrame.email(command).encoded()
        #expect(try FrameCodec.readType(from: data) == "email.command")
        let decoded = try FrameCodec.payload(EmailCommandFrame.self, from: data)
        #expect(decoded == command)
        let state = #"{"t":"email.state","request_id":"email_one","items":[],"reminders":[],"counts":{},"preferences":{"vip":[],"signature":"","style":"concise"},"result":{"operation":"reply","text":"Ciao","result_kind":"reply","message_id":"one@x"}}"#
        let incoming = try IncomingFrame.decode(from: Data(state.utf8))
        #expect(incoming.requestId == "email_one")
        if case .email(let value) = incoming { #expect(value.result?.messageId == "one@x") }
        else { Issue.record("Wrong email frame") }
    }

    @MainActor @Test func lateDeltasAndResultsCannotOverwriteANewerRequest() throws {
        let state = AppState()
        let coordinator = BobbCoordinator(state: state, client: IPCClient(socketPath: "/tmp/no-email-daemon.sock"), eventSource: MockEventSource(scenario: []))
        state.emailWriting = EmailWritingSession(requestId: "email_new", operation: "reply")
        coordinator.handle(try IncomingFrame.decode(from: Data(#"{"t":"email.delta","request_id":"email_old","text":"old"}"#.utf8)))
        #expect(state.emailWriting?.text == "")
        coordinator.handle(try IncomingFrame.decode(from: Data(#"{"t":"email.delta","request_id":"email_new","text":"new"}"#.utf8)))
        #expect(state.emailWriting?.text == "new")
        coordinator.cancelEmailWriting()
        coordinator.handle(try IncomingFrame.decode(from: Data(#"{"t":"email.delta","request_id":"email_new","text":"late"}"#.utf8)))
        #expect(state.emailWriting?.text == "new")
    }
}
