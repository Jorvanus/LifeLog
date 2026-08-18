import SwiftUI

/// The seven-day mini-calendar: one compact, chronological bar per day of the
/// viewed week, so a quiet or unlogged day still draws something (mostly the
/// same muted gray `DayTimelineBar` uses for a gap) instead of disappearing
/// from the row entirely. Each day's `segments` are the same post-resolution
/// `InsightSegment`s the day bar and donut are built from — see
/// `InsightsView.weekDays` — so a column can never disagree with what opening
/// that day in Day Insights would show.
struct WeeklyStrip: View {
    struct Day: Identifiable {
        let date: Date
        let segments: [InsightSegment]
        var id: Date { date }
    }

    let days: [Day]
    let today: Date
    let selectedDate: Date?
    let onSelectDay: (Date) -> Void
    /// Timeline uses the strip as a one-tap date control. Insights keeps the
    /// original two-step selection so a person can inspect a week's total first.
    var selectsImmediately: Bool = false
    var compact: Bool = false
    @State private var selectedDay: Date?

    var body: some View {
        HStack(alignment: .bottom, spacing: compact ? 4 : 8) {
            ForEach(days) { day in
                Button {
                    if selectsImmediately {
                        onSelectDay(day.date)
                    } else {
                        selectedDay = selectedDay == day.date ? nil : day.date
                    }
                } label: {
                    VStack(spacing: 6) {
                        column(for: day)
                        VStack(spacing: 1) {
                            Text(day.date.formatted(.dateTime.weekday(.narrow)))
                                .font(.caption2.weight(.bold))
                            Text(day.date.formatted(.dateTime.day()))
                                .font(.caption2)
                        }
                        .foregroundStyle(isToday(day) ? Color.primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel(for: day))
                .accessibilityHint(selectsImmediately
                                   ? "Opens this day in Timeline"
                                   : "Selects this day; use the selected-day action to open Day Insights")
            }
        }
        if !compact, let selectedDay, let day = days.first(where: { Calendar.current.isDate($0.date, inSameDayAs: selectedDay) }) {
            Button { onSelectDay(day.date) } label: {
                HStack {
                    Label(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day()), systemImage: "calendar")
                    Spacer()
                    Text(formatHours(day.segments.reduce(0) { $0 + $1.hours }))
                        .font(.subheadline.bold().monospacedDigit())
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
            .accessibilityLabel("Open \(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day())) details, \(formatHours(day.segments.reduce(0) { $0 + $1.hours }))")
            .accessibilityIdentifier("weekly-selected-day")
        }
    }

    private func isToday(_ day: Day) -> Bool {
        Calendar.current.isDate(day.date, inSameDayAs: today)
    }

    private func isSelected(_ day: Day) -> Bool {
        if let selectedDay {
            return Calendar.current.isDate(day.date, inSameDayAs: selectedDay)
        }
        guard let selectedDate else { return false }
        return Calendar.current.isDate(day.date, inSameDayAs: selectedDate)
    }

    /// Segments stacked top (midnight) to bottom (end of day), proportional to
    /// the fraction of the day they cover — the same chronological reading a
    /// horizontal day bar gives, just rotated to fit seven of them in a row.
    private func column(for day: Day) -> some View {
        GeometryReader { proxy in
            let totalHours = max(day.segments.reduce(0) { $0 + $1.hours }, 0.01)
            let gaps = CGFloat(max(day.segments.count - 1, 0))
            let available = max(proxy.size.height - gaps, 1)
            VStack(spacing: 1) {
                ForEach(day.segments) { segment in
                    Rectangle()
                        .fill(segment.isUnlogged ? Color.secondary.opacity(0.15) : segment.color)
                        .frame(height: available * segment.hours / totalHours)
                }
            }
        }
        .frame(width: compact ? 22 : 28, height: compact ? 44 : 64)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isSelected(day) ? Color.primary : (isToday(day) ? Color.primary.opacity(0.45) : .clear),
                        lineWidth: isSelected(day) ? 2.5 : 1.5)
        )
        .background(isToday(day) ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
    }

    private func accessibilityLabel(for day: Day) -> String {
        let logged = day.segments.filter { !$0.isUnlogged }.reduce(0) { $0 + $1.hours }
        let dateText = day.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let state = logged > 0.01 ? "\(formatHours(logged)) logged" : "nothing logged"
        let marker = isSelected(day) ? ", selected" : (isToday(day) ? ", today" : "")
        return "\(dateText), \(state)\(marker)"
    }
}
