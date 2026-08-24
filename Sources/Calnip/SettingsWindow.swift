import AppKit
import Carbon.HIToolbox
import SwiftUI

extension Notification.Name {
    static let calnipHotkeyChanged = Notification.Name("com.avi.calnip.hotkeyChanged")
}

// MARK: - Settings view

struct SettingsView: View {
    @AppStorage(Settings.viewModeKey) private var viewMode = "expanded"
    @AppStorage(Settings.defaultDurationKey) private var duration = 60
    @AppStorage(Settings.defaultCalendarKey) private var defaultCalendar = "auto"
    @AppStorage(Settings.calendarSlotsKey) private var slotsRaw = ""
    @AppStorage(Settings.calendarSymbolKey) private var calendarSymbol = ">"
    @State private var calendars: [CalendarInfo] = []

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            divider
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    generalCard
                    shortcutsCard
                    calendarsCard
                }
                .padding(20)
            }
            divider
            footer
        }
        .frame(width: 560, height: 680)
        .task {
            guard await CalendarService.shared.requestAccess() else { return }
            calendars = CalendarService.shared.writableCalendars.map(CalendarInfo.init)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(.quaternary.opacity(0.5))
            .frame(height: 1)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 56, height: 56)
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Calnip")
                        .font(.system(size: 22, weight: .bold))
                    Text("v\(version)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary.opacity(0.6), in: .capsule)
                }
                Text("Type it. It's on your calendar.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 26)
        .padding(.bottom, 18)
    }

    // MARK: Cards

    private func card(_ title: String, icon: String,
                      @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.22), in: .rect(cornerRadius: 14))
    }

    private func row(_ label: String, caption: String? = nil,
                     @ViewBuilder control: () -> some View) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13))
                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            control()
        }
        .padding(.vertical, 7)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(.quaternary.opacity(0.4))
            .frame(height: 1)
    }

    private var generalCard: some View {
        card("General", icon: "slider.horizontal.3") {
            row("View", caption: viewMode == "minimal"
                ? "Just the input bar — details appear while typing."
                : "Day timeline, conflicts and shortcuts.") {
                Picker("", selection: $viewMode) {
                    Text("Minimal").tag("minimal")
                    Text("Expanded").tag("expanded")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }
            rowDivider
            row("Default duration", caption: "For events typed without an end time.") {
                Picker("", selection: $duration) {
                    ForEach([15, 30, 45, 60, 90, 120], id: \.self) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
            }
        }
    }

    private var shortcutsCard: some View {
        card("Shortcuts", icon: "keyboard") {
            row("Open Calnip", caption: "Summons the panel from anywhere.") {
                LaunchHotkeyRecorder()
            }
            rowDivider
            row("Edit selected event", caption: "⌘ plus a letter, while an event is selected.") {
                EditKeyRecorder()
            }
            rowDivider
            row("Calendar prefix", caption: "Type \(calendarSymbol)work to file into a matching calendar.") {
                Picker("", selection: $calendarSymbol) {
                    ForEach([">", "@", "#", "/"], id: \.self) { symbol in
                        Text(symbol).tag(symbol)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }
            rowDivider
            HStack(spacing: 18) {
                fixedShortcut("↩", "add")
                fixedShortcut("esc", "close")
                fixedShortcut("↓", "select")
                fixedShortcut("← →", "days")
                fixedShortcut("⌘1–9", "calendar")
                Spacer()
            }
            .padding(.top, 8)
        }
    }

    private func fixedShortcut(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Keycap(keys)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private var calendarsCard: some View {
        card("Calendars", icon: "calendar") {
            row("Default calendar", caption: "Where events go unless you pick otherwise.") {
                Picker("", selection: $defaultCalendar) {
                    Text("Last used").tag("auto")
                    ForEach(calendars) { calendar in
                        Text(calendar.name).tag(calendar.id)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            rowDivider
            Text("⌘1–9 assignments")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .padding(.bottom, 4)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(0..<3, id: \.self) { rowIndex in
                    GridRow {
                        ForEach(0..<3, id: \.self) { columnIndex in
                            let number = rowIndex * 3 + columnIndex + 1
                            HStack(spacing: 6) {
                                Keycap("⌘\(number)")
                                Picker("", selection: slotBinding(number)) {
                                    Text("None").tag("")
                                    ForEach(calendars) { calendar in
                                        Text(calendar.name).tag(calendar.id)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 118)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock")
                .font(.system(size: 10))
            Text("Calnip \(version) — a tiny launcher for Apple Calendar. Everything stays on your Mac.")
                .font(.system(size: 11))
            Spacer()
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    // MARK: Slot storage

    /// Slots persist as comma-joined calendar IDs; empty entry = unassigned.
    private func slotBinding(_ number: Int) -> Binding<String> {
        Binding(
            get: {
                if slotsRaw.isEmpty {
                    return number <= 5 && number - 1 < calendars.count ? calendars[number - 1].id : ""
                }
                let slots = slotsRaw.components(separatedBy: ",")
                return number - 1 < slots.count ? slots[number - 1] : ""
            },
            set: { newValue in
                var slots: [String]
                if slotsRaw.isEmpty {
                    slots = (0..<9).map { $0 < 5 && $0 < calendars.count ? calendars[$0].id : "" }
                } else {
                    slots = slotsRaw.components(separatedBy: ",")
                }
                while slots.count < 9 { slots.append("") }
                slots[number - 1] = newValue
                slotsRaw = slots.joined(separator: ",")
            }
        )
    }
}

// MARK: - Hotkey recorders

private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
    var result = 0
    if flags.contains(.command) { result |= cmdKey }
    if flags.contains(.shift) { result |= shiftKey }
    if flags.contains(.option) { result |= optionKey }
    if flags.contains(.control) { result |= controlKey }
    return result
}

private func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
    var symbols = ""
    if flags.contains(.control) { symbols += "⌃" }
    if flags.contains(.option) { symbols += "⌥" }
    if flags.contains(.shift) { symbols += "⇧" }
    if flags.contains(.command) { symbols += "⌘" }
    return symbols
}

private func keyName(for event: NSEvent) -> String {
    switch Int(event.keyCode) {
    case kVK_Space: return "Space"
    case kVK_Return: return "↩"
    case kVK_Tab: return "⇥"
    case kVK_Delete: return "⌫"
    default: return event.charactersIgnoringModifiers?.uppercased() ?? "?"
    }
}

private struct RecorderChrome: ViewModifier {
    let recording: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(recording ? 0.7 : 0.45), in: .capsule)
            .overlay {
                if recording {
                    Capsule().strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
            .contentShape(.capsule)
    }
}

/// Records the global launch hotkey (any modifier + key).
struct LaunchHotkeyRecorder: View {
    @State private var recording = false
    @State private var monitor: Any?
    @State private var display = Settings.launchDisplay

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Type shortcut…" : display)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(recording ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .modifier(RecorderChrome(recording: recording))
        }
        .buttonStyle(.plain)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.isEmpty else {
                NSSound.beep()
                return nil
            }
            let text = "\(modifierSymbols(flags)) \(keyName(for: event))"
            let defaults = UserDefaults.standard
            defaults.set(Int(event.keyCode), forKey: Settings.launchKeyCodeKey)
            defaults.set(carbonModifiers(from: flags), forKey: Settings.launchModifiersKey)
            defaults.set(text, forKey: Settings.launchDisplayKey)
            display = text
            NotificationCenter.default.post(name: .calnipHotkeyChanged, object: nil)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Records the ⌘+letter used to edit the selected event.
struct EditKeyRecorder: View {
    @State private var recording = false
    @State private var monitor: Any?
    @State private var key = Settings.editKey

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "⌘ + letter…" : "⌘ \(key.uppercased())")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(recording ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .modifier(RecorderChrome(recording: recording))
        }
        .buttonStyle(.plain)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            guard event.modifierFlags.contains(.command),
                  let letter = event.charactersIgnoringModifiers?.lowercased(),
                  letter.count == 1, letter.first?.isLetter == true,
                  letter != "q", letter != ","    // keep Quit and Settings
            else {
                NSSound.beep()
                return nil
            }
            UserDefaults.standard.set(letter, forKey: Settings.editKeyKey)
            key = letter
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Window

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.title = "Calnip Settings"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.contentViewController = NSHostingController(rootView: SettingsView())
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
