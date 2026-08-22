import SwiftUI
import Charts

/// The three views Year and Month both offer over their own Apple Health
/// figures. Shared between `AnnualHealthVisual` and `MonthHealthVisual` since
/// the choice itself has nothing period-specific about it.
enum HealthChartSection: String, CaseIterable, Identifiable {
    case movement = "Movement"
    case sleep = "Sleep"
    case workouts = "Workouts"

    var id: String { rawValue }
}

/// One bar's position on the chart's axis -- a month for Year, a day for
/// Month. Deliberately just `id`/`label`: everything period-specific about
/// what a bar means lives in the caller, not here.
struct HealthChartAxisPoint: Identifiable {
    let id: Date
    let label: String
}

struct HealthChartPoint: Identifiable {
    let id: Date
    let label: String
    let value: Double
}

/// One line on the chart -- Steps, Average sleep, Workout duration, etc. --
/// still unaware of whether its values are month buckets or day buckets;
/// that split lives entirely in what `values` and `axis` are built from.
struct HealthChartSeries: Identifiable {
    let id: String
    let title: String
    let unit: String
    let values: [Double?]
    let integerValues: Bool

    var hasData: Bool { values.contains { $0 != nil } }

    func points(axis: [HealthChartAxisPoint]) -> [HealthChartPoint] {
        axis.enumerated().compactMap { index, point in
            guard values.indices.contains(index), let value = values[index] else { return nil }
            return HealthChartPoint(id: point.id, label: point.label, value: value)
        }
    }

    func formatted(_ value: Double) -> String {
        integerValues ? "\(Int(value.rounded()).formatted()) \(unit)" : "\(String(format: "%.1f", value)) \(unit)"
    }
}

struct HealthBarChart: View {
    let series: HealthChartSeries
    let points: [HealthChartPoint]
    let axisLabels: [String]
    let color: Color
    /// "Monthly"/"Daily" -- how each bar's period reads in its accessibility
    /// label ("Monthly Steps from Apple Health" vs. "Daily Steps...").
    let periodAdjective: String
    let accessibilityIdentifier: String

    var body: some View {
        Chart(points) { point in
            BarMark(x: .value("Period", point.label), y: .value(series.title, point.value))
                .foregroundStyle(color.gradient)
        }
        .chartXAxis {
            AxisMarks(values: axisLabels) { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label).font(.caption2).minimumScaleFactor(0.75).fixedSize()
                    }
                }
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .frame(height: 150)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(periodAdjective) \(series.title) from Apple Health")
        .accessibilityValue(points.map { "\($0.label), \(series.formatted($0.value))" }.joined(separator: ". "))
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct HealthChartSummary: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold().monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value), Apple Health")
    }
}

struct HealthChartSummaryRow: View {
    let series: HealthChartSeries
    /// "monthly average"/"daily average" -- matches whichever period the bars
    /// represent, read out after the series title in VoiceOver.
    let averageLabel: String

    private var average: Double {
        let values = series.values.compactMap { $0 }
        return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    var body: some View {
        HStack {
            Text("\(series.title) · Apple Health").font(.subheadline)
            Spacer()
            Text(series.formatted(average))
                .font(.subheadline.bold().monospacedDigit())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(series.title), Apple Health, \(averageLabel) \(series.formatted(average))")
    }
}
