import AppKit
import Carbon.HIToolbox
import SwiftUI

extension Notification.Name {
    static let calnipHotkeyChanged = Notification.Name("com.avi.calnip.hotkeyChanged")
}

// MARK: - Settings view

/// Behind-window translucency, macOS Settings style.
private struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

enum SettingsTab: String, CaseIterable {
    case general, appearance, shortcuts, calendarsTab

    var label: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .shortcuts: return "Shortcuts"
        case .calendarsTab: return "Calendars"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .shortcuts: return "keyboard"
        case .calendarsTab: return "calendar"
        }
    }
}

struct SettingsView: View {
    @AppStorage(Settings.viewModeKey) private var viewMode = "expanded"
    @AppStorage(Settings.panelStyleKey) private var panelStyle = "glass"
    @AppStorage(Settings.defaultDurationKey) private var duration = 60
    @AppStorage(Settings.defaultCalendarKey) private var defaultCalendar = "auto"
    @AppStorage(Settings.calendarSlotsKey) private var slotsRaw = ""
    @AppStorage(Settings.calendarSymbolKey) private var calendarSymbol = ">"
    @AppStorage(Settings.hiddenCalendarsKey) private var hiddenRaw = ""
    @AppStorage(Settings.showMenuBarIconKey) private var showMenuBarIcon = true
    @State private var calendars: [CalendarInfo] = []
    @State private var tab: SettingsTab = .general
    @State private var accessBlocked = false

