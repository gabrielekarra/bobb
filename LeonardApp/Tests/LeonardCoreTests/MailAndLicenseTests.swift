import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
import Testing
@testable import LeonardCore

@Suite("Mail sensor logic")
struct MailSessionTests {
    private func message(_ id: String, read: Bool = false) -> MailMessage {
        MailMessage(id: id, messageId: "<\(id)@x>", sender: "Marco Rossi <m@x.it>", subject: "Preventivo",
                    body: "Ciao, mi confermi?", read: read, mailbox: "INBOX")
    }

    @Test func parsesTheAppleScriptRecord() {
        let us = MailScriptFormat.unit
        let output = ["42", "<m1@x>", "Marco <m@x.it>", "Oggetto", "false", "INBOX", "riga uno\(us)ancora"].joined(separator: us)
        let parsed = MailScriptFormat.parseSelected(output)
        #expect(parsed?.id == "42")
        #expect(parsed?.read == false)
        #expect(parsed?.body == "riga uno\(us)ancora")
        #expect(MailScriptFormat.parseSelected("") == nil)
    }

    @Test func arrowingThroughTheInboxOpensNothing() {
        let tracker = MailSessionTracker(openAfter: 1.2)
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(tracker.update(selected: message("1"), at: t0).isEmpty)
        #expect(tracker.update(selected: message("2"), at: t0.addingTimeInterval(0.3)).isEmpty)
        #expect(tracker.update(selected: message("3"), at: t0.addingTimeInterval(0.6)).isEmpty)
    }

    @Test func dwellingOpensOnceAndLeavingCloses() {
        let tracker = MailSessionTracker(openAfter: 1.2)
        let t0 = Date(timeIntervalSince1970: 0)
        _ = tracker.update(selected: message("1"), at: t0)
        let opened = tracker.update(selected: message("1", read: true), at: t0.addingTimeInterval(1.5))
        #expect(opened == [.opened(message("1", read: true), wasUnread: true)])
        #expect(tracker.update(selected: message("1", read: true), at: t0.addingTimeInterval(5)).isEmpty)
        let closed = tracker.update(selected: nil, at: t0.addingTimeInterval(41.5))
        #expect(closed == [.closed(message("1", read: true), dwellMs: 41_500, stillUnread: false)])
    }

    @Test func threadLengthAndNewestPart() {
        let body = "Perfetto, allora giovedì.\n\nIl giorno 3 ott 2026, alle 10:00, Marco ha scritto:\n> ok per giovedì?\n\nOn Oct 2, 2026, Dana wrote:\n> hi"
        #expect(MailScriptFormat.estimateThreadLength(subject: "Re: riunione", body: body) == 3)
        #expect(MailScriptFormat.estimateThreadLength(subject: "Nuovo", body: "ciao") == 1)
        #expect(MailScriptFormat.newestPart(of: body) == "Perfetto, allora giovedì.")
    }

    @Test func composeChecksAfterAPauseAndOnlyOnRealChange() {
        let watcher = ComposeWatcher(pauseSeconds: 4, minimumCharacters: 20)
        let draft = "Marco, è la terza volta che i file arrivano in ritardo."
        #expect(!watcher.shouldCheck(draft: draft, subject: "Ritardo", keyboardIdle: 1))
        #expect(watcher.shouldCheck(draft: draft, subject: "Ritardo", keyboardIdle: 5))
        #expect(!watcher.shouldCheck(draft: draft + " ok", subject: "Ritardo", keyboardIdle: 5))
        #expect(watcher.shouldCheck(draft: draft + String(repeating: " davvero inaccettabile", count: 3), subject: "Ritardo", keyboardIdle: 5))
    }

