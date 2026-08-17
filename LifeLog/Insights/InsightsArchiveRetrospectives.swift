import Foundation
import SwiftData

/// Everywhere Insights reaches past the selected period into the whole
/// archive — place history, year-over-year comparisons, and Year's list of
/// places visited before this year — all through the one shared
/// `VisitArchiveReader` actor, so this work runs off the main actor instead
/// of blocking the interaction path.
///
/// Extracted from `InsightsView` so these archive-scale reads can be
/// exercised without a live `View`. `InsightsView` still owns `context` and
/// decides when a retrospective is needed; this owns the reader instance and
/// the three queries built on it.
@MainActor @Observable
final class InsightsArchiveRetrospectives {
    private var archiveReader: VisitArchiveReader?
    /// True while Year's "new this year"/"not visited this year" comparison is
    /// still reading the archive — see `YearPlaceStoryCard.placesLoading`.
    var annualPlacesLoading = false

    func archive(context: ModelContext) -> VisitArchiveReader {
        let reader = archiveReader ?? VisitArchiveReader(modelContainer: context.container)
        archiveReader = reader
        return reader
    }

    /// Every visit at places matching this name, unscoped by date — the archive
    /// retrospectives need to know what happened before the window being looked
    /// at, not just within it. Bounded to history before the selected period,
    /// scoped the same way as the visible place story.
    func placeHistory(matching name: String, before end: Date, scope: InsightsScope,
                      context: ModelContext) async -> [PlaceVisitOccurrence] {
        do {
            return try await archive(context: context).placeOccurrences(matching: name, before: end, scope: scope)
        } catch is CancellationError {
            return []
        } catch {
            Diagnostics.record(error, context: context, subsystem: "Insights",
                               operation: "place retrospective fetch", severity: "warning")
            return []
        }
    }

    /// This period's total against the same period a year ago. Already a narrow,
    /// date-scoped fetch rather than a whole-archive one; run on the archive
    /// actor so it never blocks the interaction path even so.
    func yearOverYearHighlight(anchorDate: Date, window: InsightWindow, loggedHours: Double,
                               scope: InsightsScope, now: Date, context: ModelContext) async -> DayHighlight? {
        guard let yearAgoAnchor = Calendar.current.date(byAdding: .year, value: -1, to: anchorDate) else { return nil }
        let yearAgoInterval = window.interval(containing: yearAgoAnchor)
        do {
            let yearAgoHours = try await archive(context: context).loggedHours(in: yearAgoInterval, scope: scope, now: now)
            return ArchiveRetrospectives.yearOverYear(loggedHours: loggedHours,
                                                       yearAgoHours: yearAgoHours, window: window)
        } catch is CancellationError {
            return nil
        } catch {
            Diagnostics.record(error, context: context, subsystem: "Insights",
                               operation: "year-over-year fetch", severity: "warning")
            return nil
        }
    }

    /// Distinct display names of places visited before this year, scoped the
    /// same way as the visible story. Runs on the shared archive-reader actor
    /// — this used to be a synchronous whole-archive fetch on the main actor,
    /// exactly the "unbounded history read on the interaction path" this
    /// screen otherwise avoids. See `VisitArchiveReader.historicalPlaceNames`
    /// for why it stays a full scan rather than a paged query: a complete
    /// distinct-names answer has no natural early stop, and the 32,000-row
    /// measurement in `VisitArchiveReaderTests` is what justifies running it
    /// as a background full scan instead of adding a persisted index.
    func annualHistoricalPlaces(before start: Date, scope: InsightsScope, generation: Int,
                                context: ModelContext) async -> Set<String> {
        do {
            return try await archive(context: context).historicalPlaceNames(before: start, scope: scope,
                                                                             generation: generation)
        } catch is CancellationError {
            return []
        } catch {
            Diagnostics.record(error, context: context, subsystem: "Insights",
                               operation: "annual historical places fetch", severity: "warning")
            return []
        }
    }
}
