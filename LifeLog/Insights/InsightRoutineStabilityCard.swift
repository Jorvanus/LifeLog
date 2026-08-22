import SwiftUI

/// Weekday Home/Work arrival-departure ranges, sleep timing regularity, and
/// commute stability, over the season `InsightsRoutineStability` computed. Shown
/// beside Recording Quality: both are read-only observations about the archive
/// rather than a correction path, so this card has no drill-down of its own.
///
/// Leads with plain-language takeaways and a visual range strip per weekday
/// rather than a wall of "arrives HH:MM (±NNN min)" rows -- the exact numbers
/// are still here, just behind a disclosure, for the minority who want them.
struct InsightRoutineStabilityCard: View {
    let routine: InsightsRoutineStability.Presentation
    @State private var isShowingExactTimes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your routine").font(.headline)
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
                VStack(alignment: .leading, spacing: 10) {
                    if let text = headline(title: "Home", rows: routine.homeWeekdays) {
                        statRow(icon: "house.fill", title: "Home", detail: text)
                    }
                    if let text = headline(title: "Work", rows: routine.workWeekdays) {
                        statRow(icon: "briefcase.fill", title: "Work", detail: text)
                    }
                    if let sleep = routine.sleep {
                        statRow(icon: "moon.fill", title: "Sleep", detail: sleepHeadline(sleep))
                    }
                    if let commute = routine.commute {
                        statRow(icon: "car.fill", title: "Commute", detail: commuteHeadline(commute))
                    }
                }

