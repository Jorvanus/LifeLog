import SwiftUI

/// Detail destinations opened from Insights. They deliberately receive the
/// already bounded segments from the parent instead of querying the archive.
struct InsightActivityDetailView: View {
    let activity: String
    let periodTitle: String
    let interval: DateInterval
    let rows: [SliceRow]

    var body: some View {
        List {
            Section {
                LabeledContent("Period", value: periodTitle)
                LabeledContent("Total", value: formatHours(rows.reduce(0) { $0 + $1.hours }))
            }
            .accessibilityIdentifier("insight-activity-period")
            Section("Visits in this period") {
                if rows.isEmpty {
                    ContentUnavailableView("No recorded visits", systemImage: "clock.badge.questionmark",
                                           description: Text("This activity has no usable records in the selected period."))
                } else {
                    ForEach(rows) { row in
                        if let visit = row.visit {
                            NavigationLink { VisitEditor(visit: visit) } label: {
                                InsightRowLabel(title: visit.displayPlaceName,
                                                detail: "(visit.arrival.formatted(date: .abbreviated, time: .shortened)) · (formatHours(row.hours))")
                            }
                        } else {
                            InsightRowLabel(title: row.activity, detail: formatHours(row.hours))
                        }
                    }
                }
            }
        }
        .navigationTitle(activity)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) { PeriodBanner(title: periodTitle, interval: interval) }
        .accessibilityIdentifier("insight-activity-detail")
    }
}

struct InsightLifeAreaDetailView: View {
    let area: LifeArea
    let periodTitle: String
    let interval: DateInterval
    let segments: [InsightSegment]

    private var activities: [(name: String, hours: Double, rows: [SliceRow])] {
        let matching = segments.filter {
            !$0.isUnlogged && ActivityCatalog.lifeArea(for: $0.activity, category: $0.category) == area
        }
        let grouped = Dictionary(grouping: matching, by: \.activity)
        return grouped.map { name, segments in
            (name, segments.reduce(0) { $0 + $1.hours }, segments.map {
                SliceRow(id: $0.id, visit: $0.visit, activity: $0.activity, placeName: $0.placeName,
                         start: $0.start, end: $0.end, hours: $0.hours, isPartial: false)
            })
        }.sorted { $0.hours > $1.hours }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Period", value: periodTitle)
                LabeledContent("Total", value: formatHours(activities.reduce(0) { $0 + $1.hours }))
            }
            Section("Activities in this life area") {
                ForEach(activities, id: \.name) { activity in
                    NavigationLink {
                        InsightActivityDetailView(activity: activity.name, periodTitle: periodTitle,
                                                  interval: interval, rows: activity.rows)
                    } label: {
                        InsightRowLabel(title: activity.name, detail: formatHours(activity.hours))
                    }
                }
            }
        }
        .navigationTitle(area.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) { PeriodBanner(title: periodTitle, interval: interval) }
        .accessibilityIdentifier("insight-life-area-detail")
    }
}

struct InsightPlaceHistoryView: View {
    let placeName: String
    let periodTitle: String
    let interval: DateInterval
    let rows: [SliceRow]

    var body: some View {
        List {
            Section {
                LabeledContent("Period", value: periodTitle)
                LabeledContent("Visits", value: "\(rows.compactMap(\.visit).count)")
                LabeledContent("Time", value: formatHours(rows.reduce(0) { $0 + $1.hours }))
            }
            Section("Visits in this period") {
                if rows.isEmpty {
                    ContentUnavailableView("No visits", systemImage: "mappin.slash",
                                           description: Text("This place has no usable records in the selected period."))
                } else {
                    ForEach(rows) { row in
                        if let visit = row.visit {
                            NavigationLink { VisitEditor(visit: visit) } label: {
                                InsightRowLabel(title: visit.suspectedActivity.isEmpty ? "Visit" : visit.suspectedActivity,
                                                detail: "(visit.arrival.formatted(date: .abbreviated, time: .shortened)) · (formatHours(row.hours))")
                            }
                        } else {
                            InsightRowLabel(title: row.activity, detail: formatHours(row.hours))
                        }
                    }
                }
            }
        }
        .navigationTitle(placeName)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) { PeriodBanner(title: periodTitle, interval: interval) }
        .accessibilityIdentifier("insight-place-history-detail")
    }
}

