import AppKit
import Combine
import EventKit
import SwiftUI

enum Settings {
    static let viewModeKey = "viewMode"
    static let showHintsKey = "showHints"
    static let defaultDurationKey = "defaultDurationMinutes"
    static let defaultCalendarKey = "defaultCalendarID"
    static let calendarSlotsKey = "calendarSlots"

    static var isExpanded: Bool {
        UserDefaults.standard.string(forKey: viewModeKey) ?? "expanded" == "expanded"
    }
    static var defaultDuration: Int {
        let value = UserDefaults.standard.integer(forKey: defaultDurationKey)
        return value > 0 ? value : 60
    }
    /// ⌘1–9 slot assignments; empty string = unassigned slot.
    static var slotIDs: [String] {
        guard let raw = UserDefaults.standard.string(forKey: calendarSlotsKey), !raw.isEmpty else {
            return []
        }
        return raw.components(separatedBy: ",")
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

struct SlotCalendar: Equatable, Identifiable {
    let number: Int
    let info: CalendarInfo
    var id: String { info.id }
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

enum ArrowKey {
    case up, down, left, right
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
            browsedDay = nil
            resolveTarget()
            scheduleTimelineRefresh()
        }
    }
    @Published private(set) var parsed = ParsedEntry()
    @Published var status: Status = .idle
    @Published private(set) var target: CalendarInfo?
    @Published private(set) var queryUnmatched = false
    /// Events of the displayed day, all-day first, conflicts marked.
    @Published private(set) var timeline: [ContextEvent] = []
    @Published private(set) var calendars: [CalendarInfo] = []
    @Published private(set) var slotCalendars: [SlotCalendar] = []
    /// Non-nil while arrow-key browsing; overrides the parsed day.
    @Published private(set) var browsedDay: Date?

    private var accessGranted = false
    private var pickedCalendarID: String?
    private var timelineTask: Task<Void, Never>?

    /// Set by PanelController — called when the panel should close.
    var onDismiss: (() -> Void)?

    var canSubmit: Bool {
        !parsed.title.isEmpty && status != .saving
    }

    /// The day the timeline shows.
    var displayDay: Date {
        if let browsedDay { return browsedDay }
        if !text.isEmpty, let start = parsed.start { return start }
        return Date()
    }

    func reset() {
        text = ""
        status = .idle
        pickedCalendarID = nil
        browsedDay = nil
    }

    func prepare() {
        Task {
            accessGranted = await CalendarService.shared.requestAccess()
            resolveTarget()
            guard accessGranted else { return }
            calendars = CalendarService.shared.writableCalendars.map(CalendarInfo.init)
            loadSlots()
            scheduleTimelineRefresh()
        }
    }

    private func loadSlots() {
        let stored = Settings.slotIDs
        let ids = stored.isEmpty ? calendars.prefix(6).map(\.id) : stored
        slotCalendars = ids.enumerated().compactMap { index, id in
            guard !id.isEmpty, let info = calendars.first(where: { $0.id == id }) else { return nil }
            return SlotCalendar(number: index + 1, info: info)
        }
    }

    // MARK: - Calendar picking

    /// ⌘1–9 → assigned slot.
    func pickCalendar(_ number: Int) -> Bool {
        guard let slot = slotCalendars.first(where: { $0.number == number }) else { return false }
        pickedCalendarID = slot.info.id
        resolveTarget()
        return true
    }

    /// Click on a calendar in the footer index.
    func pickCalendar(id: String) {
        pickedCalendarID = id
        resolveTarget()
    }

    private func resolveTarget() {
        guard accessGranted else { return }
        queryUnmatched = parsed.calendarQuery.map { CalendarService.shared.match($0) == nil } ?? false
        target = CalendarService.shared
            .targetCalendar(query: parsed.calendarQuery, pickedID: pickedCalendarID)
            .map(CalendarInfo.init)
    }

    // MARK: - Day browsing (↓ then ←/→, ↑ back)

    func handleArrow(_ key: ArrowKey) -> Bool {
        switch key {
        case .down:
            if browsedDay == nil {
                browsedDay = Calendar.current.startOfDay(for: displayDay)
                scheduleTimelineRefresh()
            }
            return true
        case .up:
            guard browsedDay != nil else { return false }
            browsedDay = nil
            scheduleTimelineRefresh()
            return true
        case .left, .right:
            guard let day = browsedDay else { return false }
            browsedDay = Calendar.current.date(byAdding: .day, value: key == .right ? 1 : -1, to: day)
            scheduleTimelineRefresh()
            return true
        }
    }

    // MARK: - Timeline

    private func scheduleTimelineRefresh() {
        timelineTask?.cancel()
        guard accessGranted else { return }
        let day = displayDay
        let entry = parsed
        let typing = !text.isEmpty
        timelineTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let events = CalendarService.shared.eventsOnDay(of: day)
            guard !Task.isCancelled else { return }
            timeline = Self.buildTimeline(events: events, day: day, entry: typing ? entry : nil)
        }
    }

    /// All-day rows first, then timed rows (capped to the 8 nearest the focus
    /// time). Conflicts marked only for a timed entry on the displayed day —
    /// all-day events never conflict in either direction.
    private static func buildTimeline(events: [EKEvent], day: Date, entry: ParsedEntry?) -> [ContextEvent] {
        let calendar = Calendar.current
        var conflictWindow: (start: Date, end: Date)?
        if let entry, !entry.isAllDay, let start = entry.start, let end = entry.end,
           calendar.isDate(start, inSameDayAs: day) {
            conflictWindow = (start, end)
        }

        let allDayRows = events.filter(\.isAllDay).prefix(2)
            .map { ContextEvent($0, conflict: false) }

        var timed = events.filter { !$0.isAllDay }
        if timed.count > 8 {
            let focus = conflictWindow?.start
                ?? (calendar.isDateInToday(day) ? Date() : calendar.startOfDay(for: day).addingTimeInterval(9 * 3600))
            timed = timed
                .sorted { abs($0.startDate.timeIntervalSince(focus)) < abs($1.startDate.timeIntervalSince(focus)) }
                .prefix(8)
                .sorted { $0.startDate < $1.startDate }
        }
        let timedRows = timed.map { event in
            ContextEvent(event, conflict: conflictWindow.map {
                event.startDate < $0.end && event.endDate > $0.start
            } ?? false)
        }
        return allDayRows + timedRows
    }

    // MARK: - Actions

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
                try? await Task.sleep(nanoseconds: 900_000_000)
                // Stay open for the next entry — esc closes.
                text = ""
                status = .idle
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }
}
