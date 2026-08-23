import SwiftUI

struct PanelView: View {
    @ObservedObject var model: InputModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputRow
            if !model.text.isEmpty {
                detailRow
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
                    Text("New event — try “coffee with sam 2pm”")
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
            Chip(icon: "calendar", text: model.parsed.dayOffset == 1 ? "Tomorrow" : "Today")
            Chip(icon: "clock", text: timeText)
            Chip(icon: "circle.inset.filled", text: model.calendarName, tint: .secondary)
        }
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

    private var timeText: String {
        guard let start = model.parsed.start else { return "" }
        let time = start.formatted(date: .omitted, time: .shortened)
        return model.parsed.hasExplicitTime ? time : "\(time)?"
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
