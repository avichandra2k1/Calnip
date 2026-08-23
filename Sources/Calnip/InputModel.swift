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
    let calendarName: String

    init(_ event: EKEvent, conflict: Bool) {
        id = event.eventIdentifier ?? UUID().uuidString
        title = event.title ?? "Untitled"
        start = event.startDate
        end = event.endDate
        isAllDay = event.isAllDay
        isConflict = conflict
        color = Color(nsColor: event.calendar?.color ?? .controlAccentColor)
        calendarName = event.calendar?.title ?? ""
    }
}

/// Day + rows published together so the header can never disagree with the
/// list while a refresh is in flight.
struct TimelineState: Equatable {
    var day = Date()
    var rows: [ContextEvent] = []
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
            selectedEventID = nil
            resolveTarget()
            refreshTimeline(debounce: true)
        }
    }
    @Published private(set) var parsed = ParsedEntry()
    @Published var status: Status = .idle
    @Published private(set) var target: CalendarInfo?
    @Published private(set) var queryUnmatched = false
    @Published private(set) var timeline = TimelineState()
    @Published private(set) var calendars: [CalendarInfo] = []
    @Published private(set) var slotCalendars: [SlotCalendar] = []
    /// Non-nil while arrow-key browsing; overrides the parsed day.
    @Published private(set) var browsedDay: Date?
    @Published private(set) var selectedEventID: String?
    @Published private(set) var editingEvent: ContextEvent?
    @Published var editText: String = ""

    private var accessGranted = false
    private var pickedCalendarID: String?
    private var timelineTask: Task<Void, Never>?

    /// Set by PanelController — called when the panel should close.
    var onDismiss: (() -> Void)?

    var canSubmit: Bool {
        !parsed.title.isEmpty && status != .saving
    }

    /// The day the timeline should show.
    private var displayDay: Date {
        if let browsedDay { return browsedDay }
        if !text.isEmpty, let start = parsed.start { return start }
        return Date()
    }

    func reset() {
        text = ""
        status = .idle
        pickedCalendarID = nil
        browsedDay = nil
        selectedEventID = nil
        editingEvent = nil
    }

    func prepare() {
        Task {
            accessGranted = await CalendarService.shared.requestAccess()
            resolveTarget()
            guard accessGranted else { return }
            calendars = CalendarService.shared.writableCalendars.map(CalendarInfo.init)
            loadSlots()
            refreshTimeline()
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

    // MARK: - Selection & day browsing (↓/↑ select, ←/→ days, ⌘E edit)

    func handleArrow(_ key: ArrowKey) -> Bool {
        guard editingEvent == nil else { return false }
        switch key {
        case .down:
            if browsedDay == nil {
                browsedDay = Calendar.current.startOfDay(for: displayDay)
            }
            moveSelection(1)
            return true
        case .up:
            guard browsedDay != nil || selectedEventID != nil else { return false }
            moveSelection(-1)
            return true
        case .left, .right:
            guard let day = browsedDay else { return false }
            browsedDay = Calendar.current.date(byAdding: .day, value: key == .right ? 1 : -1, to: day)
            selectedEventID = nil
            refreshTimeline()
            return true
        }
    }

    private func moveSelection(_ delta: Int) {
        let rows = timeline.rows
        guard !rows.isEmpty else {
            if delta < 0 { exitBrowse() }
            return
        }
        guard let current = selectedEventID,
              let index = rows.firstIndex(where: { $0.id == current }) else {
            if delta > 0 { selectedEventID = rows.first?.id }
            return
        }
        let next = index + delta
        if next < 0 {
            exitBrowse()
        } else if next < rows.count {
            selectedEventID = rows[next].id
        }
    }

    /// Click on an event block.
    func selectEvent(id: String) {
        selectedEventID = id
        if browsedDay == nil {
            browsedDay = Calendar.current.startOfDay(for: timeline.day)
        }
    }

    private func exitBrowse() {
        selectedEventID = nil
        browsedDay = nil
        refreshTimeline()
    }

    // MARK: - Editing (⌘E)

    var selectedEvent: ContextEvent? {
        timeline.rows.first { $0.id == selectedEventID }
    }

    func beginEdit() {
        guard editingEvent == nil, let event = selectedEvent else { return }
        editingEvent = event
        editText = Self.editPhrase(for: event)
    }

    /// "standup 3pm-4pm" — round-trips through the same parser.
    static func editPhrase(for event: ContextEvent) -> String {
        guard !event.isAllDay else { return event.title }
        func phrase(_ date: Date) -> String {
            let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
            let hour24 = comps.hour ?? 0
            let minute = comps.minute ?? 0
            let meridiem = hour24 >= 12 ? "pm" : "am"
            var hour = hour24 % 12
            if hour == 0 { hour = 12 }
            return minute == 0 ? "\(hour)\(meridiem)" : "\(hour):" + String(format: "%02d", minute) + meridiem
        }
        return "\(event.title) \(phrase(event.start))-\(phrase(event.end))"
    }

    func commitEdit() {
        guard let event = editingEvent else { return }
        // Parse relative to the event's own day so "4pm" keeps it on that day.
        let entry = Parser.parse(editText, now: event.start,
                                 defaultDurationMinutes: Settings.defaultDuration)
        guard !entry.title.isEmpty, let start = entry.start, let end = entry.end else { return }
        Task {
            do {
                try await CalendarService.shared.update(
                    eventID: event.id, title: entry.title, start: start, end: end,
                    isAllDay: entry.isAllDay, calendarQuery: entry.calendarQuery)
                editingEvent = nil
                editText = ""
                refreshTimeline()
                NotificationCenter.default.post(name: .calnipPanelDidShow, object: nil)
            } catch {
                status = .error(error.localizedDescription)
                editingEvent = nil
                editText = ""
                NotificationCenter.default.post(name: .calnipPanelDidShow, object: nil)
            }
        }
    }

    func cancelEdit() {
        editingEvent = nil
        editText = ""
        NotificationCenter.default.post(name: .calnipPanelDidShow, object: nil)
    }

    // MARK: - Timeline

    private func refreshTimeline(debounce: Bool = false) {
        timelineTask?.cancel()
        guard accessGranted else { return }
        let day = displayDay
        let entry = parsed
        let typing = !text.isEmpty
        timelineTask = Task {
            if debounce {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
            }
            let events = CalendarService.shared.eventsOnDay(of: day)
            guard !Task.isCancelled else { return }
            timeline = TimelineState(
                day: day,
                rows: Self.buildRows(events: events, day: day, entry: typing ? entry : nil)
            )
        }
    }

    /// All-day rows first, then every timed event of the day (the view
    /// scrolls). Conflicts marked only for a timed entry on the displayed day —
    /// all-day events never conflict in either direction.
    private static func buildRows(events: [EKEvent], day: Date, entry: ParsedEntry?) -> [ContextEvent] {
        let calendar = Calendar.current
        var conflictWindow: (start: Date, end: Date)?
        if let entry, !entry.isAllDay, let start = entry.start, let end = entry.end,
           calendar.isDate(start, inSameDayAs: day) {
            conflictWindow = (start, end)
        }

        let allDayRows = events.filter(\.isAllDay).prefix(3)
            .map { ContextEvent($0, conflict: false) }
        let timedRows = events.filter { !$0.isAllDay }.map { event in
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
