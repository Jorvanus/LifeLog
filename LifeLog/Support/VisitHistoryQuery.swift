import Foundation
import SwiftData

/// The common bounded fetches used by history-facing screens. Keeping predicates
/// here makes a 32,000-row archive a constraint each caller observes by default,
/// rather than an optimisation each caller has to rediscover.
enum VisitHistoryQuery {
    static func day(_ day: Date, calendar: Calendar = .current,
                    includesImported: Bool = true) -> FetchDescriptor<Visit> {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return FetchDescriptor(
            predicate: #Predicate { visit in
                visit.arrival < end && (visit.departure == nil || visit.departure! >= start) &&
                    (includesImported || visit.source != "imported-journal")
            },
            sortBy: [SortDescriptor(\Visit.arrival, order: .reverse)]
        )
    }

    static func month(containing day: Date, calendar: Calendar = .current) -> FetchDescriptor<Visit> {
        let components = calendar.dateComponents([.year, .month], from: day)
        let start = calendar.date(from: components) ?? day
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return range(start..<end)
    }

    static func year(containing day: Date, calendar: Calendar = .current) -> FetchDescriptor<Visit> {
        let components = calendar.dateComponents([.year], from: day)
        let start = calendar.date(from: components) ?? day
        let end = calendar.date(byAdding: .year, value: 1, to: start) ?? start
        return range(start..<end)
    }

    static func place(named name: String, mapsIdentifier: String? = nil, limit: Int = 5_000) -> FetchDescriptor<Visit> {
        let identifier = mapsIdentifier ?? ""
        var descriptor = FetchDescriptor(
            predicate: #Predicate { visit in
                visit.placeName == name || (!identifier.isEmpty && visit.mapsIdentifier == identifier)
            },
            sortBy: [SortDescriptor(\Visit.arrival, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// A Maps identifier is the durable identity for a place. Prefer it whenever a
    /// Saved Place has one; a name-only lookup is retained solely for older rows.
    static func place(mapsIdentifier: String, limit: Int = 5_000) -> FetchDescriptor<Visit> {
        var descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { $0.mapsIdentifier == mapsIdentifier },
            sortBy: [SortDescriptor(\Visit.arrival, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// Legacy names cannot use NameKey inside a SwiftData predicate. Keep their
    /// candidate set bounded before applying that stricter comparison in memory.
    static func legacyPlace(named name: String, limit: Int = 5_000) -> FetchDescriptor<Visit> {
        var descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { $0.placeName == name },
            sortBy: [SortDescriptor(\Visit.arrival, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    static func previous(before boundary: Date, excluding stableID: UUID) -> FetchDescriptor<Visit> {
        var descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { visit in
                visit.stableID != stableID && visit.departure != nil && visit.departure! <= boundary
            },
            sortBy: [SortDescriptor(\Visit.departure, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    static func next(after boundary: Date, excluding stableID: UUID) -> FetchDescriptor<Visit> {
        var descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { visit in visit.stableID != stableID && visit.arrival >= boundary },
            sortBy: [SortDescriptor(\Visit.arrival, order: .forward)]
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    static func activity(named name: String, limit: Int = 5_000) -> FetchDescriptor<Visit> {
        var descriptor = FetchDescriptor(
            predicate: #Predicate { $0.userActivity == name || $0.inferredActivity == name },
            sortBy: [SortDescriptor(\Visit.arrival, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// Text in notes is deliberately excluded from regular history queries. An
    /// explicit search UI may opt into it later; loading Timeline must not do so.
    static func searchPlaces(_ text: String) -> FetchDescriptor<Visit> {
        return FetchDescriptor(predicate: #Predicate { $0.placeName.contains(text) },
                               sortBy: [SortDescriptor(\Visit.arrival, order: .reverse)])
    }

    private static func range(_ range: Range<Date>) -> FetchDescriptor<Visit> {
        let start = range.lowerBound, end = range.upperBound
        return FetchDescriptor(predicate: #Predicate { $0.arrival >= start && $0.arrival < end },
                               sortBy: [SortDescriptor(\Visit.arrival, order: .reverse)])
    }
}
