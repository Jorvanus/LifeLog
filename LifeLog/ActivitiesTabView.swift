import SwiftUI
import SwiftData
import Charts

/// The activities screen: every label you use, with the shape of the last week beside
/// it, and a page of detail behind each one.
///
/// Insights answers "where did my time go" by group. This answers "what about this
/// one thing" — how often, how long, where, and whether it is going up or down.
struct ActivitiesTabView: View {
    @Query(sort: \Visit.arrival, order: .reverse) private var visits: [Visit]
    @State private var definitions = ActivityCatalog.load()
    @State private var now = Date.now

    /// Every activity in the catalogue, plus any label the timeline uses that the
    /// catalogue has never heard of — otherwise the screen would quietly omit the
    /// activities most in need of attention.
    private var rows: [Row] {
        var seen = Set<String>()
        var result: [Row] = []
        for definition in definitions {
            let key = definition.name.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(Row(name: definition.name, symbol: definition.symbol,
                              statistics: ActivityStatistics.make(activity: definition.name,
                                                                  visits: visits, now: now)))
        }
        for visit in visits {
            let name = visit.activity.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            result.append(Row(name: name, symbol: "circle.fill",
                              statistics: ActivityStatistics.make(activity: name,
                                                                  visits: visits, now: now)))
        }
        // Used first, unused last, each alphabetical: a list of labels is scanned by
        // name, but a label you have never recorded is not what you came here for.
        return result.sorted { left, right in
            let leftUsed = left.statistics.occasions > 0
            let rightUsed = right.statistics.occasions > 0
            if leftUsed != rightUsed { return leftUsed }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    private struct Row: Identifiable {
        let name: String
        let symbol: String
        let statistics: ActivityStatistics
        var id: String { name }
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
                                }
                                Spacer(minLength: 8)
                                WeekSparkline(days: row.statistics.recentDays,
                                              color: activityColor(row.name))
                                    .frame(width: 78, height: 30)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } footer: {
                    Text("The line beside each activity is the last seven days.")
                }
            }
            .navigationTitle("Activities")
            .accessibilityIdentifier("activities-tab-screen")
            .onAppear {
                definitions = ActivityCatalog.load()
                now = .now
            }
        }
    }

    private func subtitle(for statistics: ActivityStatistics) -> String {
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
