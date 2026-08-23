import SwiftUI

struct PanelView: View {
    @ObservedObject var model: InputModel
    @AppStorage(Settings.viewModeKey) private var viewMode = "expanded"

    private var expanded: Bool { viewMode == "expanded" }
    private var typing: Bool { !model.text.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputRow
            if expanded {
                expandedContent
            } else if typing {
                chipsRow
                    .padding(.horizontal, 22)
                    .padding(.bottom, 14)
                if !model.context.isEmpty, model.status == .idle {
                    eventSection(model.context, header: nil)
                        .padding(.bottom, 14)
                }
            }
        }
        .frame(width: expanded ? 780 : 640, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        // Transparent margin so the glass material's soft shadow can fade out
        // instead of clipping in a hard rectangle at the window edge.
        .padding(40)
    }

    // MARK: - Expanded (Raycast-style) layout

    @ViewBuilder
    private var expandedContent: some View {
        divider
        VStack(alignment: .leading, spacing: 14) {
            if typing {
                chipsRow
                    .padding(.horizontal, 24)
                if !model.context.isEmpty, model.status == .idle {
                    eventSection(model.context, header: "Schedule")
                }
            } else if !todayDisplay.isEmpty {
                eventSection(todayDisplay, header: "Today")
            }
        }
        .padding(.vertical, 14)
        divider
        footer
    }

    /// Next few things today — upcoming first, capped so the panel stays short.
    private var todayDisplay: [ContextEvent] {
        let now = Date()
        let upcoming = model.todayEvents.filter { $0.isAllDay || $0.end >= now }
        if upcoming.isEmpty {
            return Array(model.todayEvents.suffix(2))
        }
        return Array(upcoming.prefix(5))
    }

    private var divider: some View {
        Rectangle()
            .fill(.quaternary.opacity(0.5))
            .frame(height: 1)
    }

    private var inputRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                if model.text.isEmpty {
                    Text("New event — try “lunch 12-1 tom”")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
                TokenField(
                    text: $model.text,
                    onSubmit: { model.submit() },
                    onCancel: { model.cancel() }
                )
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    // MARK: - Chips

    @ViewBuilder
    private var chipsRow: some View {
        HStack(spacing: 8) {
            switch model.status {
            case .saved(let calendar):
                Label("Added to \(calendar)", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.green)
            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            default:
                Chip(icon: "calendar", text: dayText)
                if model.parsed.isAllDay {
                    Chip(icon: "sun.max", text: "All day")
                } else {
                    Chip(icon: "clock", text: timeText)
                }
                if let recurrence = model.parsed.recurrence {
                    Chip(icon: "repeat", text: recurrence.label)
                }
                if let until = model.parsed.recurrenceEnd {
                    Chip(icon: "arrow.right.to.line", text: "Until \(untilText(until))")
                }
                if model.queryUnmatched, let query = model.parsed.calendarQuery {
                    Chip(icon: "questionmark.circle", text: query, tint: .orange)
                } else if !expanded, let target = model.target {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(target.color)
                            .frame(width: 8, height: 8)
                        Text(target.name)
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(0.5), in: .capsule)
                }
            }
            Spacer()
            if model.status == .saving {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Event lists

    private func eventSection(_ events: [ContextEvent], header: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let header {
                sectionHeader(header)
            }
            ForEach(events) { event in
                eventRow(event)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 24)
            .padding(.bottom, 4)
    }

    private func eventRow(_ event: ContextEvent) -> some View {
        let past = !event.isAllDay && event.end < Date()
        return HStack(spacing: 12) {
            if event.isConflict {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .frame(width: 16)
            } else {
                Circle()
                    .fill(event.color.opacity(past ? 0.4 : 1))
                    .frame(width: 9, height: 9)
                    .frame(width: 16)
            }
            Text(event.isConflict ? "Conflicts with \(event.title)" : event.title)
                .font(.system(size: 14, weight: event.isConflict ? .medium : .regular))
                .foregroundStyle(event.isConflict ? AnyShapeStyle(.red)
                                 : past ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .lineLimit(1)
            Spacer()
            Text(event.isAllDay ? "All day" : rangeText(event.start, event.end))
                .font(.system(size: 13))
                .foregroundStyle(event.isConflict ? AnyShapeStyle(.red.opacity(0.8)) : AnyShapeStyle(.secondary))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            event.isConflict ? AnyShapeStyle(.red.opacity(0.08)) : AnyShapeStyle(.clear),
            in: .rect(cornerRadius: 10)
        )
        .padding(.horizontal, 10)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            calendarIndex
            Spacer()
            Button {
                model.cancel()
                SettingsWindowController.shared.show()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(6)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            Rectangle()
                .fill(.quaternary)
                .frame(width: 1, height: 18)
            footerAction("Add", key: "↩", emphasized: model.canSubmit) {
                model.submit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// ⌘1–9 index in two compact rows — name and shortcut always visible,
    /// the active target highlighted.
    private var calendarIndex: some View {
        let calendars = Array(model.calendars.prefix(9).enumerated())
        let half = (calendars.count + 1) / 2
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                ForEach(calendars[..<half], id: \.element.id) { index, calendar in
                    calendarIndexItem(calendar, number: index + 1)
                }
            }
            if calendars.count > half {
                HStack(spacing: 4) {
                    ForEach(calendars[half...], id: \.element.id) { index, calendar in
                        calendarIndexItem(calendar, number: index + 1)
                    }
                }
            }
        }
    }

    private func calendarIndexItem(_ calendar: CalendarInfo, number: Int) -> some View {
        let isTarget = model.target?.id == calendar.id
        return HStack(spacing: 5) {
            Text("⌘\(number)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isTarget ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            Circle()
                .fill(calendar.color)
                .frame(width: 7, height: 7)
            Text(calendar.name)
                .font(.system(size: 11, weight: isTarget ? .medium : .regular))
                .foregroundStyle(isTarget ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            isTarget ? AnyShapeStyle(.quaternary.opacity(0.7)) : AnyShapeStyle(.clear),
            in: .capsule
        )
        .contentShape(.rect)
        .onTapGesture { model.pickCalendar(id: calendar.id) }
    }

    private func footerAction(_ label: String, key: String, emphasized: Bool = true,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                Keycap(key)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(emphasized ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
    }

    // MARK: - Text helpers

    private var dayText: String {
        guard let start = model.parsed.start else { return "Today" }
        let calendar = Calendar.current
        if calendar.isDateInToday(start) { return "Today" }
        if calendar.isDateInTomorrow(start) { return "Tomorrow" }
        return start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private var timeText: String {
        guard let start = model.parsed.start else { return "" }
        let from = start.formatted(date: .omitted, time: .shortened)
        if model.parsed.hasExplicitEnd, let end = model.parsed.end {
            return "\(from) – \(end.formatted(date: .omitted, time: .shortened))"
        }
        return from
    }

    private func untilText(_ date: Date) -> String {
        if let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func rangeText(_ start: Date, _ end: Date) -> String {
        "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }
}

// MARK: - Components

/// Raycast-style key cap: small rounded square with the key symbol.
struct Keycap: View {
    let symbol: String

    init(_ symbol: String) {
        self.symbol = symbol
    }

    var body: some View {
        Text(symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.8), in: .rect(cornerRadius: 6))
    }
}

private struct Chip: View {
    let icon: String
    let text: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.system(size: 14, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12), in: .capsule)
    }
}
