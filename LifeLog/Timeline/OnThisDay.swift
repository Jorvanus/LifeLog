import SwiftUI
import SwiftData

/// The same calendar day, in earlier years.
///
/// The one thing nine years of history can offer that a fresh install cannot. It
/// reports **places rather than activity labels**: 24,940 of the 25,609 recorded
/// visits came from a bulk import whose labels are whatever the old app defaulted
/// to, so an activity read back from 2019 is often not what happened. A place name
/// came from an arrival that was actually recorded, and is a fact.
enum OnThisDay {
    struct Year: Identifiable, Equatable {
        /// The start of that day, so tapping it can open it.
        let day: Date
        let year: Int
        /// Where the day was spent, longest first.
        let places: [String]
        let visits: Int
        var id: Int { year }
    }

    /// Far enough back to cover the archive without an unbounded loop if the earliest
    /// record is ever missing.
    static let maximumYears = 12
    /// A day is recognisable from a few places. The whole list would be a timeline,
    /// which is what tapping through to the day is for.
    static let placesShown = 3

    /// The days to look at: the same month and day, one per earlier year, stopping
    /// before the first record rather than offering years that cannot hold anything.
    static func earlierDays(matching day: Date, notBefore earliest: Date?,
                            calendar: Calendar = .current) -> [Date] {
        let start = calendar.startOfDay(for: day)
        var days: [Date] = []
        for offset in 1...maximumYears {
            guard let earlier = calendar.date(byAdding: .year, value: -offset, to: start) else { continue }
            if let earliest, earlier < calendar.startOfDay(for: earliest) { break }
            days.append(earlier)
        }
        return days
    }

    /// What one earlier day held, or nil when it held nothing worth showing.
    ///
    /// Time is counted only for the part of a stay that fell inside the day, so a stay
    /// running from the evening before does not out-rank a place by hours it spent in
    /// a different day.
    static func summarise(_ visits: [Visit], on day: Date, calendar: Calendar = .current) -> Year? {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        let interval = DateInterval(start: start, end: end)
        let covering = visits
            .filter { ActivityLocationPolicy.covers($0, day: interval, now: end) }
            .filter { $0.resolutionState != .ignored && $0.resolutionState != .superseded }
        guard !covering.isEmpty else { return nil }

        var timeByPlace: [String: TimeInterval] = [:]
        for visit in covering {
            let name = visit.placeName.trimmingCharacters(in: .whitespacesAndNewlines)
            // A placeholder says nothing about where this was, and "Walking" is the
            // name device activity carries rather than a place.
            guard !Visit.isPlaceholderName(name),
                  !ActivityLocationPolicy.isDeviceActivity(visit) else { continue }
            let overlap = min(visit.departure ?? end, end).timeIntervalSince(max(visit.arrival, start))
            timeByPlace[name, default: 0] += max(0, overlap)
        }
        let places = timeByPlace.sorted { $0.value > $1.value }.prefix(placesShown).map(\.key)
        guard !places.isEmpty else { return nil }
        return Year(day: start, year: calendar.component(.year, from: start),
                    places: places, visits: covering.count)
    }
}

/// Shows the earlier years under the day being read, each one openable.
struct OnThisDaySection: View {
    let day: Date
    let earliest: Date?
    let open: (Date) -> Void
    @Environment(\.modelContext) private var context
    @State private var years: [OnThisDay.Year] = []

    var body: some View {
        Group {
            if !years.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("On this day")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                    VStack(spacing: 10) {
                        ForEach(years) { year in
                            Button { open(year.day) } label: { row(year) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .accessibilityIdentifier("on-this-day")
            }
        }
        // Keyed on the day, so moving to another date reloads rather than showing the
        // previous day's years under it.
        .task(id: day) { load() }
    }

    private func row(_ year: OnThisDay.Year) -> some View {
        HStack(spacing: 12) {
            Text(String(year.year))
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(year.places.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lifeCard()
    }

    /// One small fetch per year rather than one large one. The whole table is never
    /// loaded, and a day in 2017 costs what a day last year costs.
    private func load() {
        let calendar = Calendar.current
        var found: [OnThisDay.Year] = []
        for earlierDay in OnThisDay.earlierDays(matching: day, notBefore: earliest) {
            let start = calendar.startOfDay(for: earlierDay)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            // A stay is shown on every day it covers, so one that began earlier has to
            // be fetched to be found — the same week's reach a past day uses.
            let from = calendar.date(byAdding: .day, value: -7, to: start) ?? start
            let descriptor = FetchDescriptor<Visit>(
                predicate: #Predicate { $0.arrival < end && $0.arrival >= from },
                sortBy: [SortDescriptor(\Visit.arrival)]
            )
            guard let rows = try? context.fetch(descriptor) else { continue }
            if let summary = OnThisDay.summarise(rows, on: start) { found.append(summary) }
        }
        years = found
    }
}
