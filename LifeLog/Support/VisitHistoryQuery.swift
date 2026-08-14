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

    /// The explicit archive search screen's only query. Place and activity are
    /// always searched; notes are opt-in because they are free text with no
    /// prefix structure a query can narrow on, so matching them scans every row's
    /// note text rather than a short label. Ordinary history queries (`day`,
    /// `place`, `activity`, …) never touch `note` at all — this is the one path
    /// that does, and only when the person has explicitly asked for it.
    ///
    /// `localizedStandardContains` is case/diacritic-insensitive, same as every
    /// other free-text match in this codebase (see `PlaceVisitLookup`). It compiles
    /// to a SQLite `LIKE '%text%'`, which cannot use a btree index on any column
    /// regardless of whether one exists — a leading wildcard defeats index range
    /// scans. `fetchLimit`/`fetchOffset` bound the work and give the caller paging;
    /// see `VisitArchiveReaderTests` for the measurement against a 32,000-row
    /// archive that this bound, not a persisted index, is what keeps it fast.
    static func search(_ text: String, includeNotes: Bool, limit: Int, offset: Int = 0) -> FetchDescriptor<Visit> {
        var descriptor: FetchDescriptor<Visit>
        if includeNotes {
            descriptor = FetchDescriptor(
                predicate: #Predicate { visit in
                    visit.placeName.localizedStandardContains(text) ||
                        (visit.userActivity?.localizedStandardContains(text) ?? false) ||
                        visit.inferredActivity.localizedStandardContains(text) ||
                        visit.note.localizedStandardContains(text)
                },
                sortBy: [SortDescriptor(\Visit.arrival, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate { visit in
                    visit.placeName.localizedStandardContains(text) ||
                        (visit.userActivity?.localizedStandardContains(text) ?? false) ||
                        visit.inferredActivity.localizedStandardContains(text)
                },
                sortBy: [SortDescriptor(\Visit.arrival, order: .reverse)]
            )
        }
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        return descriptor
    }

    private static func range(_ range: Range<Date>) -> FetchDescriptor<Visit> {
        let start = range.lowerBound, end = range.upperBound
        return FetchDescriptor(predicate: #Predicate { $0.arrival >= start && $0.arrival < end },
                               sortBy: [SortDescriptor(\Visit.arrival, order: .reverse)])
    }
}
