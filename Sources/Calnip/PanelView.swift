import SwiftUI

struct PanelView: View {
    @ObservedObject var model: InputModel
    @AppStorage(Settings.viewModeKey) private var viewMode = "expanded"
    @Environment(\.colorScheme) private var colorScheme

    private var expanded: Bool { viewMode == "expanded" }
    private var typing: Bool { !model.text.isEmpty }

    // Day-grid metrics.
    private let hourHeight: CGFloat = 22
    /// Total height a collapsed run of empty hours squeezes into.
    private let collapsedRunHeight: CGFloat = 26
    private let gutterWidth: CGFloat = 66
    private let gridTrailingInset: CGFloat = 20
    private let maxTimelineHeight: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputRow
            if expanded {
                expandedContent
            } else if typing {
                chipsRow
                    .padding(.horizontal, 22)
                    .padding(.bottom, 14)
                let conflicts = model.timeline.rows.filter(\.isConflict)
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
            // Always shown — empty input already means "all-day today", so the
            // panel opens in its full layout and nothing jumps on first keypress.
            chipsRow
                .padding(.horizontal, 24)
            timelineSection
        }
        .padding(.vertical, 14)
        divider
        footer
    }

    // Hairlines and fills need real contrast on the light glass; the dark
    // values would be glaring in light mode and vice versa.
    private var hairline: AnyShapeStyle {
        colorScheme == .light ? AnyShapeStyle(Color.black.opacity(0.15))
                              : AnyShapeStyle(.quaternary.opacity(0.5))
    }
    private var gridLine: AnyShapeStyle {
        colorScheme == .light ? AnyShapeStyle(Color.black.opacity(0.1))
                              : AnyShapeStyle(.quaternary.opacity(0.35))
    }
    private var blockFill: Double { colorScheme == .light ? 0.28 : 0.18 }
    private var ghostFill: Double { colorScheme == .light ? 0.22 : 0.14 }

    private var divider: some View {
        Rectangle()
            .fill(hairline)
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
                let conflicts = model.timeline.rows.filter(\.isConflict)
                if typing, let first = conflicts.first {
                    Chip(icon: "xmark.octagon.fill",
                         text: "Conflicts with \(first.title)"
                            + (conflicts.count > 1 ? " +\(conflicts.count - 1)" : ""),
                         tint: .red)
                }
            }
            Spacer()
            if model.status == .saving {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Day grid

    /// Column assignment for overlapping events, Calendar-app style.
    private struct Placed: Identifiable {
        let event: ContextEvent
        var column = 0
        var columns = 1
        var id: String { event.id }
    }

    private static func layoutColumns(_ events: [ContextEvent]) -> [Placed] {
        var placed: [Placed] = []
        var active: [(end: Date, column: Int)] = []
        var clusterStart = 0
        var clusterMaxColumn = 0
        for event in events.sorted(by: { $0.start < $1.start }) {
            active.removeAll { $0.end <= event.start }
            if active.isEmpty, !placed.isEmpty {
                for index in clusterStart..<placed.count { placed[index].columns = clusterMaxColumn + 1 }
                clusterStart = placed.count
                clusterMaxColumn = 0
            }
            let used = Set(active.map(\.column))
            var column = 0
            while used.contains(column) { column += 1 }
            clusterMaxColumn = max(clusterMaxColumn, column)
            active.append((event.end, column))
            placed.append(Placed(event: event, column: column))
        }
        for index in clusterStart..<placed.count { placed[index].columns = clusterMaxColumn + 1 }
        return placed
    }

    private var timelineSection: some View {
        let day = model.timeline.day
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(day)
        let dayStart = calendar.startOfDay(for: day)
        let previewOnDay = typing && model.status == .idle
            && model.parsed.start.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let timedPreview = previewOnDay && !model.parsed.isAllDay

        let allDay = model.timeline.rows.filter(\.isAllDay)
        let timed = model.timeline.rows.filter { !$0.isAllDay }

        // Full 12 AM – 11:59 PM day. Hours near events / the now line / the
        // typed preview (±1h) get full height; blank stretches compress.
        var active = Set<Int>()
        func mark(_ start: Date, _ end: Date) {
            let from = max(Int(start.timeIntervalSince(dayStart) / 3600) - 1, 0)
            let to = min(Int(ceil(end.timeIntervalSince(dayStart) / 3600)) + 1, 24)
            guard from < 24 else { return }
            for hour in from..<max(to, from + 1) { active.insert(hour) }
        }
        for event in timed { mark(event.start, min(event.end, dayStart.addingTimeInterval(86400))) }
        if timedPreview, let start = model.parsed.start, let end = model.parsed.end {
            mark(start, min(end, dayStart.addingTimeInterval(86400)))
        }
        if isToday { mark(Date(), Date()) }
        if active.isEmpty { for hour in 8..<19 { active.insert(hour) } }

        // Uniform hour height; only long empty runs (4h+) collapse, each into
        // one small uniform band — no per-hour height wobble.
        var heights = [CGFloat](repeating: hourHeight, count: 24)
        var cursor = 0
        while cursor < 24 {
            guard !active.contains(cursor) else { cursor += 1; continue }
            var runEnd = cursor
            while runEnd < 24, !active.contains(runEnd) { runEnd += 1 }
            let length = runEnd - cursor
            if length >= 4 {
                let per = collapsedRunHeight / CGFloat(length)
                for hour in cursor..<runEnd { heights[hour] = per }
            }
            cursor = runEnd
        }
        var accumulated: [CGFloat] = [0]
        for height in heights { accumulated.append(accumulated.last! + height) }
        let totalHeight = accumulated[24]
        // Labels/lines everywhere except inside collapsed bands.
        let labeledHours = (0...24).filter { hour in
            hour == 0 || hour == 24
                || heights[hour] == hourHeight
                || heights[hour - 1] == hourHeight
        }

        func yOffset(_ date: Date) -> CGFloat {
            let t = min(max(date.timeIntervalSince(dayStart) / 3600, 0), 24)
            let whole = min(Int(t), 23)
            return accumulated[whole] + CGFloat(t - Double(whole)) * heights[whole]
        }

        let placed = Self.layoutColumns(timed)
        let now = Date()

        return VStack(alignment: .leading, spacing: 6) {
            timelineHeader(day: day, isToday: isToday)
            if !allDay.isEmpty || (previewOnDay && model.parsed.isAllDay) {
                allDayRow(allDay, showPreview: previewOnDay && model.parsed.isAllDay)
            }
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        // Scroll rail — real layout, so scrollTo has stable targets.
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { hour in
                                Color.clear
                                    .frame(height: heights[hour])
                                    .id("hour-\(hour)")
                            }
                        }
                        gridCanvas(labeledHours: labeledHours, accumulated: accumulated,
                                   yOffset: yOffset, placed: placed, timedPreview: timedPreview,
                                   nowVisible: isToday, now: now, isToday: isToday)
                    }
                    .frame(height: totalHeight)
                    .padding(.top, 8)
                    .padding(.bottom, 16)   // last label clear of the footer
                }
                .frame(height: min(totalHeight + 24, maxTimelineHeight))
                .onAppear {
                    scrollToFocus(proxy, isToday: isToday, now: now)
                }
                .onReceive(NotificationCenter.default.publisher(for: .calnipPanelDidShow)) { _ in
                    // Re-center on the current time each open; second pass once
                    // the freshly fetched timeline has settled the geometry.
                    scrollToFocus(proxy, isToday: isToday, now: Date())
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        scrollToFocus(proxy, isToday: isToday, now: Date())
                    }
                }
                .onChange(of: model.timeline.day) { _, _ in
                    scrollToFocus(proxy, isToday: isToday, now: now)
                }
                .onChange(of: model.focusDate) { _, focus in
                    guard let focus else { return }
                    let hour = Calendar.current.component(.hour, from: focus)
                    scrollToHour(proxy, hour)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        scrollToHour(proxy, hour)
                    }
                }
                .onChange(of: model.selectedEventID) { _, id in
                    guard let id, let event = model.timeline.rows.first(where: { $0.id == id }),
                          !event.isAllDay else { return }
                    scrollToHour(proxy, Calendar.current.component(.hour, from: event.start))
                }
                .onChange(of: timedPreview ? model.parsed.start : nil) { _, start in
                    guard let start else { return }
                    scrollToHour(proxy, Calendar.current.component(.hour, from: start))
                }
            }
        }
    }

    private func scrollToFocus(_ proxy: ScrollViewProxy, isToday: Bool, now: Date) {
        if let focus = model.focusDate,
           Calendar.current.isDate(focus, inSameDayAs: model.timeline.day) {
            scrollToHour(proxy, Calendar.current.component(.hour, from: focus), animated: false)
            return
        }
        let hour = isToday ? Calendar.current.component(.hour, from: now) : 9
        scrollToHour(proxy, hour, animated: false)
    }

    private func scrollToHour(_ proxy: ScrollViewProxy, _ hour: Int, animated: Bool = true) {
        let target = max(0, min(hour, 23))
        if animated {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("hour-\(target)", anchor: .center) }
        } else {
            proxy.scrollTo("hour-\(target)", anchor: .center)
        }
    }

    private func gridCanvas(labeledHours: [Int], accumulated: [CGFloat],
                            yOffset: @escaping (Date) -> CGFloat,
                            placed: [Placed], timedPreview: Bool,
                            nowVisible: Bool, now: Date, isToday: Bool) -> some View {
        GeometryReader { geo in
            let contentX = gutterWidth + 8
            let contentWidth = geo.size.width - contentX - gridTrailingInset
            ZStack(alignment: .topLeading) {
                // Hour lines + right-aligned gutter labels.
                ForEach(labeledHours, id: \.self) { hour in
                    let y = accumulated[hour]
                    Rectangle()
                        .fill(gridLine)
                        .frame(height: colorScheme == .light ? 1 : 0.5)
                        .padding(.leading, gutterWidth)
                        .offset(y: y)
                    Text(hourLabel(hour))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(colorScheme == .light ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                        .frame(width: gutterWidth - 14, alignment: .trailing)
                        .offset(y: y - 6)
                }

                // Event blocks.
                ForEach(placed) { item in
                    let width = (contentWidth / CGFloat(item.columns))
                    let x = contentX + width * CGFloat(item.column)
                    let y = max(yOffset(item.event.start), 0)
                    let height = max(yOffset(item.event.end) - y, 16)
                    if model.editingEvent?.id == item.event.id {
                        editBlock
                            .frame(width: contentWidth, height: max(height, 36))
                            .offset(x: contentX, y: y)
                            .zIndex(3)
                    } else {
                        eventBlock(item.event, height: height, isToday: isToday)
                            .frame(width: width - 4, height: height)
                            .offset(x: x, y: y)
                            .zIndex(model.selectedEventID == item.event.id ? 2 : 1)
                    }
                }

                // Ghost of the entry being typed.
                if timedPreview, let start = model.parsed.start, let end = model.parsed.end {
                    let y = max(yOffset(start), 0)
                    let height = max(yOffset(min(end, start.addingTimeInterval(86400))) - y, 16)
                    previewBlock(height: height)
                        .frame(width: contentWidth - 4, height: height)
                        .offset(x: contentX, y: y)
                        .zIndex(5)   // the entry being typed always wins overlaps
                }

                // Now line.
                if nowVisible {
                    HStack(spacing: 0) {
                        Circle()
                            .fill(.red.opacity(0.85))
                            .frame(width: 6, height: 6)
                        Rectangle()
                            .fill(.red.opacity(0.5))
                            .frame(height: 1)
                    }
                    .padding(.leading, gutterWidth - 3)
                    .offset(y: yOffset(now) - 3)
                    .zIndex(4)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0, 24: return "12 AM"
        case 12: return "Noon"
        case 1...11: return "\(hour) AM"
        default: return "\(hour - 12) PM"
        }
    }

    private func eventBlock(_ event: ContextEvent, height: CGFloat, isToday: Bool) -> some View {
        let past = isToday && event.end < Date()
        let selected = model.selectedEventID == event.id
        let compact = height < 30
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7)
                .fill(event.color.opacity(blockFill))
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(event.color)
                    .frame(width: 3)
                    .padding(.vertical, 2)
                if compact {
                    HStack(spacing: 6) {
                        Text(event.title)
                            .font(.system(size: 11, weight: .semibold))
                        Text(rangeLabel(event.start, event.end))
                            .font(.system(size: 10))
                            .opacity(0.8)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 7)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.system(size: 9))
                            Text(rangeLabel(event.start, event.end))
                                .font(.system(size: 10.5))
                        }
                        .opacity(0.85)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 7)
                    .padding(.top, 3)
                }
            }
            .foregroundStyle(readable(event.color))
        }
        .overlay {
            // Conflicts stay unstyled here — the overlapping ghost makes the
            // collision obvious; the existing event shouldn't light up.
            if selected {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(.primary.opacity(0.65), lineWidth: 1.5)
            }
        }
        .opacity(past ? 0.45 : 1)
        .contentShape(.rect)
        .onTapGesture { model.selectEvent(id: event.id) }
        .help(event.isConflict ? "Conflicts with what you're typing" : "")
    }

    private func previewBlock(height: CGFloat) -> some View {
        let compact = height < 30
        let tint = model.target?.color ?? Color.accentColor
        return ZStack(alignment: .topLeading) {
            // Opaque backing so overlapped blocks can't bleed through the ghost.
            RoundedRectangle(cornerRadius: 7)
                .fill(.thickMaterial)
            RoundedRectangle(cornerRadius: 7)
                .fill(tint.opacity(ghostFill))
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(readable(tint).opacity(0.9),
                              style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            Group {
                if compact {
                    HStack(spacing: 6) {
                        Text(model.parsed.title.isEmpty ? "New event" : model.parsed.title)
                            .font(.system(size: 11, weight: .semibold))
                        if let start = model.parsed.start, let end = model.parsed.end {
                            Text(rangeLabel(start, end))
                                .font(.system(size: 10))
                                .opacity(0.8)
                        }
                    }
                    .padding(.horizontal, 8)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.parsed.title.isEmpty ? "New event" : model.parsed.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        if let start = model.parsed.start, let end = model.parsed.end {
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .font(.system(size: 9))
                                Text(rangeLabel(start, end))
                                    .font(.system(size: 10.5))
                            }
                            .opacity(0.85)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 3)
                }
            }
            .foregroundStyle(readable(tint))
        }
        .allowsHitTesting(false)
    }

    /// Inline NLP edit field styled like an event block (⌘E).
    private var editBlock: some View {
        let editCalendar = model.calendars.first { $0.id == model.editCalendarID }
        let tint = editCalendar?.color ?? Color.accentColor
        return ZStack(alignment: .leading) {
            // Same treatment as the new-event ghost, tinted by the target calendar.
            RoundedRectangle(cornerRadius: 7)
                .fill(.thickMaterial)
            RoundedRectangle(cornerRadius: 7)
                .fill(tint.opacity(ghostFill))
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(readable(tint).opacity(0.9),
                              style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(editCalendar?.color ?? Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 6)
                TokenField(
                    text: $model.editText,
                    fontSize: 14,
                    focusOnAppear: true,
                    respondsToPanelShow: false,
                    onSubmit: { model.commitEdit() },
                    onCancel: { model.cancelEdit() }
                )
                .frame(height: 20)
                if let editCalendar {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(editCalendar.color)
                            .frame(width: 8, height: 8)
                        Text(editCalendar.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5), in: .capsule)
                    .help("⌘1–9 to change calendar")
                }
                HStack(spacing: 5) {
                    Keycap("↩")
                    Text("save")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
        }
    }

    private func allDayRow(_ events: [ContextEvent], showPreview: Bool) -> some View {
        HStack(spacing: 6) {
            Text("all day")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: gutterWidth - 14, alignment: .trailing)
            if showPreview {
                let tint = model.target?.color ?? Color.accentColor
                Text(model.parsed.title.isEmpty ? "New event" : model.parsed.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(readable(tint))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(tint.opacity(ghostFill), in: .rect(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(readable(tint).opacity(0.8),
                                          style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    }
            }
            ForEach(events) { event in
                if model.editingEvent?.id == event.id {
                    editBlock
                        .frame(width: 260, height: 30)
                } else {
                    Text(event.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(readable(event.color))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(event.color.opacity(blockFill), in: .rect(cornerRadius: 6))
                        .overlay {
                            if model.selectedEventID == event.id {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(.primary.opacity(0.65), lineWidth: 1.5)
                            }
                        }
                        .onTapGesture { model.selectEvent(id: event.id) }
                }
            }
            Spacer()
        }
        .padding(.trailing, gridTrailingInset)
    }

    private func timelineHeader(day: Date, isToday: Bool) -> some View {
        HStack(spacing: 8) {
            Text(dayHeader(day, isToday: isToday))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
            Spacer()
            if model.selectedEventID != nil {
                HStack(spacing: 4) {
                    Keycap("↑↓")
                    Text("select")
                        .font(.system(size: 11))
                    Keycap("←")
                    Keycap("→")
                    Text("days")
                        .font(.system(size: 11))
                    Keycap("⌘E")
                    Text("edit")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.tertiary)
            } else if model.browsedDay != nil {
                HStack(spacing: 4) {
                    Keycap("←")
                    Keycap("→")
                    Text("days")
                        .font(.system(size: 11))
                    Keycap("↓")
                    Text("select")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 4) {
                    Keycap("↓")
                    Text("select")
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
            Text(rangeLabel(event.start, event.end))
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

    /// ⌘-slot index — one row up to 5 calendars, else 4 + the rest on a second
    /// aligned row. Assignments are configurable in Settings.
    private var calendarIndex: some View {
        let slots = model.slotCalendars
        let split = slots.count <= 5 ? slots.count : 4
        let firstRow = Array(slots.prefix(split))
        let secondRow = Array(slots.dropFirst(split))
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
        // While editing, the index reflects (and retargets) the edited event.
        let activeID = model.editingEvent != nil ? model.editCalendarID : model.target?.id
        let isTarget = activeID == slot.info.id
        return HStack(spacing: 6) {
            Text("⌘\(slot.number)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isTarget ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            Circle()
                .fill(slot.info.color)
                .frame(width: 7, height: 7)
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

    // MARK: - Color helpers

    /// Calendar colors are tuned for dark backgrounds; on light tints they
    /// need darkening to stay readable (what Calendar.app does).
    private func readable(_ color: Color) -> Color {
        colorScheme == .light ? color.mix(with: .black, by: 0.4) : color
    }

    // MARK: - Text helpers

    private var dayText: String {
        guard let start = model.parsed.start else { return "Today" }
        let calendar = Calendar.current
        if calendar.isDateInToday(start) { return "Today" }
        if calendar.isDateInTomorrow(start) { return "Tomorrow" }
        if calendar.isDateInYesterday(start) { return "Yesterday" }
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

    /// Calendar-app style: "12 – 1 PM", "11:30 AM – 1 PM".
    private func rangeLabel(_ start: Date, _ end: Date) -> String {
        func parts(_ date: Date) -> (hour: Int, minute: Int, pm: Bool) {
            let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
            let hour24 = comps.hour ?? 0
            var hour = hour24 % 12
            if hour == 0 { hour = 12 }
            return (hour, comps.minute ?? 0, hour24 >= 12)
        }
        let s = parts(start)
        let e = parts(end)
        func text(_ p: (hour: Int, minute: Int, pm: Bool), meridiem: Bool) -> String {
            let base = p.minute == 0 ? "\(p.hour)" : "\(p.hour):" + String(format: "%02d", p.minute)
            return meridiem ? base + (p.pm ? " PM" : " AM") : base
        }
        return "\(text(s, meridiem: s.pm != e.pm)) – \(text(e, meridiem: true))"
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
