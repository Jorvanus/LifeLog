import SwiftUI

struct TravelInsightsCard: View {
    let title: String
    let summary: TravelInsights.Summary
    var period: DateInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.bold())
            if summary.trips.isEmpty {
                InsightEmptyRow(icon: "car.fill", title: "No resolved travel", detail: "Travel appears when movement connects two destinations.")
            } else {
                HStack(spacing: 12) {
                    metric("Time", formatHours(summary.totalHours))
                    metric("Trips", "\(summary.tripCount)")
                    metric("Median", summary.medianTripMinutes.map { formatMinutes($0) } ?? "—")
                    metric("Long trips", "\(summary.longTripCount)")
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Commute \(formatHours(summary.commuteHours)) · other travel \(formatHours(summary.nonCommuteHours))")
                        .font(.subheadline)
                    if let share = summary.wakingShare {
                        Text("\(Int((share * 100).rounded()))% of waking, non-sleep time")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    let modes = TravelInsights.Mode.allCases.compactMap { mode -> String? in
                        guard let count = summary.modeCounts[mode], count > 0 else { return nil }
                        return "\(mode.rawValue) \(count)"
                    }
                    if !modes.isEmpty {
                        Text(modes.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            NavigationLink {
                TravelTripsView(title: title, trips: summary.trips, period: period)
            } label: {
                Label("Review trips", systemImage: "list.bullet.rectangle")
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityLabel("Review \(summary.tripCount) travel trips")
        }
        .padding(20).lifeCard()
        .accessibilityIdentifier("insights-travel-summary")
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatMinutes(_ minutes: Double) -> String {
        let rounded = Int(minutes.rounded())
        if rounded < 60 { return "\(rounded)m" }
        return "\(rounded / 60)h \(rounded % 60)m"
    }
}

struct TravelTripsView: View {
    let title: String
    let trips: [TravelInsights.Trip]
    var period: DateInterval?

    var body: some View {
        List {
            if trips.isEmpty {
                ContentUnavailableView("No travel", systemImage: "car.fill",
                                       description: Text("No resolved transitions were recorded for this period."))
            } else {
                ForEach(trips) { trip in
                    HStack(spacing: 12) {
                        Image(systemName: trip.mode.symbol)
                            .foregroundStyle(trip.isCommute ? .teal : .blue)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(trip.isCommute ? "Commute" : "Travel")
                                .font(.headline)
                            Text("\(trip.start.formatted(date: .abbreviated, time: .shortened)) – \(trip.end.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formatHours(trip.hours))
                            .font(.subheadline.bold().monospacedDigit())
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(trip.isCommute ? "Commute" : "Travel"), \(formatHours(trip.hours)), \(trip.mode.rawValue)")
                }
            }
        }
        .navigationTitle("\(title) trips")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            if let period {
                Text("Selected period: \(period.start.formatted(date: .abbreviated, time: .omitted))–\(period.end.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.vertical, 8)
                    .background(.thinMaterial)
                    .accessibilityIdentifier("travel-selected-period")
            }
        }
    }
}
