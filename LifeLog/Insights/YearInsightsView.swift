import SwiftUI

private enum YearPlaceSection: String, CaseIterable, Identifiable {
    case mostTime = "Most time"
    case mostVisits = "Most visits"
    case newPlaces = "New places"
    case notVisited = "Not visited"

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
        VStack(alignment: .leading, spacing: 12) {
            Text("Movement and wellbeing").font(.title2.bold())
            if !insights.health.healthDataAvailable {
                Text("Connect Apple Health to add monthly sleep and step averages.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                if insights.health.monthlySleepHours.contains(where: { $0 != nil }) {
                    metricRow(title: "Average sleep", values: insights.health.monthlySleepHours, suffix: "h/night")
                }
                if insights.health.monthlySteps.contains(where: { $0 != nil }) {
                    metricRow(title: "Average daily steps", values: insights.health.monthlySteps, suffix: "steps/day", integer: true)
                }
                if insights.health.monthlyWalkingKilometres.contains(where: { $0 != nil }) {
                    metricRow(title: "Walking/running", values: insights.health.monthlyWalkingKilometres, suffix: "km/month")
                }
                if insights.health.monthlyActiveEnergy.contains(where: { $0 != nil }) {
                    metricRow(title: "Active energy", values: insights.health.monthlyActiveEnergy, suffix: "kcal/month", integer: true)
                }
                if insights.health.monthlyExerciseMinutes.contains(where: { $0 != nil }) {
                    metricRow(title: "Exercise", values: insights.health.monthlyExerciseMinutes, suffix: "min/month", integer: true)
                }
                if insights.health.monthlyWorkoutMinutes.contains(where: { $0 != nil }) {
                    metricRow(title: "Workouts", values: insights.health.monthlyWorkoutMinutes, suffix: "min/month", integer: true)
                }
                if insights.health.monthlyStandHours.contains(where: { $0 != nil }) {
                    metricRow(title: "Stand time", values: insights.health.monthlyStandHours, suffix: "h/month", integer: true)
                }
            }
            Text("Health values are sourced from Apple Health; sleep score is a LifeLog estimate when shown in detail.")
                .font(.footnote).foregroundStyle(.secondary)
            let exercise = insights.months.reduce(0) { total, month in total + (month.hours["Health/Fitness"] ?? 0) }
            if exercise > 0 { Text("Exercise and fitness: \(formatHours(exercise))").font(.subheadline) }
        }
        .padding(20).lifeCard()
        .accessibilityIdentifier("insights-year-wellbeing")
    }

    private func metricRow(title: String, values: [Double?], suffix: String, integer: Bool = false) -> some View {
        let available = values.compactMap { $0 }
        let average = available.isEmpty ? 0 : available.reduce(0, +) / Double(available.count)
        return HStack {
            Text(title).font(.subheadline)
            Spacer()
            Text(integer ? "\(Int(average.rounded())) \(suffix)" : "\(average, specifier: "%.1f") \(suffix)")
                .font(.subheadline.bold().monospacedDigit())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(integer ? "\(Int(average.rounded()))" : "\(average, specifier: "%.1f")") \(suffix)")
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
