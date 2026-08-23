import SwiftUI

struct PanelView: View {
    @ObservedObject var model: InputModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputRow
            if !model.text.isEmpty {
                detailRow
            }
            if !model.context.isEmpty, model.status == .idle {
                contextList
            }
        }
        .frame(width: 640, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        // Transparent margin so the glass material's soft shadow can fade out
        // instead of clipping in a hard rectangle at the window edge.
        .padding(40)
    }

    private var inputRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                if model.text.isEmpty {
                    Text("New event — try “lunch 12-1 tom >work”")
                        .font(.system(size: 22))
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
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var detailRow: some View {
        HStack(spacing: 8) {
            chips
            Spacer()
            trailing
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
        .transition(.opacity)
    }

    @ViewBuilder
    private var chips: some View {
        switch model.status {
        case .saved(let calendar):
            Label("Added to \(calendar)", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.green)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.red)
                .lineLimit(1)
        default:
            Chip(icon: "calendar", text: dayText)
            Chip(icon: "clock", text: timeText)
            if let recurrence = model.parsed.recurrence {
                Chip(icon: "repeat", text: recurrence.label)
            }
            calendarChip
        }
    }

    @ViewBuilder
    private var calendarChip: some View {
        if model.queryUnmatched, let query = model.parsed.calendarQuery {
            Chip(icon: "questionmark.circle", text: query, tint: .orange)
        } else if let target = model.target {
            HStack(spacing: 5) {
                Circle()
                    .fill(target.color)
                    .frame(width: 8, height: 8)
                Text(target.name)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: .capsule)
        }
    }

    private var contextList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.context) { event in
                HStack(spacing: 8) {
                    if event.isConflict {
                        Image(systemName: "xmark.octagon.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    } else {
                        Circle()
                            .fill(event.color)
                            .frame(width: 6, height: 6)
                    }
                    Text(event.isConflict ? "Conflicts with \(event.title)" : event.title)
                        .font(.system(size: 12, weight: event.isConflict ? .medium : .regular))
                        .foregroundStyle(event.isConflict ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                    Spacer()
                    Text(rangeText(event.start, event.end))
                        .font(.system(size: 11))
                        .foregroundStyle(event.isConflict ? AnyShapeStyle(.red.opacity(0.8)) : AnyShapeStyle(.tertiary))
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .transition(.opacity)
    }

    @ViewBuilder
    private var trailing: some View {
        if model.status == .saving {
            ProgressView()
                .controlSize(.small)
        } else if case .saved = model.status {
            EmptyView()
        } else {
            HStack(spacing: 4) {
                Text("↩")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .rect(cornerRadius: 5))
                Text("Add")
                    .font(.system(size: 12))
            }
            .foregroundStyle(model.canSubmit ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
        }
    }

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
        return model.parsed.hasExplicitTime ? from : "\(from)?"
    }

    private func rangeText(_ start: Date, _ end: Date) -> String {
        "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }
}

private struct Chip: View {
    let icon: String
    let text: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.12), in: .capsule)
    }
}
