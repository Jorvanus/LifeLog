import Foundation

/// Travel is a transition between resolved places, not a place of its own.
/// This model is built from post-resolution InsightSegments so walking inside a
/// destination, overlapping callbacks, and synthetic Home/Work commutes follow
/// the same rules as the donut and the rest of Insights.
struct TravelInsights {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case walking = "Walking"
        case vehicle = "Driving / vehicle"
        case flight = "Flight"
        case unknown = "Other / unknown"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .walking: "figure.walk"
            case .vehicle: "car.fill"
            case .flight: "airplane"
            case .unknown: "questionmark"
            }
        }
    }

    struct Trip: Identifiable, Sendable {
        let start: Date
        let end: Date
        let isCommute: Bool
        let mode: Mode

        var id: Date { start }
        var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
        var hours: Double { duration / 3600 }
    }

    struct Summary: Sendable {
        let trips: [Trip]
        let totalHours: Double
        let medianTripMinutes: Double?
        let longTripCount: Int
        let commuteHours: Double
        let nonCommuteHours: Double
        let modeCounts: [Mode: Int]
        let wakingShare: Double?

        var tripCount: Int { trips.count }
        var hasTravel: Bool { !trips.isEmpty }
        /// A few minutes of movement is useful in raw history but should not
        /// compete with the rest of Week Insights as a first-class story.
        var isMeaningful: Bool {
            commuteHours > 0 || totalHours * 60 >= 15 || longTripCount > 0
        }
        var commuteDays: Int {
            let calendar = Calendar.current
            return Set(trips.filter(\.isCommute).map { calendar.startOfDay(for: $0.start) }).count
        }
        var averageCommuteMinutes: Double? {
            let commuteTrips = trips.filter(\.isCommute)
            guard !commuteTrips.isEmpty else { return nil }
            return commuteTrips.reduce(0) { $0 + $1.duration } / Double(commuteTrips.count) / 60
        }
        // Compatibility names keep existing Year aggregation callers readable
        // while the reusable summary exposes the more precise fields above.
        var hours: Double { totalHours }
        var tripsTotal: Int { trips.count }
        var longTrips: Int { longTripCount }
        var flights: Int { modeCounts[.flight, default: 0] }

        static let empty = Summary(trips: [], totalHours: 0, medianTripMinutes: nil,
                                   longTripCount: 0, commuteHours: 0,
                                   nonCommuteHours: 0, modeCounts: [:], wakingShare: nil)
    }

    /// A two-hour transition is long enough to distinguish a meaningful journey
    /// from the short movement that should remain an Insights-only detail.
    static let longTripDuration: TimeInterval = 2 * 60 * 60
    static let segmentMergeGap: TimeInterval = 10 * 60

    static func make(from segments: [InsightSegment]) -> Summary {
        let travelSegments = segments
            .filter { !$0.isUnlogged && isTravel($0) }
            .sorted { $0.start < $1.start }
        let trips = makeTrips(from: travelSegments)
        let durations = trips.map(\.duration).sorted()
        let median: TimeInterval?
        if durations.isEmpty {
            median = nil
        } else if durations.count.isMultiple(of: 2) {
            median = (durations[durations.count / 2 - 1] + durations[durations.count / 2]) / 2
        } else {
            median = durations[durations.count / 2]
        }
        let total = trips.reduce(0) { $0 + $1.duration }
        let commute = trips.filter(\.isCommute).reduce(0) { $0 + $1.duration }
        let nonSleep = segments.filter { !$0.isUnlogged && !$0.isSleep }
            .reduce(0) { $0 + $1.hours * 3600 }
        var modeCounts: [Mode: Int] = [:]
        for trip in trips { modeCounts[trip.mode, default: 0] += 1 }

        return Summary(
            trips: trips,
            totalHours: total / 3600,
            medianTripMinutes: median.map { $0 / 60 },
            longTripCount: trips.filter { $0.duration >= longTripDuration }.count,
            commuteHours: commute / 3600,
            nonCommuteHours: (total - commute) / 3600,
            modeCounts: modeCounts,
            wakingShare: nonSleep > 0 ? total / nonSleep : nil
        )
    }

    private static func isTravel(_ segment: InsightSegment) -> Bool {
        if segment.category.caseInsensitiveCompare(CommuteDetection.categoryName) == .orderedSame {
            return true
        }
        guard let visit = segment.visit else { return false }
        if isExplicitFlight(visit) { return true }
        guard segment.category.caseInsensitiveCompare("Travel") == .orderedSame else { return false }
        // Ordinary places can be categorised as Travel (an airport, hotel, or
        // rental desk) without being transition time. Keep those place/activity
        // rows out unless the record is actual movement or explicitly says flight.
        return ActivityLocationPolicy.isMovementActivity(visit) || segment.placeName == nil
    }

    private static func isExplicitFlight(_ visit: Visit) -> Bool {
        let text = "\(visit.activity) \(visit.inferredActivity)".lowercased()
        return text.contains("flight") || text.contains("plane")
    }

    private static func makeTrips(from segments: [InsightSegment]) -> [Trip] {
        var result: [Trip] = []
        for segment in segments {
            guard let last = result.last else {
                result.append(trip(for: segment))
                continue
            }
            // Motion import can deliver adjacent fragments. Fuse only a short
            // transition gap; a destination stay between two journeys remains
            // a real trip boundary.
            if segment.start.timeIntervalSince(last.end) <= segmentMergeGap {
                result[result.count - 1] = Trip(
                    start: min(last.start, segment.start),
                    end: max(last.end, segment.end),
                    isCommute: last.isCommute || isCommute(segment),
                    mode: strongest(last.mode, mode(for: segment))
                )
            } else {
                result.append(trip(for: segment))
            }
        }
        return result
    }

    private static func trip(for segment: InsightSegment) -> Trip {
        Trip(start: segment.start, end: segment.end, isCommute: isCommute(segment), mode: mode(for: segment))
    }

    private static func isCommute(_ segment: InsightSegment) -> Bool {
        segment.category.caseInsensitiveCompare(CommuteDetection.categoryName) == .orderedSame
    }

    private static func mode(for segment: InsightSegment) -> Mode {
        guard let visit = segment.visit else { return .unknown }
        let text = "\(visit.activity) \(visit.inferredActivity) \(visit.placeName)".lowercased()
        if text.contains("flight") || text.contains("plane") { return .flight }
        if ActivityLocationPolicy.isWalkingActivity(visit) { return .walking }
        if visit.source == "motion" && text.contains("travel") { return .vehicle }
        if text.contains("automotive") || text.contains("vehicle") || text.contains("driv") || text.contains("car") {
            return .vehicle
        }
        return .unknown
    }

    private static func strongest(_ first: Mode, _ second: Mode) -> Mode {
        let rank: [Mode: Int] = [.unknown: 0, .walking: 1, .vehicle: 2, .flight: 3]
        return (rank[second] ?? 0) > (rank[first] ?? 0) ? second : first
    }
}
