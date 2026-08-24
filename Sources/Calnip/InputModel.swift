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
    static let launchKeyCodeKey = "launchKeyCode"
    static let launchModifiersKey = "launchModifiers"
    static let launchDisplayKey = "launchDisplay"
    static let editKeyKey = "editKey"
    static let calendarSymbolKey = "calendarSymbol"
    static let hiddenCalendarsKey = "hiddenCalendars"
    static let panelStyleKey = "panelStyle"   // "glass" | "opaque"
    static let showMenuBarIconKey = "showMenuBarIcon"

    static var showMenuBarIcon: Bool {
        UserDefaults.standard.object(forKey: showMenuBarIconKey) as? Bool ?? true
    }

    /// Calendars excluded from the timeline, conflicts, and ⌘-slots.
    static var hiddenCalendarIDs: Set<String> {
        guard let raw = UserDefaults.standard.string(forKey: hiddenCalendarsKey),
              !raw.isEmpty else { return [] }
        return Set(raw.components(separatedBy: ","))
    }

    /// Launch hotkey, Carbon encoding. Defaults: ⌥Space (keycode 49, optionKey).
    static var launchKeyCode: Int {
        UserDefaults.standard.object(forKey: launchKeyCodeKey) as? Int ?? 49
    }
    static var launchModifiers: Int {
        UserDefaults.standard.object(forKey: launchModifiersKey) as? Int ?? 2048
    }
    static var launchDisplay: String {
        UserDefaults.standard.string(forKey: launchDisplayKey) ?? "⌥ Space"
    }
    /// ⌘+letter that opens inline editing on the selected event.
    static var editKey: String {
        UserDefaults.standard.string(forKey: editKeyKey) ?? "e"
    }
    /// Prefix that targets a calendar in the input, e.g. ">work".
    static var calendarSymbol: String {
        UserDefaults.standard.string(forKey: calendarSymbolKey) ?? ">"
    }

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
    let calendarID: String

    init(_ event: EKEvent, conflict: Bool) {
        id = event.eventIdentifier ?? UUID().uuidString
        title = event.title ?? "Untitled"
        start = event.startDate
        end = event.endDate
        isAllDay = event.isAllDay
        isConflict = conflict
        color = Color(nsColor: event.calendar?.color ?? .controlAccentColor)
        calendarName = event.calendar?.title ?? ""
        calendarID = event.calendar?.calendarIdentifier ?? ""
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
            if !suppressTextSideEffects {
                browsedDay = nil
                selectedEventID = nil
                focusDate = nil
            }
            resolveTarget()
            refreshTimeline(debounce: true)
        }
    }
    private var suppressTextSideEffects = false
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
    /// Target calendar while editing (⌘1–9 retargets the edited event).
    @Published private(set) var editCalendarID: String?
    /// Where the timeline should center (a just-saved event); nil = now.
    @Published private(set) var focusDate: Date?
    /// The user denied (or restricted) calendar access; the app can't work.
    @Published private(set) var accessBlocked = false

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
        focusDate = nil
    }

    func prepare() {
        Task {
            accessGranted = await CalendarService.shared.requestAccess()
            accessBlocked = !accessGranted && CalendarService.shared.isAccessBlocked
            resolveTarget()
            guard accessGranted else { return }
            calendars = CalendarService.shared.writableCalendars.map(CalendarInfo.init)
            loadSlots()
            refreshTimeline()
            // Warm the surrounding days so browsing and "tom" render instantly.
            await CalendarService.shared.preload(around: Date())
            refreshTimeline()
        }
    }

    private func loadSlots() {
        let hidden = Settings.hiddenCalendarIDs
        let stored = Settings.slotIDs
        let ids = stored.isEmpty
            ? calendars.filter { !hidden.contains($0.id) }.prefix(5).map(\.id)
            : stored
        slotCalendars = ids.enumerated().compactMap { index, id in
            guard !id.isEmpty, !hidden.contains(id),
                  let info = calendars.first(where: { $0.id == id }) else { return nil }
            return SlotCalendar(number: index + 1, info: info)
        }
    }

    // MARK: - Calendar picking

    /// ⌘1–9 → assigned slot. While editing, retargets the edited event instead.
    func pickCalendar(_ number: Int) -> Bool {
        guard let slot = slotCalendars.first(where: { $0.number == number }) else { return false }
        pickCalendar(id: slot.info.id)
        return true
    }

    /// Click on a calendar in the footer index.
    func pickCalendar(id: String) {
        if editingEvent != nil {
            editCalendarID = id
        } else {
            pickedCalendarID = id
            resolveTarget()
        }
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
            let newDay = Calendar.current.date(byAdding: .day, value: key == .right ? 1 : -1, to: day) ?? day
            browsedDay = newDay
            selectedEventID = nil
            refreshTimeline()
            syncDayToken(to: newDay)
            return true
        }
    }

    /// Browsing a day means the entry is probably for that day — keep the
    /// text's day token in step: tom / yest / "aug 27" for anything further out.
    private func syncDayToken(to day: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: day)
        let delta = calendar.dateComponents([.day], from: today, to: target).day ?? 0

        let replacement: String?
        switch delta {
        case 0: replacement = nil
        case 1: replacement = "tom"
        case -1: replacement = "yest"
        case 2...365:
            let comps = calendar.dateComponents([.month, .day], from: target)
            let month = calendar.shortMonthSymbols[(comps.month ?? 1) - 1].lowercased()
            replacement = "\(month) \(comps.day ?? 1)"
        default:
            replacement = nil   // deeper past isn't expressible — clear the token
        }

        var newText = text
        if let token = parsed.tokens.first(where: {
            if case .day = $0.kind { return true }
            return false
        }) {
            newText = ((newText as NSString).replacingCharacters(in: token.removalRange, with: " "))
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        if let replacement {
            newText = newText.isEmpty ? replacement : "\(newText) \(replacement)"
        }
        guard newText != text else { return }
        suppressTextSideEffects = true
        text = newText
        suppressTextSideEffects = false
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
        editCalendarID = event.calendarID
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
        let calendarID = editCalendarID
        Task {
            do {
                try await CalendarService.shared.update(
                    eventID: event.id, title: entry.title, start: start, end: end,
                    isAllDay: entry.isAllDay, calendarQuery: entry.calendarQuery,
                    calendarID: calendarID)
                await CalendarService.shared.preload(around: start)
                endEdit()
                refreshTimeline()
            } catch {
                status = .error(error.localizedDescription)
                endEdit()
            }
        }
    }

    func cancelEdit() {
        endEdit()
    }

    private func endEdit() {
        editingEvent = nil
        editText = ""
        editCalendarID = nil
        NotificationCenter.default.post(name: .calnipFocusField, object: nil)
    }

    // MARK: - Timeline

    private func refreshTimeline(debounce: Bool = false) {
        timelineTask?.cancel()
        guard accessGranted else { return }
        // Normalized so the published day only changes when the calendar day
        // does — a raw parsed date would retrigger day-change scrolling.
        let day = Calendar.current.startOfDay(for: displayDay)
        let entry = parsed
        let typing = !text.isEmpty

        // Cached day → render synchronously; browsing feels instant. Stale
        // data still renders (never a blank flash) and revalidates behind it.
        if let cached = CalendarService.shared.cachedEvents(on: day) {
            timeline = TimelineState(
                day: day,
                rows: Self.buildRows(events: cached, day: day, entry: typing ? entry : nil)
            )
            if CalendarService.shared.isStale {
                timelineTask = Task {
                    await CalendarService.shared.preload(around: day)
                    guard !Task.isCancelled else { return }
                    refreshTimeline()
                }
            } else {
                CalendarService.shared.prefetchNeighborsIfNeeded(of: day)
            }
            return
        }
        timelineTask = Task {
            let events = await CalendarService.shared.events(on: day)
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
    private static func buildRows(events allEvents: [EKEvent], day: Date, entry: ParsedEntry?) -> [ContextEvent] {
        // Hidden calendars are invisible to both display and conflict checks.
        let hidden = Settings.hiddenCalendarIDs
        let events = hidden.isEmpty ? allEvents : allEvents.filter {
            !hidden.contains($0.calendar?.calendarIdentifier ?? "")
        }
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
                // Warm the cache during the toast so the refreshed timeline
                // (including the new event) renders instantly.
                let warm = Task { await CalendarService.shared.preload(around: start) }
                try? await Task.sleep(nanoseconds: 900_000_000)
                await warm.value
                // Stay open for the next entry — esc closes. The timeline stays
                // on the added event's day, centered on it.
                text = ""
                status = .idle
                browsedDay = Calendar.current.startOfDay(for: start)
                refreshTimeline()
                focusDate = start
                // Keep the next entry consistent with the day on screen.
                syncDayToken(to: start)
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }
}
