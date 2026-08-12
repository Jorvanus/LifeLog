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
    let onSelectDay: (Date) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(days) { day in
                Button { onSelectDay(day.date) } label: {
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
                .accessibilityHint("Opens this day in Day Insights")
            }
        }
    }

    private func isToday(_ day: Day) -> Bool {
        Calendar.current.isDate(day.date, inSameDayAs: today)
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
        .frame(width: 28, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isToday(day) ? Color.primary.opacity(0.4) : .clear, lineWidth: 1.5)
        )
    }

    private func accessibilityLabel(for day: Day) -> String {
        let logged = day.segments.filter { !$0.isUnlogged }.reduce(0) { $0 + $1.hours }
        let dateText = day.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return logged > 0.01 ? "\(dateText), \(formatHours(logged)) logged" : "\(dateText), nothing logged"
    }
}
