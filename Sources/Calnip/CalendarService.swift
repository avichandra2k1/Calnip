import EventKit
import Foundation

final class CalendarService {
    static let shared = CalendarService()
    private let store = EKEventStore()

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

    var defaultCalendar: EKCalendar? {
        store.defaultCalendarForNewEvents
    }

    /// Adds the event and returns the name of the calendar it landed in.
    func add(title: String, start: Date, end: Date) async throws -> String {
        guard await requestAccess() else { throw CalendarError.accessDenied }
        guard let calendar = defaultCalendar else { throw CalendarError.noCalendar }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = end
        try store.save(event, span: .thisEvent)
        return calendar.title
    }
}