    private let contentWidth: CGFloat = 560

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var body: some View {
        ZStack {
            WindowBackdrop()
                .ignoresSafeArea()
            content
        }
        .frame(width: contentWidth, height: 560)
        .task {
            guard await CalendarService.shared.requestAccess() else {
                accessBlocked = CalendarService.shared.isAccessBlocked
                return
            }
            calendars = CalendarService.shared.writableCalendars.map(CalendarInfo.init)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            tabBar
            hairline
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .general: generalTab
                    case .appearance: appearanceTab
                    case .shortcuts: shortcutsTab
                    case .calendarsTab: calendarsTab
                    }
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .frame(width: contentWidth, alignment: .leading)
            }
            hairline
            footer
        }
    }

    // MARK: Tab bar

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(SettingsTab.allCases, id: \.self) { item in
                let selected = tab == item
                VStack(spacing: 3) {
                    Image(systemName: item.icon)
                        .font(.system(size: 15, weight: .medium))
                    Text(item.label)
                        .font(.system(size: 11, weight: selected ? .medium : .regular))
                }
                .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 86)
                .padding(.vertical, 7)
                .background(
                    selected ? AnyShapeStyle(.quaternary.opacity(0.55)) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 9)
                )
                .contentShape(.rect)
                .onTapGesture { tab = item }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
    }

    // MARK: Tabs

    @ViewBuilder
    private var generalTab: some View {
        row("Default event duration",
            caption: "Applied when no end time is typed.") {
            Picker("", selection: $duration) {
                ForEach([15, 30, 45, 60, 90, 120], id: \.self) { minutes in
                    Text("\(minutes) min").tag(minutes)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        hairline
        row("Calendar prefix",
            caption: "\(calendarSymbol)work targets a matching calendar.") {
            Picker("", selection: $calendarSymbol) {
                ForEach([">", "@", "#", "/"], id: \.self) { symbol in
                    Text(symbol).tag(symbol)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
        }
    }

    @ViewBuilder
    private var appearanceTab: some View {
        row("View mode") {
            Picker("", selection: $viewMode) {
                Text("Minimal").tag("minimal")
                Text("Expanded").tag("expanded")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
        }
        hairline
        row("Panel background") {
            Picker("", selection: $panelStyle) {
                Text("Glass").tag("glass")
                Text("Opaque").tag("opaque")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
        }
        hairline
        row("Show menu bar icon") {
            Toggle("", isOn: $showMenuBarIcon)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private var shortcutsTab: some View {
        row("Open Calnip") {
            LaunchHotkeyRecorder()
        }
        hairline
        row("Edit selected event") {
            EditKeyRecorder()
        }
        hairline
        sectionHeader("Fixed keys")
        HStack(spacing: 16) {
            fixedShortcut("↩", "add")
            fixedShortcut("esc", "close")
            fixedShortcut("↓", "select")
            fixedShortcut("← →", "days")
            fixedShortcut("⌘1–9", "calendar")
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var calendarsTab: some View {
        if accessBlocked {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calendar access not granted")
                        .font(.system(size: 13, weight: .medium))
                    Text("Grant full calendar access, then reopen Calnip.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Privacy Settings") {
                    CalendarService.openPrivacySettings()
                }
                .controlSize(.small)
            }
            .padding(14)
            .background(.orange.opacity(0.1), in: .rect(cornerRadius: 12))
            .padding(.top, 12)
        }
        row("Default calendar") {
            Picker("", selection: $defaultCalendar) {
                Text("Last used").tag("auto")
                Divider()
                ForEach(calendars) { calendar in
                    Text(calendar.name).tag(calendar.id)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        hairline
        Text("Hidden calendars are excluded from the timeline and conflicts.")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.top, 12)
            .padding(.bottom, 4)
        ForEach(Array(calendars.enumerated()), id: \.element.id) { index, calendar in
            calendarRow(calendar)
            if index < calendars.count - 1 {
                hairline
            }
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(.quaternary.opacity(0.4))
            .frame(height: 1)
    }

    // MARK: Header / footer

    private var header: some View {
        VStack(spacing: 7) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.secondary)
            Text("Calnip Settings")
                .font(.system(size: 16, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 26)
        .padding(.bottom, 16)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock")
                .font(.system(size: 10))
            Text("Local-only. Works directly with Apple Calendar.")
                .font(.system(size: 11))
            Spacer()
            Text("Calnip \(version)")
                .font(.system(size: 11))
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 24)
        .padding(.vertical, 11)
    }

    // MARK: Rows

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .kerning(0.4)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }

    private func row(_ label: String, caption: String? = nil,
                     @ViewBuilder control: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13))
                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            control()
        }
        .padding(.vertical, 11)
    }

    private func fixedShortcut(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Keycap(keys)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Calendars

    private func calendarRow(_ calendar: CalendarInfo) -> some View {
        let visible = visibilityBinding(for: calendar.id)
        return HStack(spacing: 10) {
            Circle()
                .fill(calendar.color)
                .frame(width: 10, height: 10)
            Text(calendar.name)
                .font(.system(size: 13))
                .foregroundStyle(visible.wrappedValue ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            Spacer(minLength: 0)
            Picker("", selection: assignBinding(for: calendar.id)) {
                Text("—").tag(0)
                ForEach(1...9, id: \.self) { number in
                    Text("⌘\(number)").tag(number)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!visible.wrappedValue)
            Toggle("", isOn: visible)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.vertical, 7)
    }

    private func visibilityBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: {
                !hiddenRaw.components(separatedBy: ",").contains(id)
            },
            set: { visible in
                var hidden = Set(hiddenRaw.components(separatedBy: ",").filter { !$0.isEmpty })
                if visible { hidden.remove(id) } else { hidden.insert(id) }
                hiddenRaw = hidden.sorted().joined(separator: ",")
            }
        )
    }

    // MARK: Slot storage (slots persist as comma-joined calendar IDs)

    private func effectiveSlots() -> [String] {
        var slots: [String]
        if slotsRaw.isEmpty {
            slots = calendars.prefix(5).map(\.id)
        } else {
            slots = slotsRaw.components(separatedBy: ",")
        }
        while slots.count < 9 { slots.append("") }
        return slots
    }

    /// Assignment from the calendar's side; picking a taken number steals it.
    private func assignBinding(for calendarID: String) -> Binding<Int> {
        Binding(
            get: {
                (effectiveSlots().firstIndex(of: calendarID)).map { $0 + 1 } ?? 0
            },
            set: { newNumber in
                var slots = effectiveSlots()
                for index in slots.indices where slots[index] == calendarID {
                    slots[index] = ""
                }
                if newNumber > 0 { slots[newNumber - 1] = calendarID }
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
