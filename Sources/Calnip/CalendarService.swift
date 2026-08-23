import EventKit
import Foundation

final class CalendarService {
    static let shared = CalendarService()
    private let store = EKEventStore()
    private static let lastCalendarKey = "lastCalendarID"

    enum CalendarError: LocalizedError {
        case accessDenied
        case noCalendar

        var errorDescription: String? {
            switch self {
            case .accessDenied: return "Calendar access denied — enable it in System Settings › Privacy"
            case .noCalendar: return "No writable calendar found"
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

    /// Resolution order: ">query" match, explicit ⌘-pick, last used, system default.
    func targetCalendar(query: String?, pickedID: String?) -> EKCalendar? {
        if let query, let matched = match(query) { return matched }
        if let pickedID, let picked = store.calendar(withIdentifier: pickedID) { return picked }
        if let lastID = UserDefaults.standard.string(forKey: Self.lastCalendarKey),
           let last = store.calendar(withIdentifier: lastID) { return last }
        return store.defaultCalendarForNewEvents
    }

    /// Timed events on the same day as `date`, sorted by start.
    func eventsOnDay(of date: Date) -> [EKEvent] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Adds the event and returns the calendar it landed in.
    @discardableResult
    func add(title: String, start: Date, end: Date,
             query: String?, pickedID: String?, recurrence: RecurrenceSpec?) async throws -> EKCalendar {
        guard await requestAccess() else { throw CalendarError.accessDenied }
        guard let calendar = targetCalendar(query: query, pickedID: pickedID) else {
            throw CalendarError.noCalendar
        }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = end
        if let recurrence {
            event.addRecurrenceRule(Self.rule(for: recurrence))
        }
        try store.save(event, span: .thisEvent)
        UserDefaults.standard.set(calendar.calendarIdentifier, forKey: Self.lastCalendarKey)
        return calendar
    }

    private static func rule(for spec: RecurrenceSpec) -> EKRecurrenceRule {
        func weeklyRule(days: [EKWeekday], interval: Int) -> EKRecurrenceRule {
            EKRecurrenceRule(
                recurrenceWith: .weekly, interval: interval,
                daysOfTheWeek: days.map { EKRecurrenceDayOfWeek($0) },
                daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                daysOfTheYear: nil, setPositions: nil, end: nil)
        }
        switch spec {
        case .daily(let interval):
            return EKRecurrenceRule(recurrenceWith: .daily, interval: interval, end: nil)
        case .weekdays:
            return weeklyRule(days: [.monday, .tuesday, .wednesday, .thursday, .friday], interval: 1)
        case .week(let interval):
            return EKRecurrenceRule(recurrenceWith: .weekly, interval: interval, end: nil)
        case .weekly(let weekday, let interval):
            return weeklyRule(days: [EKWeekday(rawValue: weekday) ?? .monday], interval: interval)
        case .monthly(let interval):
            return EKRecurrenceRule(recurrenceWith: .monthly, interval: interval, end: nil)
        case .yearly(let interval):
            return EKRecurrenceRule(recurrenceWith: .yearly, interval: interval, end: nil)
        }
    }
}
