import AppKit
import Combine
import Foundation

@MainActor
final class InputModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case saving
        case saved(calendar: String)
        case error(String)
    }

    @Published var text: String = "" {
        didSet { parsed = Parser.parse(text) }
    }
    @Published private(set) var parsed = ParsedEntry()
    @Published var status: Status = .idle
    @Published var calendarName: String = "Calendar"

    /// Set by PanelController — called when the panel should close.
    var onDismiss: (() -> Void)?

    var canSubmit: Bool {
        !parsed.title.isEmpty && status != .saving
    }

    func reset() {
        text = ""
        status = .idle
    }

    func loadCalendarName() {
        Task {
            if await CalendarService.shared.requestAccess(),
               let name = CalendarService.shared.defaultCalendar?.title {
                calendarName = name
            }
        }
    }

    func cancel() {
        onDismiss?()
    }

    func submit() {
        guard canSubmit, let start = parsed.start, let end = parsed.end else { return }
        let title = parsed.title
        status = .saving
        Task {
            do {
                let calendar = try await CalendarService.shared.add(title: title, start: start, end: end)
                status = .saved(calendar: calendar)
                try? await Task.sleep(nanoseconds: 750_000_000)
                onDismiss?()
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }
}
