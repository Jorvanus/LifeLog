import SwiftUI

/// Weekday Home/Work arrival-departure ranges, sleep timing regularity, and
/// commute stability, over the season `InsightsRoutineStability` computed. Shown
/// beside Recording Quality: both are read-only observations about the archive
/// rather than a correction path, so this card has no drill-down of its own.
struct InsightRoutineStabilityCard: View {
    let routine: InsightsRoutineStability.Presentation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Routine stability").font(.headline)
                Text("Sample: \(sampleWindowText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)

            if !routine.hasEnoughCoverage {
                InsightEmptyRow(icon: "clock.badge.questionmark", title: "Not enough recorded time yet",
                                detail: "This needs more consistently logged days over the season before a routine can be described with any confidence.")
            } else if !routine.hasAnyConclusion {
                InsightEmptyRow(icon: "calendar.badge.clock", title: "Not enough distinct days yet",
                                detail: "Home, Work, sleep, and commute each need several separate days before a pattern is worth naming.")
            } else {
                if !routine.homeWeekdays.isEmpty {
                    weekdaySection(title: "Home", icon: "house.fill", rows: routine.homeWeekdays)
                }
                if !routine.workWeekdays.isEmpty {
                    weekdaySection(title: "Work", icon: "briefcase.fill", rows: routine.workWeekdays)
                }
                if let sleep = routine.sleep {
                    statRow(icon: "moon.fill", title: "Sleep",
                           detail: "Usually asleep by \(timeString(sleep.start.medianMinutes)) (±\(spreadString(sleep.start.spreadMinutes))), wakes around \(timeString(sleep.end.medianMinutes)) (±\(spreadString(sleep.end.spreadMinutes)))")
                }
                if let commute = routine.commute {
                    statRow(icon: "car.fill", title: "Commute",
                           detail: "Usually \(durationString(commute.medianMinutes)) (±\(durationString(commute.spreadMinutes))), from \(commute.sampleCount) days")
                }
            }
        }
        .padding(20)
        .lifeCard()
        .accessibilityIdentifier("insight-routine-stability-card")
    }

    private var sampleWindowText: String {
        "\(routine.sampleWindow.start.formatted(date: .abbreviated, time: .omitted)) – \(routine.sampleWindow.end.formatted(date: .abbreviated, time: .omitted)) · \(Int((routine.coverage * 100).rounded()))% coverage"
    }

    private func weekdaySection(title: String, icon: String, rows: [InsightsRoutineStability.WeekdayRoutine]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(weekdayName(row.weekday)).font(.subheadline).frame(width: 44, alignment: .leading)
                    Spacer()
                    Text(weekdayRangeText(row))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(title) on \(weekdayName(row.weekday)): \(weekdayRangeText(row))")
            }
        }
    }

    private func weekdayRangeText(_ row: InsightsRoutineStability.WeekdayRoutine) -> String {
        let arrival = row.arrival.map { "arrives \(timeString($0.medianMinutes)) (±\(spreadString($0.spreadMinutes)))" }
        let departure = row.departure.map { "leaves \(timeString($0.medianMinutes)) (±\(spreadString($0.spreadMinutes)))" }
        return [arrival, departure].compactMap { $0 }.joined(separator: ", ")
    }

    private func statRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.subheadline).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(detail)")
    }

    private func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        return symbols[(weekday - 1) % 7]
    }

    private func timeString(_ minutesSinceMidnight: Double) -> String {
        let base = Calendar.current.startOfDay(for: .now)
        let date = base.addingTimeInterval(minutesSinceMidnight * 60)
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func spreadString(_ minutes: Double) -> String {
        minutes < 1 ? "<1 min" : "\(Int(minutes.rounded())) min"
    }

    private func durationString(_ minutes: Double) -> String {
        let rounded = Int(minutes.rounded())
        if rounded < 60 { return "\(rounded) min" }
        return "\(rounded / 60)h \(rounded % 60)m"
    }
}