    @Test func openedEventCarriesWhatTheDaemonReads() {
        let event = MailEvents.opened(message("1"), wasUnread: true, typing: false, idle: false)
        #expect(event.kind == .mailOpened)
        #expect(event.payload["sender"]?.stringValue == "Marco Rossi <m@x.it>")
        #expect(event.payload["message_id"]?.stringValue == "<1@x>")
        #expect(event.payload["unread"]?.boolValue == true)
    }
}

/// Signs with a fixed key so the parser and entitlement rules are tested on
/// every platform; the real Ed25519 path is tested below where CryptoKit exists.
private struct AcceptAll: LicenseSignatureVerifier {
    func isValidSignature(_ signature: Data, for message: Data) -> Bool { signature == Data("sig".utf8) }
}

@Suite("Offline licensing")
struct LicenseTests {
    private func key(_ payload: String, signature: String = "sig") -> String {
        "LEONARD-" + Base64URL.encode(Data(payload.utf8)) + "." + Base64URL.encode(Data(signature.utf8))
    }

    private let payload = #"{"v":1,"id":"lic_1","name":"Studio Rossi","email":"a@b.it","edition":"pro","seats":3,"issued":"2026-09-28","updates_until":"2027-09-28"}"#

    @Test func parsesAValidKeyEvenWithLineBreaks() throws {
        var text = key(payload)
        text.insert("\n", at: text.index(text.startIndex, offsetBy: 20))
        let license = try LicenseKey.verify(text, with: AcceptAll())
        #expect(license.name == "Studio Rossi")
        #expect(license.editionDisplay == "Pro")
    }

    @Test func rejectsTamperingAndGarbage() {
        #expect(throws: LicenseError.badSignature) { try LicenseKey.verify(key(payload, signature: "forged"), with: AcceptAll()) }
        #expect(throws: LicenseError.malformed) { try LicenseKey.verify("hello", with: AcceptAll()) }
        #expect(throws: LicenseError.malformed) { try LicenseKey.verify("LEONARD-abc", with: AcceptAll()) }
        let v2 = payload.replacingOccurrences(of: #""v":1"#, with: #""v":2"#)
        #expect(throws: LicenseError.unsupportedVersion) { try LicenseKey.verify(key(v2), with: AcceptAll()) }
    }

    @Test func entitlementRules() throws {
        let license = try LicenseKey.verify(key(payload), with: AcceptAll())
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let built = LicenseDates.parse("2027-01-01")!
        #expect(Entitlement.evaluate(license: nil, trialStart: start, buildDate: built, now: start) == .trial(daysLeft: 14))
        #expect(Entitlement.evaluate(license: nil, trialStart: start, buildDate: built, now: start.addingTimeInterval(13.5 * 86400)) == .trial(daysLeft: 1))
        #expect(Entitlement.evaluate(license: nil, trialStart: start, buildDate: built, now: start.addingTimeInterval(14 * 86400)) == .trialExpired)
        #expect(Entitlement.evaluate(license: license, trialStart: start, buildDate: built, now: start) == .licensed(license))
        let later = LicenseDates.parse("2028-01-01")!
        #expect(Entitlement.evaluate(license: license, trialStart: start, buildDate: later, now: later) == .updatesExpired(license))
        #expect(!Entitlement.updatesExpired(license).allowsAssistance)
    }

    #if canImport(CryptoKit)
    @Test func realEd25519SignaturesVerify() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicB64 = Base64URL.encode(privateKey.publicKey.rawRepresentation)
        let signature = try privateKey.signature(for: Data(payload.utf8))
        let text = "LEONARD-" + Base64URL.encode(Data(payload.utf8)) + "." + Base64URL.encode(signature)
        let verifier = try #require(Ed25519Verifier(publicKeyBase64: publicB64))
        #expect(try LicenseKey.verify(text, with: verifier).id == "lic_1")
        let other = try #require(Ed25519Verifier(publicKeyBase64: Base64URL.encode(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)))
        #expect(throws: LicenseError.badSignature) { try LicenseKey.verify(text, with: other) }
    }
    #endif
}