struct InsightComparisonDetailView: View {
    let comparison: TrendComparison
    let periodTitle: String
    let baselineTitle: String

    var body: some View {
        List {
            Section("Selected period") {
                LabeledContent(periodTitle, value: formatHours(comparison.hours))
                LabeledContent("Baseline", value: formatHours(comparison.previousHours))
                LabeledContent("Difference", value: formatHours(abs(comparison.delta)) + (comparison.delta >= 0 ? " more" : " less"))
            }
            Section {
                Text("This comparison describes a difference in recorded time. It does not explain why the change happened.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("Compared with (baselineTitle)")
            }
        }
        .navigationTitle(comparison.name)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("insight-comparison-detail")
    }
}

struct InsightSleepDetailView: View {
    let periodTitle: String
    let interval: DateInterval
    let segments: [InsightSegment]
    let activityData: ActivityDataService
    @State private var summary: SleepSummary?

    private var recordedHours: Double { segments.filter(\.isSleep).reduce(0) { $0 + $1.hours } }

    var body: some View {
        List {
            Section("Recorded sleep") {
                LabeledContent("Period", value: periodTitle)
                LabeledContent("Duration", value: summary.map { formatHours($0.totalSleep / 3600) } ?? formatHours(recordedHours))
                if let summary {
                    LabeledContent("LifeLog estimated score", value: "\(summary.estimatedScore)/100")
                    LabeledContent("Interruptions", value: "\(summary.interruptions)")
                    if summary.rem + summary.core + summary.deep > 0 {
                        LabeledContent("Stages", value: "REM \(formatHours(summary.rem / 3600)) · Core \(formatHours(summary.core / 3600)) · Deep \(formatHours(summary.deep / 3600))")
                    }
                } else {
                    Text("Sleep stages and interruptions are unavailable for this period.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("About this data") {
                Text(summary == nil ? "No Apple Health sleep samples were available. Recorded sleep-looking visits are shown as LifeLog activity only." : "Source: Apple Health. Sleep stages come from Health data when available. The score is a LifeLog estimate, not an Apple Watch or Apple Health score.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let imported = activityData.lastImport {
                    Text("Last successful Health import: \(imported.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Sleep")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) { PeriodBanner(title: periodTitle, interval: interval) }
        .task { summary = await activityData.sleepSummary(for: interval) }
        .accessibilityIdentifier("insight-sleep-detail")
    }
}

struct InsightGapDetailView: View {
    let gap: InsightSegment
    let periodTitle: String
    @State private var adding = false

    var body: some View {
        List {
            Section("Unlogged time") {
                LabeledContent("Period", value: periodTitle)
                LabeledContent("Gap", value: "(gap.start.formatted(date: .omitted, time: .shortened))–(gap.end.formatted(date: .omitted, time: .shortened))")
                LabeledContent("Duration", value: formatHours(gap.hours))
            }
            Section {
                Button { adding = true } label: {
                    Label("Add or categorise a visit", systemImage: "plus.circle.fill")
                }
            } footer: {
                Text("This exact gap is selected so the visit you add will not broaden into another part of the day.")
            }
        }
        .navigationTitle("Timeline gap")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $adding) { ManualVisitView(range: DateInterval(start: gap.start, end: gap.end)) }
        .accessibilityIdentifier("insight-gap-detail")
    }
}

// Shared by all Insights drill-down destinations, including the Month place list.
struct PeriodBanner: View {
    let title: String
    let interval: DateInterval
    var body: some View {
        Text("Selected period: \(title)")
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal).padding(.vertical, 8)
            .background(.thinMaterial)
            .accessibilityElement(children: .combine)
    }
}

private struct InsightRowLabel: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}