                if !routine.homeWeekdays.isEmpty || !routine.workWeekdays.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        if !routine.homeWeekdays.isEmpty {
                            weekdayRangeStrip(title: "Home", category: "Home", rows: routine.homeWeekdays)
                        }
                        if !routine.workWeekdays.isEmpty {
                            weekdayRangeStrip(title: "Work", category: "Work", rows: routine.workWeekdays)
                        }
                        rangeAxisTicks
                    }
                }

                DisclosureGroup("Exact times", isExpanded: $isShowingExactTimes) {
                    VStack(alignment: .leading, spacing: 12) {
                        if !routine.homeWeekdays.isEmpty {
                            weekdaySection(title: "Home", icon: "house.fill", rows: routine.homeWeekdays)
                        }
                        if !routine.workWeekdays.isEmpty {
                            weekdaySection(title: "Work", icon: "briefcase.fill", rows: routine.workWeekdays)
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline.weight(.semibold))
                .tint(.secondary)
            }
        }
        .padding(20)
        .lifeCard()
        .accessibilityIdentifier("insight-routine-stability-card")
    }

    private var sampleWindowText: String {
        "\(routine.sampleWindow.start.formatted(date: .abbreviated, time: .omitted)) – \(routine.sampleWindow.end.formatted(date: .abbreviated, time: .omitted)) · \(Int((routine.coverage * 100).rounded()))% coverage"
    }

    // MARK: - Plain-language takeaways

    /// The steadiest weekday for this role, in a sentence: which day, when, and
    /// (only when it's actually informative) how much even that steadiest day
    /// still wanders. With only one qualifying day there's nothing to contrast,
    /// so it's stated plainly instead of framed as "most consistent."
    private func headline(title: String, rows: [InsightsRoutineStability.WeekdayRoutine]) -> String? {
        let withArrival = rows.compactMap { row in row.arrival.map { (row, $0) } }
        guard let best = withArrival.min(by: { $0.1.spreadMinutes < $1.1.spreadMinutes }) else { return nil }
        let day = weekdayName(best.0.weekday)
        let time = timeString(best.1.medianMinutes)
        if withArrival.count == 1 {
            return "\(day)s, usually \(title == "Home" ? "home" : "in") by \(time)."
        }
        let verb = title == "Home" ? "home" : "in"
        if best.1.spreadMinutes < 20 {
            return "Steadiest on \(day)s — \(verb) by \(time), rarely more than \(spreadPhrase(best.1.spreadMinutes)) off."
        }
        return "\(day)s are the steadiest \(title.lowercased()) day, usually \(verb) by \(time), though timing still varies by about \(spreadPhrase(best.1.spreadMinutes))."
    }

    private func sleepHeadline(_ sleep: InsightsRoutineStability.SleepStat) -> String {
        "Usually asleep by \(timeString(sleep.start.medianMinutes)), waking around \(timeString(sleep.end.medianMinutes)). Bedtime varies by about \(spreadPhrase(sleep.start.spreadMinutes))."
    }

    private func commuteHeadline(_ commute: InsightsRoutineStability.DurationStat) -> String {
        "Usually \(durationString(commute.medianMinutes)), varying by about \(durationString(commute.spreadMinutes)), from \(commute.sampleCount) days."
    }

    /// "give or take 25 minutes" reads more like something a person would say
    /// than "±25 min" -- the underlying number is unchanged, only the framing.
    private func spreadPhrase(_ minutes: Double) -> String {
        minutes < 1 ? "a minute" : durationString(minutes)
    }

    // MARK: - Visual range strip

    /// One horizontal strip per weekday: a bar from typical arrival to typical
    /// departure on a shared midnight-to-midnight axis, so the *shape* of the
    /// week -- which days run long, which are brief, which overlap -- reads at
    /// a glance instead of requiring the reader to mentally lay out seven rows
    /// of times themselves. An overnight stay (arrival before midnight,
    /// departure after) draws as two pieces, one against each edge.
    private func weekdayRangeStrip(title: String, category: String, rows: [InsightsRoutineStability.WeekdayRoutine]) -> some View {
        let color = categoryColor(forCategory: category)
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows) { row in
                    GeometryReader { proxy in
                        HStack(spacing: 8) {
                            Text(weekdayName(row.weekday))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .leading)
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.12))
                                let trackWidth = max(proxy.size.width - 32, 1)
                                ForEach(Array(barSegments(row).enumerated()), id: \.offset) { _, segment in
                                    Capsule()
                                        .fill(color)
                                        .frame(width: max(trackWidth * CGFloat(segment.end - segment.start) / 1_440, 3))
                                        .offset(x: trackWidth * CGFloat(segment.start) / 1_440)
                                }
                            }
                            .frame(height: 10)
                        }
                    }
                    .frame(height: 16)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(title) on \(weekdayName(row.weekday)): \(weekdayRangeText(row))")
                }
            }
        }
    }

    /// Where a bar segment starts is not necessarily where it visually starts on
    /// screen: an overnight stay's departure is numerically *before* its arrival
    /// (8:14am is less than 1:42pm), which without this would draw backwards.
    /// Split into an arrival→midnight piece and a midnight→departure piece
    /// instead. A role with only one of arrival/departure gets a short marker at
    /// that single point rather than spanning the whole day.
    private func barSegments(_ row: InsightsRoutineStability.WeekdayRoutine) -> [(start: Double, end: Double)] {
        switch (row.arrival?.medianMinutes, row.departure?.medianMinutes) {
        case let (.some(arrival), .some(departure)) where departure >= arrival:
            return [(arrival, departure)]
        case let (.some(arrival), .some(departure)):
            return [(arrival, 1_440), (0, departure)]
        case let (.some(arrival), nil):
            return [(arrival, min(arrival + 12, 1_440))]
        case let (nil, .some(departure)):
            return [(max(departure - 12, 0), departure)]
        case (nil, nil):
            return []
        }
    }

    private var rangeAxisTicks: some View {
        GeometryReader { proxy in
            let trackWidth = max(proxy.size.width - 32, 1)
            ForEach([0, 6, 12, 18], id: \.self) { hour in
                Text(hourLabel(hour))
                    .font(.caption2).foregroundStyle(.tertiary)
                    .position(x: 32 + trackWidth * CGFloat(hour) / 24, y: 8)
            }
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }

    private func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: "12am"
        case 12: "12pm"
        case let hour where hour < 12: "\(hour)am"
        default: "\(hour - 12)pm"
        }
    }

    // MARK: - Exact times (disclosed)

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
