import SwiftUI

struct MonthCalendarHeatmap: View {
    let days: [MonthlyInsights.Day]
    let onSelect: (Date) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)
    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityIdentifier("month-calendar-weekdays")

            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(MonthlyInsights.calendarCells(days: days, calendar: calendar)) { cell in
                    if let day = cell.day {
                        MonthCalendarDayCell(day: day, fill: fill(for: day), label: label(for: day)) {
                            onSelect(day.date)
                        }
                    } else {
                        Color.clear
                            .frame(height: 32)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Monthly calendar")
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let offset = max(0, calendar.firstWeekday - 1)
        return Array(symbols[offset...] + symbols[..<offset])
    }

    private func fill(for day: MonthlyInsights.Day) -> Color {
        guard let category = day.dominantCategory else { return .secondary.opacity(0.12) }
        let intensity = max(0.28, min(1, day.awayFraction * 0.55 + day.hours / 24 * 0.45))
        return insightColor(for: category).opacity(intensity)
    }

    private func label(for day: MonthlyInsights.Day) -> String {
        let date = day.date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        guard let category = day.dominantCategory else { return "\(date), no recorded activity" }
        let pattern: String
        if category == "Home" {
            pattern = "mostly Home"
        } else if day.awayFraction >= 0.65 {
            pattern = "high away-from-home time, mostly \(category)"
        } else {
            pattern = "activity-dominant, mostly \(category)"
        }
        return "\(date), \(pattern), \(formatHours(day.hours)) recorded"
    }
}

private struct MonthCalendarDayCell: View {
    let day: MonthlyInsights.Day
    let fill: Color
    let label: String
    let onSelect: () -> Void

    private var isHighAwayDay: Bool {
        day.dominantCategory != "Home" && day.awayFraction >= 0.65
    }

    var body: some View {
        Button(action: onSelect) {
            RoundedRectangle(cornerRadius: 5)
                .fill(fill)
                .frame(height: 32)
                .overlay {
                    Text(day.date.formatted(.dateTime.day()))
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(day.hours > 0 ? .white : .secondary)
                        .minimumScaleFactor(0.75)
                }
                .overlay {
                    if isHighAwayDay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(.primary.opacity(0.45), lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint("Opens Day Insights")
    }
}
