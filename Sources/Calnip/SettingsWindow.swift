import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage(Settings.viewModeKey) private var viewMode = "expanded"
    @AppStorage(Settings.showHintsKey) private var showHints = true
    @AppStorage(Settings.defaultDurationKey) private var duration = 60
    @AppStorage(Settings.defaultCalendarKey) private var defaultCalendar = "auto"
    @State private var calendars: [CalendarInfo] = []

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("View", selection: $viewMode) {
                    Text("Minimal").tag("minimal")
                    Text("Expanded").tag("expanded")
                }
                .pickerStyle(.segmented)
                Text(viewMode == "minimal"
                     ? "Just the input bar — details appear only while typing."
                     : "Shows today's events, nearby events and keyboard hints.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show keyboard hints", isOn: $showHints)
            }
            Section("Events") {
                Picker("Default duration", selection: $duration) {
                    ForEach([15, 30, 45, 60, 90, 120], id: \.self) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
                Picker("Default calendar", selection: $defaultCalendar) {
                    Text("Last used").tag("auto")
                    ForEach(calendars) { calendar in
                        Text(calendar.name).tag(calendar.id)
                    }
                }
            }
            Section("Shortcuts") {
                shortcutRow("⌥ Space", "Open / close Calnip")
                shortcutRow("↩", "Add event")
                shortcutRow("⌘ 1–9", "Pick calendar")
                shortcutRow("⌘ ,", "Settings")
                shortcutRow("esc", "Dismiss")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            guard await CalendarService.shared.requestAccess() else { return }
            calendars = CalendarService.shared.writableCalendars.map(CalendarInfo.init)
        }
    }

    private func shortcutRow(_ keys: String, _ label: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(keys)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = "Calnip Settings"
            w.contentViewController = NSHostingController(rootView: SettingsView())
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
