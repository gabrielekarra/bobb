import EventKit
import Foundation
import LeonardCore
import Observation

/// Reads the user's calendars through EventKit, on the Mac, for two things:
/// the next two weeks of events go into screen memory (so "when is the call
/// with Marco?" has an answer), and about ten minutes before a meeting with
/// other people an event lets the daemon offer a brief. Nothing is written
/// to any calendar.
@MainActor
@Observable
final class CalendarSensor {
    enum Access: Equatable {
        case granted, denied, notDetermined
    }

    private(set) var access: Access = .notDetermined
    @ObservationIgnored var onEvent: ((EventFrame) -> Void)?
    @ObservationIgnored var onMemory: ((MemoryObserveFrame) -> Void)?

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var scheduler = MeetingScheduler()
    @ObservationIgnored private var remembered: [String: Int] = [:]
    @ObservationIgnored private var lastMemoryPass: Date = .distantPast

    init() {
        refreshAccess()
    }

    func refreshAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .notDetermined: access = .notDetermined
        default: access = .denied
        }
    }

    func requestAccess() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let granted = (try? await self.store.requestFullAccessToEvents()) ?? false
            self.access = granted ? .granted : .denied
            if granted { self.tick() }
        }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        refreshAccess()
        guard access == .granted else { return }
        let now = Date()
        let items = events(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(14 * 86400))
        for item in scheduler.due(items, now: now) {
            onEvent?(MeetingScheduler.event(for: item, now: now))
        }
        if now.timeIntervalSince(lastMemoryPass) >= 300 {
            lastMemoryPass = now
            remember(items)
        }
    }

    private func remember(_ items: [CalendarItem]) {
        for item in items {
            let text = item.memoryText()
            let hash = text.hashValue
            guard remembered[item.id] != hash else { continue }
            remembered[item.id] = hash
            onMemory?(MemoryObserveFrame(ts: Date().timeIntervalSince1970, app: "Calendar", bundleId: "com.apple.iCal",
                                         window: item.title, text: text, source: "calendar"))
        }
        if remembered.count > 2000 { remembered.removeAll() }
    }

    private func events(from start: Date, to end: Date) -> [CalendarItem] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).prefix(400).map { event in
            let people = (event.attendees ?? []).filter { !$0.isCurrentUser }.map { person -> String in
                let address = person.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                if let name = person.name, !name.isEmpty, name != address { return "\(name) <\(address)>" }
                return address
            }
            return CalendarItem(
                id: event.calendarItemIdentifier + "|" + String(event.startDate.timeIntervalSince1970),
                title: event.title ?? "",
                start: event.startDate,
                end: event.endDate,
                allDay: event.isAllDay,
                location: event.location ?? "",
                notes: event.notes ?? "",
                attendees: people,
                calendar: event.calendar?.title ?? ""
            )
        }
    }
}
