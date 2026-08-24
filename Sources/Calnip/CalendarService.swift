import EventKit
import Foundation

@MainActor
final class CalendarService {
    static let shared = CalendarService()
    private let store = EKEventStore()
    private static let lastCalendarKey = "lastCalendarID"

    /// Events bucketed by start-of-day, so day switches render synchronously.
    private var dayCache: [Date: [EKEvent]] = [:]
    private var preloading = false

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: .EKEventStoreChanged, object: store)
    }

    @objc nonisolated private func storeChanged() {
        Task { @MainActor in CalendarService.shared.clearCache() }
    }

    func clearCache() {
        dayCache.removeAll()
    }

    enum CalendarError: LocalizedError {
        case accessDenied
        case noCalendar
        case eventNotFound

        var errorDescription: String? {
            switch self {
            case .accessDenied: return "Calendar access denied — enable it in System Settings › Privacy"
            case .noCalendar: return "No writable calendar found"
            case .eventNotFound: return "Event no longer exists"
            }
        }
    }

    func requestAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return true
        case .notDetermined:
            return (try? await store.requestFullAccessToEvents()) ?? false
        default:
            return false
        }
    }

    /// Calendars events can be saved to, stable order (for ⌘1–9).
    var writableCalendars: [EKCalendar] {
        store.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func match(_ query: String) -> EKCalendar? {
        let q = query.lowercased()
        let calendars = writableCalendars
        return calendars.first { $0.title.lowercased().hasPrefix(q) }
            ?? calendars.first { $0.title.lowercased().contains(q) }
    }

    /// Resolution order: ">query" match, explicit pick, configured default
    /// (Settings), last used, system default.
    func targetCalendar(query: String?, pickedID: String?) -> EKCalendar? {
        if let query, let matched = match(query) { return matched }
        if let pickedID, let picked = store.calendar(withIdentifier: pickedID) { return picked }
        let configured = UserDefaults.standard.string(forKey: Settings.defaultCalendarKey)
        if let configured, configured != "auto",
           let calendar = store.calendar(withIdentifier: configured) { return calendar }
        if let lastID = UserDefaults.standard.string(forKey: Self.lastCalendarKey),
           let last = store.calendar(withIdentifier: lastID) { return last }
        return store.defaultCalendarForNewEvents
    }

    // MARK: - Day events (cached)

    /// Instant when cached — all-day first, then timed by start.
    func cachedEvents(on day: Date) -> [EKEvent]? {
        dayCache[Calendar.current.startOfDay(for: day)]
    }

    func events(on day: Date) async -> [EKEvent] {
        let key = Calendar.current.startOfDay(for: day)
        if let cached = dayCache[key] { return cached }
        await preload(around: key)
        return dayCache[key] ?? []
    }

    /// Kick off a background preload if the day's neighborhood isn't cached yet.
    func prefetchNeighborsIfNeeded(of day: Date) {
        let calendar = Calendar.current
        let anchor = calendar.startOfDay(for: day)
        let missing = [-2, -1, 1, 2, 3].contains { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: anchor) else { return false }
            return dayCache[date] == nil
        }
        guard missing, !preloading else { return }
        Task { await preload(around: anchor) }
    }

    /// One ranged fetch (−3…+8 days), bucketed per day.
    func preload(around center: Date) async {
        guard !preloading else { return }
        preloading = true
        defer { preloading = false }

        let calendar = Calendar.current
        let anchor = calendar.startOfDay(for: center)
        guard let start = calendar.date(byAdding: .day, value: -3, to: anchor),
              let end = calendar.date(byAdding: .day, value: 8, to: anchor) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let store = self.store
        let events = await Task.detached { store.events(matching: predicate) }.value

        var day = start
        while day < end {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            dayCache[day] = events
                .filter { $0.startDate < next && $0.endDate > day }
                .sorted {
                    if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
                    return $0.startDate < $1.startDate
                }
            day = next
        }
    }

    // MARK: - Mutations

    /// Adds the event and returns the calendar it landed in.
    @discardableResult
    func add(title: String, start: Date, end: Date, isAllDay: Bool,
             query: String?, pickedID: String?,
             recurrence: RecurrenceSpec?, recurrenceEnd: Date?) async throws -> EKCalendar {
        guard await requestAccess() else { throw CalendarError.accessDenied }
        guard let calendar = targetCalendar(query: query, pickedID: pickedID) else {
            throw CalendarError.noCalendar
        }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = isAllDay
        if let recurrence {
            event.addRecurrenceRule(Self.rule(for: recurrence, until: recurrenceEnd))
        }
        try store.save(event, span: .thisEvent)
        clearCache()
        UserDefaults.standard.set(calendar.calendarIdentifier, forKey: Self.lastCalendarKey)
        return calendar
    }

    /// Applies an inline edit to an existing event (this occurrence only).
    /// A ">query" in the edit text wins over the ⌘-picked calendar.
    func update(eventID: String, title: String, start: Date, end: Date,
                isAllDay: Bool, calendarQuery: String?, calendarID: String?) async throws {
        guard await requestAccess() else { throw CalendarError.accessDenied }
        guard let event = store.event(withIdentifier: eventID) else {
            throw CalendarError.eventNotFound
        }
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = isAllDay
        if let calendarQuery, let calendar = match(calendarQuery) {
            event.calendar = calendar
        } else if let calendarID, calendarID != event.calendar?.calendarIdentifier,
                  let calendar = store.calendar(withIdentifier: calendarID) {
            event.calendar = calendar
        }
        try store.save(event, span: .thisEvent)
        clearCache()
    }

    private static func rule(for spec: RecurrenceSpec, until: Date?) -> EKRecurrenceRule {
        let end = until.map { EKRecurrenceEnd(end: $0) }
        func weeklyRule(days: [EKWeekday], interval: Int) -> EKRecurrenceRule {
            EKRecurrenceRule(
                recurrenceWith: .weekly, interval: interval,
                daysOfTheWeek: days.map { EKRecurrenceDayOfWeek($0) },
                daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                daysOfTheYear: nil, setPositions: nil, end: end)
        }
        switch spec {
        case .daily(let interval):
            return EKRecurrenceRule(recurrenceWith: .daily, interval: interval, end: end)
        case .weekdays:
            return weeklyRule(days: [.monday, .tuesday, .wednesday, .thursday, .friday], interval: 1)
        case .week(let interval):
            return EKRecurrenceRule(recurrenceWith: .weekly, interval: interval, end: end)
        case .weekly(let weekday, let interval):
            return weeklyRule(days: [EKWeekday(rawValue: weekday) ?? .monday], interval: interval)
        case .monthly(let interval):
            return EKRecurrenceRule(recurrenceWith: .monthly, interval: interval, end: end)
        case .yearly(let interval):
            return EKRecurrenceRule(recurrenceWith: .yearly, interval: interval, end: end)
        }
    }
}
