import SwiftUI

/// One category's hours this week against its rolling baseline, worth calling
/// out because the change passed `InsightsTrends.noticeableChange`.
struct WeekRoutineChange: Identifiable {
    let category: String
    let latest: Double
    let baseline: Double
    var id: String { category }
    var delta: Double { latest - baseline }
}

extension WeekRoutineChange {
    /// How many of the baseline's completed weeks count as "usual" — fixed
    /// rather than adaptive, so the comparison basis stated in the section
    /// subtitle is always literally true.
    static let baselineWeekCount = 8
    /// Sleep already has its own scorecard row; Home is deliberately *not*
    /// excluded here even though `InsightsTrends.habitExclusions` excludes it
    /// from the habits card — that exclusion is about presence never being
    /// news ("everyone is home every week"), but a change in *how much* time
    /// was spent at Home is exactly what this section exists to say.
    private static let exclusions: Set<String> = ["Sleep", "Unlogged", "Uncategorised"]

    /// This week's per-category hours appended to the rolling baseline and run
    /// through the exact same `InsightsTrends.series` math the trend lines
    /// already use — the same "mean of the *nonzero* earlier weeks" baseline,
    /// so one quiet holiday week can't silently drag a category's usual down
    /// without it showing up as a real change either.
    @MainActor
    static func changes(currentWeekStart: Date, currentSegments: [InsightSegment],
                        baselineTotals: [WeeklyTotals]) -> [WeekRoutineChange] {
        guard !baselineTotals.isEmpty else { return [] }
        let thisWeek = WeeklyTotals(weekStart: currentWeekStart, hours: InsightsSnapshot.categoryHours(in: currentSegments))
        let combined = Array(baselineTotals.suffix(baselineWeekCount)) + [thisWeek]
        guard combined.count > 1 else { return [] }
        let categories = Set(combined.flatMap { $0.hours.keys }).subtracting(exclusions)
        let changes = categories.compactMap { category -> WeekRoutineChange? in
            let series = InsightsTrends.series(for: category, title: category,
                                               symbol: insightSymbol(for: category), weeks: combined)
            guard series.baseline > 0 else { return nil }
            let change = abs(series.latest - series.baseline) / series.baseline
            guard change >= InsightsTrends.noticeableChange else { return nil }
            return WeekRoutineChange(category: category, latest: series.latest, baseline: series.baseline)
        }
        return Array(changes.sorted { abs($0.delta) > abs($1.delta) }.prefix(3))
    }
}

struct WeeklyYourWeekMetric: Identifiable {
    let id: String
    let icon: String
    let title: String
    let value: String
    var action: (() -> Void)?
}

/// "How did this week compare with usual" — a different question from
/// Month/Year's "what's the pattern," so a different layout, not a smaller
/// one: the seven days at a glance, a combined facts-and-balance card, what
/// actually changed against a rolling baseline (not just the single preceding
/// week), and a commute summary when there's a real one to show.
struct WeekInsightsView: View {
    let weekDays: [WeeklyStrip.Day]
    let now: Date
    let selectedDate: Date
    let yourWeekMetrics: [WeeklyYourWeekMetric]
    let groupTotals: [String: Double]
    let periodTitle: String
    let analysisInterval: DateInterval
    let segments: [InsightSegment]
    let travel: TravelInsights.Summary
    let commuteSummary: InsightsSnapshot.WeekCommuteSummary?
    let routineChanges: [WeekRoutineChange]
    let onSelectDay: (Date) -> Void

    var body: some View {
        WeeklyStripSection(days: weekDays, now: now, selectedDate: selectedDate, onSelectDay: onSelectDay)
        WeeklyYourWeekCard(metrics: yourWeekMetrics, groupTotals: groupTotals, periodTitle: periodTitle,
                           interval: analysisInterval, segments: segments)
            .accessibilityIdentifier("insights-week-your-week")
        if travel.isMeaningful || commuteSummary != nil {
            GettingAroundCard(summary: travel, commute: commuteSummary, period: analysisInterval)
        }
        WeeklyRoutineChangesSection(changes: routineChanges)
    }
}

