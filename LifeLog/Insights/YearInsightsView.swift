import Foundation
import SwiftUI
import Charts

private enum YearPlaceSection: String, CaseIterable, Identifiable {
    case mostTime = "Most time"
    case mostVisits = "Most visits"
    case newPlaces = "New places"
    case notVisited = "Not visited"

    var id: String { rawValue }
}

private enum AnnualHealthSection: String, CaseIterable, Identifiable {
    case movement = "Movement"
    case sleep = "Sleep"
    case workouts = "Workouts"

    var id: String { rawValue }
}

private struct YearPlaceStoryCard: View {
    let insights: AnnualInsights
    @Binding var selection: YearPlaceSection
    let openPlace: (AnnualInsights.Place) -> Void

    private var places: [AnnualInsights.Place] {
        switch selection {
        case .mostTime: return insights.placesByTime
        case .mostVisits: return insights.placesByVisits
        case .newPlaces: return insights.newPlaces
        case .notVisited: return insights.placesNotVisited
        }
    }

    private var emptyMessage: String {
        switch selection {
        case .mostTime: return "No places with enough recorded time."
        case .mostVisits: return "No places with recorded visits."
        case .newPlaces: return "No newly discovered places with enough history."
        case .notVisited: return "No regular places were missed this year with enough comparable history."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Places that shaped the year").font(.title2.bold())
            Picker("Places", selection: $selection) {
                ForEach(YearPlaceSection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("year-place-picker")

            Text(selection.rawValue).font(.headline)
            if places.isEmpty {
                Text(emptyMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(places.prefix(5)) { place in
                    Button { openPlace(place) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: insightSymbol(for: place.category))
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(insightColor(for: place.category), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.8)
                                Text("\(place.category) · \(place.visits) \(place.visits == 1 ? "visit" : "visits")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(formatHours(place.hours))
                                    .font(.subheadline.bold().monospacedDigit())
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                Image(systemName: "chevron.right")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(place.name), \(place.visits) \(place.visits == 1 ? "visit" : "visits"), \(formatHours(place.hours))")
                }
            }
        }
    }
}

struct YearInsightsView: View {
    let insights: AnnualInsights
    let openArea: (AnnualInsights.LifeArea) -> Void
    let openPlace: (AnnualInsights.Place) -> Void
    let period: DateInterval
    @State private var selectedArea: AnnualInsights.LifeArea?
    @State private var selectedPlaceSection: YearPlaceSection = .mostTime
    @State private var selectedHealthSection: AnnualHealthSection = .movement

    var body: some View {
        VStack(spacing: 18) {
            annualStory
            lifeAreas
            placeSummary
            movementAndWellbeing
            TravelInsightsCard(title: "Travel", summary: insights.travel, period: period)
            milestones
        }
    }

    private var annualStory: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your year in perspective").font(.title2.bold())
            if insights.comparisonSupported {
                Text("A concise view of how your time, places, movement, and routines changed from last year.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("This year is still building. Comparisons appear after both years have enough recorded history.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Text("Recorded: \(formatHours(insights.currentLoggedHours))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).lifeCard()
        .accessibilityIdentifier("insights-year-story")
    }

    private var lifeAreas: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How the year was spent").font(.title2.bold())
            Text("Monthly time by derived life area. Select an area to highlight it.")
                .font(.subheadline).foregroundStyle(.secondary)
            AnnualLifeAreasChart(months: insights.months, selectedArea: $selectedArea, openArea: openArea)
        }
        .padding(20).lifeCard()
        .accessibilityIdentifier("insights-year-life-areas")
    }

    private var placeSummary: some View {
        YearPlaceStoryCard(insights: insights, selection: $selectedPlaceSection, openPlace: openPlace)
        .padding(20).lifeCard()
        .accessibilityIdentifier("insights-year-places")
    }

    private var movementAndWellbeing: some View {
        AnnualHealthVisual(months: insights.months, health: insights.health, selection: $selectedHealthSection)
            .padding(20).lifeCard()
            .accessibilityIdentifier("insights-year-wellbeing")
    }

    @ViewBuilder private var milestones: some View {
        let milestone = insights.milestones
        if milestone.leadingIncrease != nil || milestone.longestActivityStreak != nil || milestone.longestPlaceGap != nil || milestone.mostVisitedNewPlace != nil {
            VStack(alignment: .leading, spacing: 12) {
                Text("A few milestones").font(.title2.bold())
                if let value = milestone.leadingIncrease { Text("Most increased: \(value)").font(.subheadline) }
                if let value = milestone.longestActivityStreak { Text("Longest streak: \(value.activity), \(value.days) days").font(.subheadline) }
                if let value = milestone.longestPlaceGap { Text("Longest return gap: \(value.place), \(value.days) days").font(.subheadline) }
                if let value = milestone.mostVisitedNewPlace { Text("Most visited new place: \(value.name), \(value.visits) visits").font(.subheadline) }
            }
            .padding(20).lifeCard()
            .accessibilityIdentifier("insights-year-milestones")
        }
    }
}

private struct AnnualHealthPoint: Identifiable {
    let id: Date
    let label: String
    let value: Double
}

private struct AnnualHealthSeries: Identifiable {
    let id: String
    let title: String
    let unit: String
    let values: [Double?]
    let integerValues: Bool

    var hasData: Bool { values.contains { $0 != nil } }

    func points(months: [AnnualInsights.Month]) -> [AnnualHealthPoint] {
        months.enumerated().compactMap { index, month in
            guard values.indices.contains(index), let value = values[index] else { return nil }
            return AnnualHealthPoint(id: month.id, label: month.label, value: value)
        }
    }

    func formatted(_ value: Double) -> String {
        integerValues ? "\(Int(value.rounded()).formatted()) \(unit)" : "\(String(format: "%.1f", value)) \(unit)"
    }
}

private struct AnnualHealthVisual: View {
    let months: [AnnualInsights.Month]
    let health: AnnualInsights.HealthMetrics
    @Binding var selection: AnnualHealthSection

    private var series: [AnnualHealthSeries] {
        let movement: [AnnualHealthSeries] = [
            AnnualHealthSeries(id: "steps", title: "Steps", unit: "steps/day", values: health.monthlySteps, integerValues: true),
            AnnualHealthSeries(id: "walking", title: "Walking/running", unit: "km/month", values: health.monthlyWalkingKilometres, integerValues: false),
            AnnualHealthSeries(id: "energy", title: "Active energy", unit: "kcal/month", values: health.monthlyActiveEnergy, integerValues: true),
            AnnualHealthSeries(id: "exercise", title: "Exercise", unit: "min/month", values: health.monthlyExerciseMinutes, integerValues: true)
        ]
        switch selection {
        case .movement: return movement
        case .sleep: return [AnnualHealthSeries(id: "sleep", title: "Average sleep", unit: "h/night", values: health.monthlySleepHours, integerValues: false)]
        case .workouts: return [AnnualHealthSeries(id: "workouts", title: "Workout duration", unit: "min/month", values: health.monthlyWorkoutMinutes, integerValues: true)]
        }
    }

    private var visibleSeries: [AnnualHealthSeries] {
        let available = series.filter(\.hasData)
        if selection == .movement, let first = available.first {
            return [first]
        }
        return available
    }

    private var primarySeries: AnnualHealthSeries? { visibleSeries.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Movement and wellbeing").font(.title2.bold())
            Text("Apple Health summaries across the year")
                .font(.subheadline).foregroundStyle(.secondary)
            Picker("Health summary", selection: $selection) {
                ForEach(AnnualHealthSection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("year-health-picker")

            if !health.healthDataAvailable {
                ContentUnavailableView("Apple Health is not connected", systemImage: "heart.slash",
                                       description: Text("Connect Apple Health to add annual movement, sleep, and workout summaries."))
            } else if let primarySeries {
                Text("\(primarySeries.title) · Apple Health")
                    .font(.headline)
                AnnualHealthChart(months: months, series: primarySeries)
                HStack(spacing: 18) {
                    AnnualHealthSummary(title: "Annual average", value: averageText(for: primarySeries))
                    AnnualHealthSummary(title: "Highest month", value: highestText(for: primarySeries))
                }
                ForEach(visibleSeries.dropFirst()) { item in
                    AnnualHealthSummaryRow(series: item)
                }
            } else {
                ContentUnavailableView("No \(selection.rawValue.lowercased()) data", systemImage: "chart.xyaxis.line",
                                       description: Text("There is no usable \(selection.rawValue.lowercased()) data from Apple Health for this year."))
            }

            Text("Health values are sourced from Apple Health; sleep score is a LifeLog estimate when shown in detail.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func averageText(for series: AnnualHealthSeries) -> String {
        let values = series.values.compactMap { $0 }
        return series.formatted(values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count))
    }

    private func highestText(for series: AnnualHealthSeries) -> String {
        series.formatted(series.values.compactMap { $0 }.max() ?? 0)
    }

}

private struct AnnualHealthChart: View {
    let months: [AnnualInsights.Month]
    let series: AnnualHealthSeries

    private var points: [AnnualHealthPoint] { series.points(months: months) }
    private var axisLabels: [String] {
        months.enumerated().compactMap { index, month in
            months.count <= 6 || index.isMultiple(of: 2) ? month.label : nil
        }
    }

    var body: some View {
        Chart(points) { point in
            BarMark(x: .value("Month", point.label), y: .value(series.title, point.value))
                .foregroundStyle(.blue.gradient)
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
        .accessibilityLabel("Monthly \(series.title) from Apple Health")
        .accessibilityValue(points.map { "\($0.label), \(series.formatted($0.value))" }.joined(separator: ". "))
        .accessibilityIdentifier("year-health-chart")
    }
}

private struct AnnualHealthSummary: View {
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

private struct AnnualHealthSummaryRow: View {
    let series: AnnualHealthSeries

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
        .accessibilityLabel("\(series.title), Apple Health, monthly average \(series.formatted(average))")
    }
}
