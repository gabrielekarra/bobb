import AppKit
import Foundation
import BobbCore

/// Reads the newest messages in Mail's Sent mailbox, read-only, so the
/// daemon can find the promises in them (VISION rule 1: the same lens as the
/// inbox, never a plugin). Only while Mail is already running: Bobb never
/// launches Mail to look.
@MainActor
final class SentMailSensor {
    var onEvent: ((EventFrame) -> Void)?
    var interval: TimeInterval = 600
    var permitted: () -> Bool = { false }

    private var timer: Timer?
    private var tracker: SentMailTracker
    private let seenFile: URL
    private var runner: AppleScriptRunner { .shared }

    init(seenFile: URL) {
        self.seenFile = seenFile
        let seen = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: seenFile))) ?? []
        tracker = SentMailTracker(seen: seen)
    }

    private static let script = """
    if application "Mail" is not running then return ""
    tell application "Mail"
        set rs to (character id 30)
        set us to (character id 31)
        set out to ""
        set box to sent mailbox
        set n to count of messages of box
        if n is 0 then return ""
        if n > 15 then set n to 15
        repeat with i from 1 to n
            set m to message i of box
            set rcpt to ""
            try
                set r to item 1 of to recipients of m
                set rcpt to (name of r) & " <" & (address of r) & ">"
            end try
            set c to ""
            try
                set c to content of m
                if (length of c) > 3000 then set c to text 1 thru 3000 of c
            end try
            set out to out & (message id of m) & us & ((date sent of m) as «class isot» as string) & us & rcpt & us & (subject of m) & us & c & rs
        end repeat
        return out
    end tell
    """

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            MainActor.assumeIsolated { self?.look() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func look() {
        guard permitted() else { return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: MailEvents.bundleId).first != nil else { return }
        guard let messages = try? MailBridge.batch(sent: true, limit: 15) else { return }
        let sent = messages.compactMap { message -> SentMessage? in
            guard let date = message.date else { return nil }
            return SentMessage(messageId: message.messageId, sent: date, to: message.to, subject: message.subject,
                               body: message.body, sender: message.sender, cc: message.cc, headers: message.headers)
        }
        let fresh = tracker.fresh(sent)
        persist()
        for message in fresh {
            onEvent?(SentMailTracker.event(for: message))
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Array(tracker.seen)) {
            try? data.write(to: seenFile, options: .atomic)
        }
    }
}