private struct WeeklyStripSection: View {
    let days: [WeeklyStrip.Day]
    let now: Date
    let selectedDate: Date
    let onSelectDay: (Date) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This week").font(.title2.bold())
            Text("Each column is a day; colours show where your time went.")
                .font(.subheadline).foregroundStyle(.secondary)
            WeeklyStrip(days: days, today: now, selectedDate: selectedDate, onSelectDay: onSelectDay)
        }
        .padding(20).lifeCard()
        .accessibilityIdentifier("insights-weekly-strip")
    }
}

private struct WeeklyRoutineChangesSection: View {
    let changes: [WeekRoutineChange]

    var body: some View {
        if !changes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("What changed").font(.headline)
                Text("Compared with your last \(WeekRoutineChange.baselineWeekCount) weeks")
                    .font(.subheadline).foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    ForEach(changes) { change in
                        HStack(spacing: 14) {
                            Image(systemName: change.delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.headline).foregroundStyle(.secondary)
                                .frame(width: 36, height: 36)
                                .background(Color.secondary.opacity(0.1), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(change.category).font(.subheadline.weight(.medium))
                                Text("\(formatHours(change.latest)) vs usual \(formatHours(change.baseline))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(change.category), \(formatHours(change.latest)) this week, usually \(formatHours(change.baseline))")
                    }
                }
            }
            .padding(20).lifeCard()
            .accessibilityIdentifier("insights-week-routine-changes")
        }
    }
}

struct WeeklyYourWeekCard: View {
    let metrics: [WeeklyYourWeekMetric]
    let groupTotals: [String: Double]
    let periodTitle: String
    let interval: DateInterval
    let segments: [InsightSegment]

    private var groups: [String] {
        groupTotals.filter { $0.value > 0.01 }.keys.sorted { groupTotals[$0, default: 0] > groupTotals[$1, default: 0] }
    }

    private var totalHours: Double {
        groups.reduce(0) { $0 + groupTotals[$1, default: 0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your week").font(.title2.bold())
            VStack(spacing: 10) {
                ForEach(metrics) { metric in
                    metricRow(metric)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Groups").font(.headline)
                groupBar
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                    GridItem(.flexible(), alignment: .leading)], spacing: 8) {
                    ForEach(groups, id: \.self) { area in
                        NavigationLink {
                            InsightGroupDetailView(title: area, groups: [area], periodTitle: periodTitle,
                                                      interval: interval, segments: segments)
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(insightColor(for: area)).frame(width: 8, height: 8)
                                Text(area).font(.caption)
                                    .lineLimit(1).minimumScaleFactor(0.8)
                                Spacer(minLength: 2)
                                Text(formatHours(groupTotals[area, default: 0]))
                                    .font(.caption.bold().monospacedDigit())
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(area), \(formatHours(groupTotals[area, default: 0]))")
                    }
                }
                .accessibilityHint("Select a group to see its activities.")
            }
        }
        .padding(20)
        .lifeCard()
        .accessibilityIdentifier("insights-week-groups")
    }

    @ViewBuilder
    private func metricRow(_ metric: WeeklyYourWeekMetric) -> some View {
        if let action = metric.action {
            Button(action: action) { metricContent(metric) }
                .buttonStyle(.plain)
        } else {
            metricContent(metric)
        }
    }

    private func metricContent(_ metric: WeeklyYourWeekMetric) -> some View {
        HStack(spacing: 10) {
            Label(metric.title, systemImage: metric.icon)
                .font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(2).minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            Text(metric.value)
                .font(.subheadline.bold().monospacedDigit())
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metric.title): \(metric.value)")
    }

    private var groupBar: some View {
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(groups, id: \.self) { area in
                    Rectangle()
                        .fill(insightColor(for: area))
                        .frame(width: max(2, proxy.size.width * groupTotals[area, default: 0] / max(totalHours, 0.01)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .frame(height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Life-area balance across \(formatHours(totalHours))")
    }
}
