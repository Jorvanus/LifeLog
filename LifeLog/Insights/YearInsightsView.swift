import SwiftUI

struct YearInsightsView: View {
    let insights: AnnualInsights
    let openArea: (AnnualInsights.LifeArea) -> Void

    var body: some View {
        VStack(spacing: 18) {
            annualStory
            lifeAreas
            placeSummary
            movementAndWellbeing
            TravelInsightsCard(title: "Travel", summary: insights.travel)
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
            Text("Monthly time by derived life area").font(.subheadline).foregroundStyle(.secondary)
            AnnualLifeAreasChart(months: insights.months)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(AnnualInsights.areas) { area in
                    Button { openArea(area) } label: {
                        Label(area.name, systemImage: insightSymbol(for: area.category))
                            .font(.caption)
                            .foregroundStyle(insightColor(for: area.category))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(area.name) activity details")
                }
            }
        }
        .padding(20).lifeCard()
        .accessibilityIdentifier("insights-year-life-areas")
    }

    private var placeSummary: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Places that shaped the year").font(.title2.bold())
            placeList(title: "Most time", places: insights.placesByTime)
            placeList(title: "Most visits", places: insights.placesByVisits)
            placeList(title: "Newly discovered", places: insights.newPlaces)
            if !insights.placesNotVisited.isEmpty {
                placeList(title: "Regular places you did not visit", places: insights.placesNotVisited)
            }
        }
        .padding(20).lifeCard()
        .accessibilityIdentifier("insights-year-places")
    }

    @ViewBuilder private func placeList(title: String, places: [AnnualInsights.Place]) -> some View {
        Text(title).font(.headline)
        if places.isEmpty {
            Text("Not enough recorded history").font(.subheadline).foregroundStyle(.secondary)
        } else {
                ForEach(places) { place in
                    NavigationLink { PlaceHistoryDetail(placeName: place.name) } label: {
                        HStack {
                            Image(systemName: insightSymbol(for: place.category))
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                                .frame(width: 42, height: 42)
                                .background(insightColor(for: place.category), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.name).font(.subheadline.weight(.medium))
                                Text("\(place.category) · \(place.visits) \(place.visits == 1 ? "visit" : "visits")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        Spacer()
                        Text(formatHours(place.hours)).font(.subheadline.bold().monospacedDigit())
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(place.name), \(place.visits) visits, \(formatHours(place.hours))")
            }
        }
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
            }
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
