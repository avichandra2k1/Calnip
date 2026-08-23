import AppKit
import Combine
import EventKit
import SwiftUI

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
    let isConflict: Bool
    let color: Color
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
            parsed = Parser.parse(text)
            resolveTarget()
            scheduleContextRefresh()
        }
    }
    @Published private(set) var parsed = ParsedEntry()
    @Published var status: Status = .idle
    @Published private(set) var target: CalendarInfo?
    @Published private(set) var queryUnmatched = false
    @Published private(set) var context: [ContextEvent] = []

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
        }
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
        contextTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let events = CalendarService.shared.eventsOnDay(of: start)
            guard !Task.isCancelled else { return }
            context = Self.buildContext(events: events, start: start, end: end)
        }
    }

    /// Conflicts plus up to two neighbors on each side, in time order.
    private static func buildContext(events: [EKEvent], start: Date, end: Date) -> [ContextEvent] {
        func row(_ event: EKEvent, conflict: Bool) -> ContextEvent {
            ContextEvent(
                id: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? "Untitled",
                start: event.startDate, end: event.endDate,
                isConflict: conflict,
                color: Color(nsColor: event.calendar?.color ?? .controlAccentColor))
        }
        let conflicts = events.filter { $0.startDate < end && $0.endDate > start }
        let before = events.filter { $0.endDate <= start }.suffix(2)
        let after = events.filter { $0.startDate >= end }.prefix(2)
        return (before.map { row($0, conflict: false) }
                + conflicts.prefix(3).map { row($0, conflict: true) }
                + after.map { row($0, conflict: false) })
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
                    title: entry.title, start: start, end: end,
                    query: entry.calendarQuery, pickedID: pickedID,
                    recurrence: entry.recurrence)
                status = .saved(calendar: calendar.title)
                try? await Task.sleep(nanoseconds: 750_000_000)
                onDismiss?()
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }
}
