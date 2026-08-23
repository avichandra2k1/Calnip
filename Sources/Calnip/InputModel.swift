import AppKit
import Combine
import EventKit
import SwiftUI

enum Settings {
    static let viewModeKey = "viewMode"
    static let showHintsKey = "showHints"
    static let defaultDurationKey = "defaultDurationMinutes"
    static let defaultCalendarKey = "defaultCalendarID"

    static var isExpanded: Bool {
        UserDefaults.standard.string(forKey: viewModeKey) ?? "expanded" == "expanded"
    }
    static var defaultDuration: Int {
        let value = UserDefaults.standard.integer(forKey: defaultDurationKey)
        return value > 0 ? value : 60
    }
}

struct CalendarInfo: Equatable, Identifiable {
    let id: String
    let name: String
    let color: Color

    init(_ calendar: EKCalendar) {
        id = calendar.calendarIdentifier
        name = calendar.title
        color = Color(nsColor: calendar.color ?? .controlAccentColor)
    }
}

struct ContextEvent: Equatable, Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let isConflict: Bool
    let color: Color

    init(_ event: EKEvent, conflict: Bool) {
        id = event.eventIdentifier ?? UUID().uuidString
        title = event.title ?? "Untitled"
        start = event.startDate
        end = event.endDate
        isAllDay = event.isAllDay
        isConflict = conflict
        color = Color(nsColor: event.calendar?.color ?? .controlAccentColor)
    }
}

@MainActor
final class InputModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case saving
        case saved(calendar: String)
        case error(String)
    }

    @Published var text: String = "" {
        didSet {
            parsed = Parser.parse(text, defaultDurationMinutes: Settings.defaultDuration)
            resolveTarget()
            scheduleContextRefresh()
        }
    }
    @Published private(set) var parsed = ParsedEntry()
    @Published var status: Status = .idle
    @Published private(set) var target: CalendarInfo?
    @Published private(set) var queryUnmatched = false
    @Published private(set) var context: [ContextEvent] = []
    @Published private(set) var todayEvents: [ContextEvent] = []
    @Published private(set) var calendars: [CalendarInfo] = []

    private var accessGranted = false
    private var pickedCalendarID: String?
    private var contextTask: Task<Void, Never>?

    /// Set by PanelController — called when the panel should close.
    var onDismiss: (() -> Void)?

    var canSubmit: Bool {
        !parsed.title.isEmpty && status != .saving
    }

    func reset() {
        text = ""
        status = .idle
        pickedCalendarID = nil
        context = []
    }

    func prepare() {
        Task {
            accessGranted = await CalendarService.shared.requestAccess()
            resolveTarget()
            guard accessGranted else { return }
            calendars = CalendarService.shared.writableCalendars.map(CalendarInfo.init)
            todayEvents = CalendarService.shared.eventsOnDay(of: Date())
                .map { ContextEvent($0, conflict: false) }
        }
    }

    /// Click on a calendar row.
    func pickCalendar(id: String) {
        pickedCalendarID = id
        resolveTarget()
    }

    /// ⌘1–9 → nth writable calendar (alphabetical).
    func pickCalendar(_ number: Int) -> Bool {
        guard accessGranted else { return false }
        let calendars = CalendarService.shared.writableCalendars
        guard number >= 1, number <= calendars.count else { return false }
        pickedCalendarID = calendars[number - 1].calendarIdentifier
        resolveTarget()
        return true
    }

    private func resolveTarget() {
        guard accessGranted else { return }
        queryUnmatched = parsed.calendarQuery.map { CalendarService.shared.match($0) == nil } ?? false
        target = CalendarService.shared
            .targetCalendar(query: parsed.calendarQuery, pickedID: pickedCalendarID)
            .map(CalendarInfo.init)
    }

    private func scheduleContextRefresh() {
        contextTask?.cancel()
        guard accessGranted, !text.isEmpty, let start = parsed.start, let end = parsed.end else {
            context = []
            return
        }
        let isAllDay = parsed.isAllDay
        contextTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let events = CalendarService.shared.eventsOnDay(of: start)
            guard !Task.isCancelled else { return }
            context = Self.buildContext(events: events, start: start, end: end, isAllDay: isAllDay)
        }
    }

    /// Conflicts plus up to two neighbors on each side, in time order.
    /// All-day events never conflict with anything — they appear as plain context,
    /// and an all-day entry being created conflicts with nothing.
    private static func buildContext(events: [EKEvent], start: Date, end: Date,
                                     isAllDay: Bool) -> [ContextEvent] {
        let allDayRows = events.filter(\.isAllDay).prefix(2)
            .map { ContextEvent($0, conflict: false) }
        let timed = events.filter { !$0.isAllDay }

        if isAllDay {
            return allDayRows + timed.prefix(4).map { ContextEvent($0, conflict: false) }
        }
        let conflicts = timed.filter { $0.startDate < end && $0.endDate > start }
        let before = timed.filter { $0.endDate <= start }.suffix(2)
        let after = timed.filter { $0.startDate >= end }.prefix(2)
        let rows = allDayRows
            + before.map { ContextEvent($0, conflict: false) }
            + conflicts.prefix(3).map { ContextEvent($0, conflict: true) }
            + after.map { ContextEvent($0, conflict: false) }
        // Conflicts always make the cut; the panel never grows past 6 rows.
        return Array(rows.sorted { $0.isConflict && !$1.isConflict }.prefix(6))
            .sorted { $0.start < $1.start }
    }

    func cancel() {
        onDismiss?()
    }

    func submit() {
        guard canSubmit, let start = parsed.start, let end = parsed.end else { return }
        let entry = parsed
        let pickedID = pickedCalendarID
        status = .saving
        Task {
            do {
                let calendar = try await CalendarService.shared.add(
                    title: entry.title, start: start, end: end, isAllDay: entry.isAllDay,
                    query: entry.calendarQuery, pickedID: pickedID,
                    recurrence: entry.recurrence, recurrenceEnd: entry.recurrenceEnd)
                status = .saved(calendar: calendar.title)
                try? await Task.sleep(nanoseconds: 750_000_000)
                onDismiss?()
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }
}
