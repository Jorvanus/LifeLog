import Charts
import SwiftUI

/// A focused drill-down for physiological trends. The main Insights screen keeps
/// the summary compact; this screen is where a person can inspect daily changes.
struct HealthTrendsView: View {
    let activityData: ActivityDataService
    let interval: DateInterval
    let periodTitle: String

    /// A long archive-scale HealthKit query makes the Trends screen wait on data
    /// that cannot be read on its chart. Keep each requested series bounded.
    private var trendInterval: DateInterval? {
        let end = min(interval.end, .now)
        let start = max(interval.start, end.addingTimeInterval(-90 * 24 * 60 * 60))
        return end > start ? DateInterval(start: start, end: end) : nil
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                HealthTrendsIntro(periodTitle: periodTitle)
                if let trendInterval {
                    Text("Choose a metric to load up to 90 days of daily samples. Loading one at a time keeps Insights responsive if Apple Health is slow or a type has no data.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(HealthTrendMetric.allCases) { metric in
                        HealthTrendMetricSection(metric: metric, activityData: activityData,
                                                 interval: trendInterval)
                    }
                } else {
                    ContentUnavailableView("No recent period to chart",
                                           systemImage: "calendar",
                                           description: Text("Choose a more recent Insights period to view Health Trends."))
                }
            }
            .padding(18)
        }
        .background(Color.lifeBackground.ignoresSafeArea())
        .navigationTitle("Health Trends")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HealthTrendsIntro: View {
    let periodTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Health signals", systemImage: "heart.text.square.fill")
                .font(.title2.bold())
            Text("Daily averages from Apple Health for \(periodTitle.lowercased()). Compare changes with your own usual pattern; these are observations, not diagnoses.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Each HealthKit type owns its own loading state. A bad or slow type must not
/// delay the other cards, nor prevent the person from leaving this screen.
private struct HealthTrendMetricSection: View {
    let metric: HealthTrendMetric
    let activityData: ActivityDataService
    let interval: DateInterval
    @State private var points: [HealthTrendPoint] = []
    @State private var isLoading = false
    @State private var didLoad = false

    private var latest: HealthTrendPoint? { points.last }
    private var average: Double { points.reduce(0) { $0 + $1.value } / Double(points.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(metric.title, systemImage: metric.symbol)
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if let latest {
                    Text("\(latest.value, format: .number.precision(.fractionLength(0))) \(metric.unitTitle)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
            }
            if didLoad, points.isEmpty {
                Text("No samples were returned for this period.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if !points.isEmpty {
                Chart(points) { point in
                    LineMark(x: .value("Date", point.date),
                             y: .value(metric.unitTitle, point.value))
                        .interpolationMethod(.catmullRom)
                    PointMark(x: .value("Date", point.date),
                              y: .value(metric.unitTitle, point.value))
                }
                .chartYAxisLabel(metric.unitTitle)
                .frame(height: 150)
                HStack {
                    Text("Average")
                    Spacer()
                    Text("\(average, format: .number.precision(.fractionLength(0))) \(metric.unitTitle)")
                        .monospacedDigit()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if !didLoad && !isLoading {
                Button("Load \(metric.title)") { load() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .lifeCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("health-trend-\(metric.rawValue)")
    }

    private func load() {
        isLoading = true
        Task {
            let loaded = await activityData.healthTrend(for: metric, interval: interval)
            guard !Task.isCancelled else { return }
            points = loaded
            didLoad = true
            isLoading = false
        }
    }
}
