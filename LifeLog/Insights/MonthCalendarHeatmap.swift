import SwiftUI

struct MonthCalendarHeatmap: View {
    let days: [MonthlyInsights.Day]
    let onSelect: (Date) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 7) {
            ForEach(days) { day in
                Button { onSelect(day.date) } label: {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(fill(for: day))
                        .frame(height: 32)
                        .overlay(Text(day.date.formatted(.dateTime.day())).font(.caption2.monospacedDigit()).foregroundStyle(day.hours > 0 ? .white : .secondary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(for: day))
                .accessibilityHint("Opens Day Insights")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Monthly calendar")
    }

    private func fill(for day: MonthlyInsights.Day) -> Color {
        guard let category = day.dominantCategory else { return .secondary.opacity(0.12) }
        let intensity = max(0.25, min(1, day.awayFraction * 0.55 + day.hours / 24 * 0.45))
        return insightColor(for: category).opacity(intensity)
    }

    private func label(for day: MonthlyInsights.Day) -> String {
        let date = day.date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        guard let category = day.dominantCategory else { return "\(date), no recorded activity" }
        return "\(date), mostly \(category), \(formatHours(day.hours)) recorded"
    }
}
