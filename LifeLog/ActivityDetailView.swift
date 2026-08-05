import SwiftUI
import SwiftData
import Charts

/// One activity in depth: how it moved over time, how it compares with the period
/// before, where it happens, and the totals underneath.
struct ActivityDetailView: View {
    let activityName: String
    var symbol: String = "circle.fill"
    @Query private var candidates: [Visit]
    @State private var window: Window = .week
    @State private var now = Date.now

    enum Window: String, CaseIterable, Identifiable {
        case week = "7 days"
        case month = "30 days"
        case quarter = "90 days"

        var days: Int {
            switch self {
            case .week: 7
            case .month: 30
            case .quarter: 90
            }
        }
        var id: String { rawValue }
    }

    init(activityName: String, symbol: String = "circle.fill") {
        self.activityName = activityName
        self.symbol = symbol
        let name = activityName
        // SwiftData cannot filter on `activity` because it is computed, so the fetch
        // is loose and narrowed by the same rule the rest of the app uses.
        _candidates = Query(
            filter: #Predicate<Visit> { $0.userActivity == name || $0.inferredActivity == name },
            sort: [SortDescriptor(\Visit.arrival, order: .reverse)]
        )
    }

    private var statistics: ActivityStatistics {
        ActivityStatistics.make(activity: activityName, visits: candidates,
                                days: window.days, now: now)
    }

    var body: some View {
        List {
            if statistics.isEmpty {
                ContentUnavailableView("Nothing recorded yet", systemImage: "chart.line.uptrend.xyaxis",
                                       description: Text("When your timeline uses “\(activityName)”, its history appears here."))
            } else {
                overTime
                comparison
                places
                totals
                usage
            }
        }
        .navigationTitle(activityName)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("activity-detail-screen")
        .onAppear { now = .now }
    }

    private var overTime: some View {
        Section {
            Picker("Period", selection: $window) {
                ForEach(Window.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Chart(statistics.recentDays) { day in
                BarMark(x: .value("Day", day.day, unit: .day),
                        y: .value("Hours", day.hours))
                    .foregroundStyle(activityColor(activityName))
            }
            .frame(height: 160)
            .chartYAxis { AxisMarks(position: .leading) }
            .accessibilityLabel("\(activityName) over the last \(window.rawValue)")
        } header: {
            Text("Over time")
        }
    }

    private var comparison: some View {
        Section {
            LabeledContent("This \(window.rawValue)", value: formattedDuration(statistics.currentPeriodTime))
            LabeledContent("Previous \(window.rawValue)", value: formattedDuration(statistics.previousPeriodTime))
            if let change = statistics.changeFraction {
                LabeledContent("Change") {
                    Label(percentage(change), systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .foregroundStyle(change >= 0 ? .green : .orange)
                }
            }
            LabeledContent("Average per day", value: formattedDuration(statistics.averagePerDay))
            LabeledContent("Average per week", value: formattedDuration(statistics.averagePerWeek))
        } header: {
            Text("Compared with before")
        } footer: {
            if statistics.changeFraction == nil {
                Text("There is nothing recorded in the previous period to compare with.")
            }
        }
    }

    private var places: some View {
        Section("Top locations") {
            ForEach(statistics.places.prefix(8)) { place in
                LabeledContent(place.name, value: "\(place.occasions)")
            }
        }
    }

    private var totals: some View {
        Section("Totals") {
            LabeledContent("Total occasions", value: "\(statistics.occasions)")
            LabeledContent("Total time", value: formattedDuration(statistics.totalTime))
            LabeledContent("Average", value: formattedDuration(statistics.averageTime))
            LabeledContent("Shortest", value: formattedDuration(statistics.shortestTime))
            LabeledContent("Longest", value: formattedDuration(statistics.longestTime))
        }
    }

    @ViewBuilder private var usage: some View {
        Section {
            if let first = statistics.firstUsed {
                Text(usageSentence(occasions: statistics.occasions, first: first))
            }
            if let last = statistics.lastUsed {
                Text("Last used on \(last.formatted(date: .long, time: .omitted)).")
            }
        } header: {
            Text("Usage")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    /// Reads as a sentence rather than a field, because a single use is worth saying
    /// out loud: it is usually the sign of a label that was created and then forgotten.
    private func usageSentence(occasions: Int, first: Date) -> String {
        let date = first.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        return occasions == 1
            ? "This activity was used once, on \(date)."
            : "First used on \(date), \(occasions) times since."
    }

    private func percentage(_ change: Double) -> String {
        let magnitude = abs(change) * 100
        let rounded = magnitude >= 10 ? String(format: "%.0f", magnitude) : String(format: "%.1f", magnitude)
        return "\(change >= 0 ? "+" : "−")\(rounded)%"
    }
}
