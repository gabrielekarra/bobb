/// The full `event.kind` vocabulary from `docs/CONTRACT.md`.
///
/// The four `mail.*` kinds that carry no suggestion — `arrived`, `closed`,
/// `archived`, `deleted` — exist for the implicit labeller, not for the
/// overlay: the daemon answers `ignore` on them almost always and records
/// them anyway. No shipped `EventSource` emits any `mail.*` kind yet; that
/// is the seam the mail sensor plugs into.
public enum EventKind: String, Codable, Sendable, CaseIterable {
    case appActivated = "app.activated"
    case windowChanged = "window.changed"
    case mailArrived = "mail.arrived"
    case mailOpened = "mail.opened"
    case mailClosed = "mail.closed"
    case mailComposing = "mail.composing"
    /// A message the user sent, read from Mail's Sent mailbox: where their
    /// promises are.
    case mailSent = "mail.sent"
    /// A meeting with other people about to start.
    case calendarUpcoming = "calendar.upcoming"
    case mailArchived = "mail.archived"
    case mailDeleted = "mail.deleted"
    case textSelected = "text.selected"
    /// A conversation opened, or new lines in it, in any chat app.
    case messageOpened = "message.opened"
    case idleEntered = "idle.entered"
    case idleLeft = "idle.left"

    /// The four `mail.*` kinds that carry no suggestion and exist purely so
    /// the implicit labeller sees negative examples (archived unread, never
    /// opened, opened and abandoned) and not only positives. The daemon
    /// answers `ignore` on these almost always; Mind's live list hides them
    /// by default (`AppState.hideLearningSignalsInMind`) so the interesting
    /// decisions do not drown, without ever dropping them from the tallies
    /// or the audit trail.
    public var isLearningSignal: Bool {
        switch self {
        case .mailArrived, .mailClosed, .mailArchived, .mailDeleted: true
        case .mailSent: true
        case .appActivated, .windowChanged, .mailOpened, .mailComposing, .textSelected, .messageOpened, .calendarUpcoming,
             .idleEntered, .idleLeft: false
        }
    }
}
