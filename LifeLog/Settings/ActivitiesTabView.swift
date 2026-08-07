import SwiftUI
import SwiftData
import Charts

/// The activities screen: every label you use, with the shape of the last week beside
/// it, and a page of detail behind each one.
///
/// Insights answers "where did my time go" by group. This answers "what about this
/// one thing" — how often, how long, where, and whether it is going up or down.
struct ActivitiesTabView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Visit.arrival, order: .reverse) private var visits: [Visit]
    /// Held rather than computed in `body`. As a computed property this was rebuilt on
    /// every render, and each rebuild walked the whole timeline once per activity.
    @State private var rows: [Row] = []

    private func reload() {
        let startedAt = Date.now
        let definitions = ActivityCatalog.load()
        var symbols: [String: String] = [:]
        for definition in definitions { symbols[definition.name.lowercased()] = definition.symbol }

        // Summaries, not full statistics: the list shows occasions, total time and
        // the week's shape. Everything else is computed when an activity is opened.
        let summaries = ActivityStatistics.summaries(named: definitions.map(\.name), visits: visits)
        // `summaries` deliberately also returns labels found in the archive that the
        // catalogue has never heard of — most of a bulk-imported history is exactly
        // that, and a screen reporting where time went must not hide it. But such a row
        // cannot be renamed, grouped or given an icon until it is adopted, and until now
        // nothing here said so or offered to do it.
        let adopted = Set(definitions.map { NameKey.matching($0.name) })
        var built = summaries.map { entry in
            Row(name: entry.activity,
                symbol: symbols[entry.activity.lowercased()] ?? "circle.fill",
                statistics: entry,
                isAdopted: adopted.contains(NameKey.matching(entry.activity)))
        }
        // Used first, unused last, each alphabetical: a list of labels is scanned by
        // name, but a label you have never recorded is not what you came here for.
        built.sort { left, right in
            let leftUsed = left.statistics.occasions > 0
            let rightUsed = right.statistics.occasions > 0
            if leftUsed != rightUsed { return leftUsed }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        rows = built
        // Instrumented because the first version of this screen was slow and left no
        // trace in Diagnostics to say so.
        Diagnostics.performance(context, subsystem: "Activities", operation: "activity statistics",
                                startedAt: startedAt, itemCount: visits.count)
    }

    private struct Row: Identifiable {
        let name: String
        let symbol: String
        let statistics: ActivityStatistics.Summary
        /// In the catalogue, so it can be edited in Settings → Activity Labels. False
        /// means the label exists only in recorded visits.
        let isAdopted: Bool
        var id: String { name }
    }

    /// Adds a label the archive already uses to the catalogue, so it can be renamed,
    /// grouped and given an icon — and so Insights stops counting it under "Other".
    ///
    /// The same thing "Add from your history" does in bulk, offered on the row where
    /// the person is already looking at the label and can see how much of their time
    /// it accounts for.
    private func adopt(_ row: Row) {
        guard ActivityCatalog.adoptFromHistory(row.name) else { return }
        // Grouping is computed rather than stored, so adopting a label re-buckets every
        // visit already carrying it. Insights has to be told.
        InsightsInvalidation.invalidate(reason: "Activity adopted from history", context: context)
        reload()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(rows) { row in
                        NavigationLink {
                            ActivityDetailView(activityName: row.name, symbol: row.symbol)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: row.symbol)
                                    .font(.title3)
                                    .foregroundStyle(activityColor(row.name))
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.name).font(.headline)
                                    Text(subtitle(for: row.statistics))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if !row.isAdopted {
                                        // Says why this row behaves differently from the
                                        // one above it, rather than leaving the person to
                                        // discover it in Settings.
                                        Label("From your history · not yet an activity",
                                              systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                                            .font(.caption2).foregroundStyle(.orange)
                                    }
                                }
                                Spacer(minLength: 8)
                                WeekSparkline(days: row.statistics.recentDays,
                                              color: activityColor(row.name))
                                    .frame(width: 78, height: 30)
                            }
                            .padding(.vertical, 2)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if !row.isAdopted {
                                Button { adopt(row) } label: {
                                    Label("Add", systemImage: "plus.circle.fill")
                                }.tint(.orange)
                            }
                        }
                        .accessibilityIdentifier(row.isAdopted ? "activity-row" : "unadopted-activity-row")
                    }
                } footer: {
                    Text(unadoptedCount == 0
                         ? "The line beside each activity is the last seven days."
                         : "The line beside each activity is the last seven days. \(unadoptedCount) \(unadoptedCount == 1 ? "label comes" : "labels come") from recorded visits and \(unadoptedCount == 1 ? "is" : "are") not in your activity list yet — tap to open one, or swipe to add \(unadoptedCount == 1 ? "it" : "them"), and Insights will stop counting \(unadoptedCount == 1 ? "it" : "them") as Other.")
                }
            }
            .navigationTitle("Activities")
            .accessibilityIdentifier("activities-tab-screen")
            .task { reload() }
            .onReceive(NotificationCenter.default.publisher(for: InsightsInvalidation.notification)) { _ in
                reload()
            }
        }
    }

    private var unadoptedCount: Int { rows.count { !$0.isAdopted } }

    private func subtitle(for statistics: ActivityStatistics.Summary) -> String {
        guard !statistics.isEmpty else { return "Not used yet" }
        let occasions = "\(statistics.occasions) \(statistics.occasions == 1 ? "occasion" : "occasions")"
        return "\(occasions) · \(formattedDuration(statistics.totalTime))"
    }
}

/// Seven days at a glance. Deliberately unlabelled: it shows the shape of a week, and
/// the numbers behind it are one tap away.
private struct WeekSparkline: View {
    let days: [ActivityStatistics.DayTotal]
    let color: Color

    var body: some View {
        if days.allSatisfy({ $0.hours == 0 }) {
            // A flat line rather than an empty frame, so an unused activity still
            // reads as "nothing this week" instead of looking like a rendering fault.
            Rectangle().fill(color.opacity(0.25)).frame(height: 1.5)
        } else {
            Chart(days) { day in
                AreaMark(x: .value("Day", day.day), y: .value("Hours", day.hours))
                    .foregroundStyle(color.opacity(0.18))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Day", day.day), y: .value("Hours", day.hours))
                    .foregroundStyle(color)
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .accessibilityHidden(true)
        }
    }
}
