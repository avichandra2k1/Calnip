import SwiftUI

struct PanelView: View {
    @ObservedObject var model: InputModel
    @AppStorage(Settings.viewModeKey) private var viewMode = "expanded"

    private var expanded: Bool { viewMode == "expanded" }
    private var typing: Bool { !model.text.isEmpty }

    // Timeline metrics — the spine line must cross the dot column's center.
    private let timeColumnWidth: CGFloat = 70
    private let dotColumnWidth: CGFloat = 16
    private let rowSpacing: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputRow
            if expanded {
                expandedContent
            } else if typing {
                chipsRow
                    .padding(.horizontal, 22)
                    .padding(.bottom, 14)
                let conflicts = model.timeline.filter(\.isConflict)
                if !conflicts.isEmpty, model.status == .idle {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(conflicts) { conflictRow($0) }
                    }
                    .padding(.horizontal, 24)
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

    @ViewBuilder
    private var expandedContent: some View {
        divider
        VStack(alignment: .leading, spacing: 12) {
            if typing {
                chipsRow
                    .padding(.horizontal, 24)
            }
            timelineSection
        }
        .padding(.vertical, 14)
        divider
        footer
    }

    private var divider: some View {
        Rectangle()
            .fill(.quaternary.opacity(0.5))
            .frame(height: 1)
    }

    // MARK: - Input

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
                    onCancel: { model.cancel() },
                    onArrow: { model.handleArrow($0) }
                )
            }
            if expanded {
                HStack(spacing: 6) {
                    Keycap("esc")
                    Text("close")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.tertiary)
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
                if !model.queryUnmatched, let target = model.target {
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
                if let recurrence = model.parsed.recurrence {
                    Chip(icon: "repeat", text: recurrence.label)
                }
                if let until = model.parsed.recurrenceEnd {
                    Chip(icon: "arrow.right.to.line", text: "Until \(untilText(until))")
                }
                if model.queryUnmatched, let query = model.parsed.calendarQuery {
                    Chip(icon: "questionmark.circle", text: query, tint: .orange)
                }
            }
            Spacer()
            if model.status == .saving {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Timeline

    private enum TimelineRow: Identifiable {
        case event(ContextEvent)
        case nowLine
        case preview

        var id: String {
            switch self {
            case .event(let event): return event.id
            case .nowLine: return "now-line"
            case .preview: return "preview"
            }
        }
    }

    private var timelineSection: some View {
        let day = model.displayDay
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(day)
        let previewOnDay = typing && model.status == .idle
            && model.parsed.start.map { calendar.isDate($0, inSameDayAs: day) } ?? false

        let allDay = model.timeline.filter(\.isAllDay)
        let timed = model.timeline.filter { !$0.isAllDay }

        // Interleave events, the now line, and the typed preview chronologically.
        var keyed: [(Date, TimelineRow)] = timed.map { ($0.start, .event($0)) }
        if isToday {
            keyed.append((Date(), .nowLine))
        }
        if previewOnDay, !model.parsed.isAllDay, let start = model.parsed.start {
            keyed.append((start.addingTimeInterval(1), .preview))
        }
        let rows = keyed.sorted { $0.0 < $1.0 }.map(\.1)
        let showAllDayPreview = previewOnDay && model.parsed.isAllDay

        return VStack(alignment: .leading, spacing: 6) {
            timelineHeader(day: day, isToday: isToday)
            if allDay.isEmpty, rows.isEmpty, !showAllDayPreview {
                Text("No events")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 24 + timeColumnWidth + rowSpacing + dotColumnWidth + rowSpacing)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if showAllDayPreview {
                        previewRow(allDay: true)
                    }
                    ForEach(allDay) { timelineEventRow($0, isToday: isToday) }
                    ForEach(rows) { row in
                        switch row {
                        case .event(let event): timelineEventRow(event, isToday: isToday)
                        case .nowLine: nowLine
                        case .preview: previewRow(allDay: false)
                        }
                    }
                }
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.quaternary.opacity(0.5))
                        .frame(width: 1)
                        .padding(.vertical, 6)
                        .offset(x: 24 + timeColumnWidth + rowSpacing + dotColumnWidth / 2)
                }
            }
        }
    }

    private func timelineHeader(day: Date, isToday: Bool) -> some View {
        HStack(spacing: 8) {
            Text(dayHeader(day, isToday: isToday))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
            Spacer()
            if model.browsedDay != nil {
                HStack(spacing: 4) {
                    Keycap("←")
                    Keycap("→")
                    Text("days")
                        .font(.system(size: 11))
                    Keycap("↑")
                    Text("back")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 4) {
                    Keycap("↓")
                    Text("browse")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 24)
    }

    private func dayHeader(_ day: Date, isToday: Bool) -> String {
        let dateText = day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        if isToday { return "Today — \(dateText)" }
        if Calendar.current.isDateInTomorrow(day) { return "Tomorrow — \(dateText)" }
        return dateText
    }

    private func timelineEventRow(_ event: ContextEvent, isToday: Bool) -> some View {
        let past = !event.isAllDay && event.end < Date() && isToday
        let timeStyle: AnyShapeStyle = event.isConflict ? AnyShapeStyle(.red.opacity(0.9))
            : past ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.secondary)
        let titleStyle: AnyShapeStyle = event.isConflict ? AnyShapeStyle(.red)
            : past ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary)
        return HStack(spacing: rowSpacing) {
            Text(event.isAllDay ? "all day" : event.start.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12))
                .foregroundStyle(timeStyle)
                .frame(width: timeColumnWidth, alignment: .trailing)
            ZStack {
                if event.isConflict {
                    Image(systemName: "xmark.octagon.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                } else {
                    Circle()
                        .fill(event.color.opacity(past ? 0.35 : 1))
                        .frame(width: 9, height: 9)
                }
            }
            .frame(width: dotColumnWidth)
            Text(event.title)
                .font(.system(size: 14, weight: event.isConflict ? .medium : .regular))
                .foregroundStyle(titleStyle)
                .lineLimit(1)
            Spacer()
            if !event.isAllDay {
                Text("– \(event.end.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 12))
                    .foregroundStyle(past ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.tertiary))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 5)
    }

    private var nowLine: some View {
        HStack(spacing: rowSpacing) {
            Text(Date().formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
                .frame(width: timeColumnWidth, alignment: .trailing)
            Circle()
                .fill(.red)
                .frame(width: 7, height: 7)
                .frame(width: dotColumnWidth)
            Rectangle()
                .fill(.red.opacity(0.7))
                .frame(height: 1.5)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 3)
    }

    /// The event being typed, ghosted into its chronological slot.
    private func previewRow(allDay: Bool) -> some View {
        HStack(spacing: rowSpacing) {
            Text(allDay ? "all day" : (model.parsed.start?.formatted(date: .omitted, time: .shortened) ?? ""))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: timeColumnWidth, alignment: .trailing)
            Circle()
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .frame(width: 9, height: 9)
                .frame(width: dotColumnWidth)
            Text(model.parsed.title.isEmpty ? "New event" : model.parsed.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
            Spacer()
            if !allDay, model.parsed.hasExplicitEnd || model.parsed.hasExplicitTime,
               let end = model.parsed.end {
                Text("– \(end.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor.opacity(0.7))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.07), in: .rect(cornerRadius: 8))
    }

    private func conflictRow(_ event: ContextEvent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
            Text("Conflicts with \(event.title)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.red)
                .lineLimit(1)
            Spacer()
            Text("\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 12))
                .foregroundStyle(.red.opacity(0.8))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            calendarIndex
            Spacer(minLength: 16)
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

    /// ⌘-slot index — one row up to 6 calendars, two aligned rows beyond that.
    /// Assignments are configurable in Settings.
    private var calendarIndex: some View {
        let slots = model.slotCalendars
        let firstRow = Array(slots.prefix(6))
        let secondRow = Array(slots.dropFirst(6))
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            GridRow {
                ForEach(firstRow) { calendarIndexItem($0) }
            }
            if !secondRow.isEmpty {
                GridRow {
                    ForEach(secondRow) { calendarIndexItem($0) }
                }
            }
        }
    }

    private func calendarIndexItem(_ slot: SlotCalendar) -> some View {
        let isTarget = model.target?.id == slot.info.id
        return HStack(spacing: 6) {
            Text("⌘\(slot.number)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isTarget ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            Text(slot.info.name)
                .font(.system(size: 13, weight: isTarget ? .medium : .regular))
                .foregroundStyle(isTarget ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            isTarget ? AnyShapeStyle(.quaternary.opacity(0.7)) : AnyShapeStyle(.clear),
            in: .capsule
        )
        .contentShape(.rect)
        .onTapGesture { model.pickCalendar(id: slot.info.id) }
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
