import Foundation
import SwiftUI
import MapKit

/// Everything Insights draws for one window, worked out in a single pass, plus the
/// per-window model types it is built from.
///
/// This was roughly 250 lines of segmentation, slicing, comparison and weekday
/// logic living `private` inside the Insights view, which made it the largest
/// piece of the project with no test coverage at all. Nothing here has changed
/// behaviour — it is the same code, now reachable from a test.
@MainActor
struct InsightsSnapshot {
    let generatedAt: Date
    let analysisInterval: DateInterval
    let segments: [InsightSegment]
    let slices: [TimeSlice]
    let placeTotals: [PlaceTotal]
    let comparisons: [TrendComparison]
    let loggedHours: Double
    let totalHours: Double
    let mappablePlaces: [PlaceTotal]
    let mapRegion: MKCoordinateRegion
    let mapID: Int
    let weekdayPatterns: [WeekdayPattern]
    let awayFromHomeHours: Double
    let unloggedHours: Double
    let provisionalCount: Int
    let supersededCount: Int

    static let empty = InsightsSnapshot(
        generatedAt: .distantPast,
        analysisInterval: DateInterval(start: .distantPast, duration: 0),
        segments: [], slices: [], placeTotals: [], comparisons: [],
        loggedHours: 0, totalHours: 0, mappablePlaces: [],
        mapRegion: MKCoordinateRegion(
            center: .init(latitude: -27.47, longitude: 153.03),
            span: .init(latitudeDelta: 0.2, longitudeDelta: 0.2)
        ),
        mapID: 0, weekdayPatterns: WeekdayPattern.empty,
        awayFromHomeHours: 0, unloggedHours: 0, provisionalCount: 0, supersededCount: 0
    )

    /// Where home is, as a place rather than a word.
    ///
    /// "Home" used to be a substring test on the place name or activity, so anywhere
    /// containing those four letters — a Homemaker Centre, a suburb called Homebush —
    /// counted as being home, while a home saved under any other name did not. The
    /// Saved Place has a coordinate and a radius, which is a fact.
    struct HomePlace: Equatable, Sendable {
        let latitude: Double
        let longitude: Double
        let radius: CLLocationDistance

        init(latitude: Double, longitude: Double, radius: CLLocationDistance) {
            self.latitude = latitude
            self.longitude = longitude
            self.radius = max(radius, 1)
        }

        init?(_ place: SavedPlace?) {
            guard let place else { return nil }
            self.init(latitude: place.latitude, longitude: place.longitude, radius: place.radius)
        }

        func contains(_ visit: Visit) -> Bool {
            guard visit.latitude != 0 || visit.longitude != 0 else { return false }
            return CLLocation(latitude: latitude, longitude: longitude)
                .distance(from: CLLocation(latitude: visit.latitude, longitude: visit.longitude)) <= radius
        }
    }

    /// No guessing from wording: without a place explicitly given the Home role,
    /// nothing is home. A name/activity substring test used to make "Homemaker
    /// Centre" or a suburb called Homebush count as home, and a real home saved
    /// under any other name not count at all.
    private static func isHome(_ visit: Visit, home: HomePlace?) -> Bool {
        guard let home else { return false }
        return home.contains(visit)
    }

    static func make(visits: [Visit], window: InsightWindow, anchorDate: Date, now: Date,
                     home: HomePlace? = nil, savedPlaces: [SavedPlace] = []) -> InsightsSnapshot {
        let interval = window.interval(containing: anchorDate)
        // Current periods end “now”; otherwise future time would dominate the donut as unlogged.
        let analysisInterval = interval.contains(now)
            ? DateInterval(start: interval.start, end: min(interval.end, now))
            : interval
        let previousInterval = window.previousComparisonInterval(for: analysisInterval)

        // Location visits are prepared once and reused by both periods. This avoids an
        // all-history scan for each individual walking or travel record.
        let locationVisits = visits.filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
        let segments = makeSegments(
            visits: visits,
            locationVisits: locationVisits,
            range: analysisInterval,
            now: now,
            savedPlaces: savedPlaces
        )
        let previousSegments = makeSegments(
            visits: visits,
            locationVisits: locationVisits,
            range: previousInterval,
            now: now,
            savedPlaces: savedPlaces
        )
        let slices = makeSlices(from: segments)
        let previousSlices = makeSlices(from: previousSegments)
        let placeTotals = makePlaceTotals(segments: segments)
        let mappablePlaces = placeTotals.filter { $0.latitude != 0 || $0.longitude != 0 }
        let loggedHours = segments.filter { !$0.isUnlogged }.reduce(0) { $0 + $1.hours }
        // Sleep is imported as its own activity ("Sleeping" at place "Sleep"), and it
        // wins the segment slot over the overnight Home stay it sits inside because it
        // is the shorter, completed record. Neither of its labels mentions "home", so
        // every night slept in your own bed was counted as time away from it.
        //
        // Only device records are rescued this way. They describe what the body was
        // doing and carry no place of their own, so the surrounding stay is the only
        // thing that knows where it happened. A location visit states its own place —
        // it is away from home whatever else claims those minutes.
        let homeVisits = locationVisits.filter { isHome($0, home: home) }
        let awayFromHomeHours = segments.filter { segment in
            guard !segment.isUnlogged else { return false }
            if let visit = segment.visit {
                if isHome(visit, home: home) { return false }
                guard ActivityLocationPolicy.isDeviceActivity(visit) else { return true }
                return !homeVisits.contains { home in
                    home.arrival < segment.end && (home.departure ?? now) > segment.start
                }
            }
            // No visit behind the segment, so its wording is all there is to read.
            return !segment.activity.localizedCaseInsensitiveContains("home")
                && !(segment.placeName?.localizedCaseInsensitiveContains("home") ?? false)
        }.reduce(0) { $0 + $1.hours }
        let unloggedHours = segments.filter(\.isUnlogged).reduce(0) { $0 + $1.hours }
        let periodVisits = visits.filter { $0.overlaps(analysisInterval, now: now) }

        return InsightsSnapshot(
            generatedAt: now,
            analysisInterval: analysisInterval,
            segments: segments,
            slices: slices,
            placeTotals: placeTotals,
            comparisons: makeComparisons(current: slices, previous: previousSlices),
            loggedHours: loggedHours,
            totalHours: analysisInterval.duration / 3600,
            mappablePlaces: mappablePlaces,
            mapRegion: makeMapRegion(for: mappablePlaces),
            mapID: makeMapID(for: mappablePlaces),
            weekdayPatterns: makeWeekdayPatterns(from: segments),
            awayFromHomeHours: awayFromHomeHours,
            unloggedHours: unloggedHours,
            provisionalCount: periodVisits.filter { $0.resolutionState == .provisional }.count,
            supersededCount: periodVisits.filter { $0.resolutionState == .superseded }.count
        )
    }

    /// Hours per category over an arbitrary stretch of time.
    ///
    /// Exposed so the long-run trends can bucket history into weeks and still resolve
    /// overlapping stays exactly the way the donut does. Counting a week by adding up
    /// visit durations instead would double-count every night that an open stay and a
    /// sleep record both claim, and the two charts would disagree about the same day.
    ///
    /// `commutes` lets a caller resolving many ranges over the same `visits` (weekly
    /// trend buckets, for instance) compute it once instead of once per range —
    /// `CommuteDetection.commutes` sorts the whole array and does not depend on
    /// `range` at all, so recomputing it per week is pure waste. `nil` computes it
    /// fresh, unchanged from before.
    // nonisolated so InsightsTrendAggregator can call this from inside its own
    // @ModelActor isolation — it touches no UI state, only the Visit array it's given.
    nonisolated static func categoryHours(visits: [Visit], range: DateInterval, now: Date,
                                          commutes: [Commute]? = nil, savedPlaces: [SavedPlace] = []) -> [String: Double] {
        let locationVisits = visits.filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
        let segments = makeSegments(visits: visits, locationVisits: locationVisits,
                                    range: range, now: now, precomputedCommutes: commutes, savedPlaces: savedPlaces)
        var totals: [String: Double] = [:]
        for segment in segments where !segment.isUnlogged {
            totals[segment.category, default: 0] += segment.hours
        }
        return totals
    }

    /// Builds the weekday chart from history independent of the Insights window.
    /// Each weekday is averaged over the number of occurrences in `range`, so the
    /// chart describes a usual week rather than making a month look four times busier
    /// than a week simply because it contains four Mondays.
    nonisolated static func weekdayPatterns(visits: [Visit], range: DateInterval, now: Date,
                                            commutes: [Commute]? = nil, savedPlaces: [SavedPlace] = []) -> [WeekdayPattern] {
        let locationVisits = visits.filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
        let segments = makeSegments(visits: visits, locationVisits: locationVisits,
                                    range: range, now: now, precomputedCommutes: commutes, savedPlaces: savedPlaces)
        return makeWeekdayPatterns(from: segments, weekdayOccurrences: weekdayOccurrences(in: range))
    }

    // Internal rather than private: VisitSuggestion builds its gaps from this same
    // computation, so "unlogged" means one thing everywhere it's reported rather
    // than two definitions that can silently disagree.
    nonisolated static func makeSegments(visits: [Visit], locationVisits: [Visit],
                                         range: DateInterval, now: Date,
                                         precomputedCommutes: [Commute]? = nil,
                                         savedPlaces: [SavedPlace] = []) -> [InsightSegment] {
        let orderedVisits = visits
            .filter { $0.overlaps(range, now: now) && $0.resolutionState != .ignored && $0.resolutionState != .superseded }
            .filter { ActivityLocationPolicy.shouldShowInInsights($0, locationVisits: locationVisits, now: now) }
        // Imported journals and delayed Core Location callbacks can contain an old
        // open stay that overlaps several completed destinations. Resolve the day in
        // small boundary slices so a broad open stay cannot hide a real visit such as
        // a shop stop; completed/shorter visits win each overlapping slice.
        var boundaries = Set([range.start, range.end])
        for visit in orderedVisits {
            boundaries.insert(max(visit.arrival, range.start))
            boundaries.insert(min(visit.departure ?? now, range.end))
        }
        let times = boundaries.sorted()
        // Avoid scanning the entire archive for every boundary. The previous
        // implementation was O(boundaries × visits), which made a year with
        // 6,000 rows take several seconds. Keep only visits active at the
        // current boundary while walking the already sorted timeline.
        // Derived once for the window rather than per boundary slice.
        let commutes = precomputedCommutes ?? CommuteDetection.commutes(in: visits, savedPlaces: savedPlaces, now: now)
        let arrivalSorted = orderedVisits.sorted { $0.arrival < $1.arrival }
        var nextArrival = 0
        var activeVisits: [Visit] = []
        var result: [InsightSegment] = []
        var gapIndex = 0

        for pair in zip(times, times.dropFirst()) {
            let start = pair.0
            let end = pair.1
            guard end > start else { continue }
            while nextArrival < arrivalSorted.count && arrivalSorted[nextArrival].arrival <= start {
                activeVisits.append(arrivalSorted[nextArrival])
                nextArrival += 1
            }
            activeVisits.removeAll { ($0.departure ?? now) <= start }
            let midpoint = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
            let matching = activeVisits.filter {
                $0.arrival <= midpoint && ($0.departure ?? now) > midpoint
            }
            // A gap between home and work is not missing data — it is the journey
            // between them, so it is counted as commuting rather than reported as
            // time the person failed to log.
            if matching.isEmpty, let commute = CommuteDetection.commute(covering: midpoint, in: commutes) {
                result.append(.commute(commute, from: start, to: end))
                continue
            }
            if let visit = matching.min(by: { left, right in
                let leftCompleted = left.departure != nil
                let rightCompleted = right.departure != nil
                if leftCompleted != rightCompleted { return leftCompleted }
                let leftDuration = (left.departure ?? now).timeIntervalSince(left.arrival)
                let rightDuration = (right.departure ?? now).timeIntervalSince(right.arrival)
                if leftDuration != rightDuration { return leftDuration < rightDuration }
                return left.arrival > right.arrival
            }) {
                result.append(.visit(visit, visibleFrom: start, visibleTo: end, now: now))
            } else {
                result.append(.unlogged(index: gapIndex, from: start, to: end))
                gapIndex += 1
            }
        }
        return result
    }

    private static func makeSlices(from segments: [InsightSegment]) -> [TimeSlice] {
        let grouped = Dictionary(grouping: segments.filter { !$0.isUnlogged }, by: \.category)
        var values = grouped.map { name, items in
            TimeSlice(name: name, hours: items.reduce(0) { $0 + $1.hours },
                      color: insightColor(for: name), symbol: insightSymbol(for: name), isUnlogged: false)
        }
        .filter { $0.hours > 0.01 }
        .sorted { $0.hours > $1.hours }
        let unlogged = segments.filter(\.isUnlogged).reduce(0) { $0 + $1.hours }
        if unlogged > 0.01 {
            values.append(TimeSlice(name: "Unlogged", hours: unlogged, color: .gray.opacity(0.35),
                                    symbol: "moon.zzz.fill", isUnlogged: true))
        }
        return values
    }

    /// Built from the same post-resolution `segments` the donut and `sliceRows`
    /// read, not from raw visit durations. A place visited twice with overlapping
    /// records (a corrected duplicate callback, say) must not count that overlap
    /// twice just because this total is grouped by place instead of by category.
    private static func makePlaceTotals(segments: [InsightSegment]) -> [PlaceTotal] {
        let matching = segments.filter { segment in
            guard !segment.isUnlogged, segment.placeName != nil,
                  let visit = segment.visit else { return false }
            return ActivityLocationPolicy.isLocationVisit(visit)
        }
        return Dictionary(grouping: matching) { $0.placeName! }.compactMap { name, items in
            guard let first = items.first else { return nil }
            return PlaceTotal(
                name: name, category: first.category, activity: first.activity,
                latitude: first.visit?.latitude ?? 0, longitude: first.visit?.longitude ?? 0,
                hours: items.reduce(0) { $0 + $1.hours }
            )
        }.sorted { $0.hours > $1.hours }
    }

    private static func makeComparisons(current: [TimeSlice], previous: [TimeSlice]) -> [TrendComparison] {
        let currentValues = Dictionary(uniqueKeysWithValues: current.filter { !$0.isUnlogged }.map { ($0.name, $0.hours) })
        let previousValues = Dictionary(uniqueKeysWithValues: previous.filter { !$0.isUnlogged }.map { ($0.name, $0.hours) })
        return Set(currentValues.keys).union(previousValues.keys).map { name in
            TrendComparison(
                name: name,
                hours: currentValues[name, default: 0],
                previousHours: previousValues[name, default: 0],
                delta: currentValues[name, default: 0] - previousValues[name, default: 0]
            )
        }
        .filter { abs($0.delta) >= 0.25 }
        .sorted { abs($0.delta) > abs($1.delta) }
    }

    /// What each weekday is usually spent doing, awake.
    ///
    /// Sleep is left out on purpose. It is the largest block in almost every day and
    /// barely varies, so including it flattened the bars into seven near-identical
    /// columns and buried the thing this chart exists to show — how the waking days
    /// differ from one another. Sleep has its own reading elsewhere.
    ///
    /// Grouped by category rather than by activity so the bars carry the same colours
    /// as the donut and Top Activities, and one day's "Shopping" stacks with another's.
    nonisolated private static func makeWeekdayPatterns(from segments: [InsightSegment],
                                            weekdayOccurrences: [Int]? = nil) -> [WeekdayPattern] {
        let calendar = Calendar.current
        var totals = Array(repeating: 0.0, count: 7)
        var activities = Array(repeating: [String: Double](), count: 7)
        for segment in segments where !segment.isUnlogged && !segment.isSleep {
            let weekday = max(1, min(7, calendar.component(.weekday, from: segment.start))) - 1
            totals[weekday] += segment.hours
            activities[weekday][segment.category, default: 0] += segment.hours
        }
        return (0..<7).map { index in
            let divisor = Double(weekdayOccurrences?[index] ?? 1)
            let averageActivities = activities[index].mapValues { $0 / max(divisor, 1) }
            let top = averageActivities.max { $0.value < $1.value }
            let breakdown = averageActivities
                .map { WeekdayActivity(weekday: index + 1, category: $0.key, hours: $0.value) }
                .filter { $0.hours > 0.01 }
                .sorted { $0.hours > $1.hours }
            return WeekdayPattern(weekday: index + 1, hours: totals[index] / max(divisor, 1),
                                  topActivity: top?.key ?? "Visiting", topHours: top?.value ?? 0,
                                  activities: breakdown)
        }
    }

    nonisolated private static func weekdayOccurrences(in range: DateInterval, calendar: Calendar = .current) -> [Int] {
        var counts = Array(repeating: 0, count: 7)
        var day = calendar.startOfDay(for: range.start)
        while day < range.end {
            let weekday = calendar.component(.weekday, from: day) - 1
            counts[weekday] += 1
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = nextDay
        }
        return counts
    }

    private static func makeMapRegion(for places: [PlaceTotal]) -> MKCoordinateRegion {
        let latitudes = places.map(\.latitude)
        let longitudes = places.map(\.longitude)
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
              let minLon = longitudes.min(), let maxLon = longitudes.max() else {
            return empty.mapRegion
        }
        return MKCoordinateRegion(
            center: .init(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: .init(latitudeDelta: max(0.01, (maxLat - minLat) * 1.5),
                        longitudeDelta: max(0.01, (maxLon - minLon) * 1.5))
        )
    }

    private static func makeMapID(for places: [PlaceTotal]) -> Int {
        var hasher = Hasher()
        for place in places {
            hasher.combine(place.name)
            hasher.combine(place.latitude)
            hasher.combine(place.longitude)
        }
        return hasher.finalize()
    }
}

/// Main-actor cache for UI-ready snapshots. SwiftData models stay on the main
/// actor; the companion actor only owns the invalidation generation, keeping
/// background imports from racing this cache.
@MainActor
final class InsightsSnapshotCache {
    private var key: String?
    private var generation = -1
    private var value = InsightsSnapshot.empty

    func snapshot(key: String, generation: Int, build: () -> InsightsSnapshot) -> InsightsSnapshot {
        if self.key == key, self.generation == generation { return value }
        let rebuilt = build()
        self.key = key
        self.generation = generation
        value = rebuilt
        return rebuilt
    }
}

struct TimeSlice: Identifiable {
    var id: String { "\(isUnlogged ? "gap" : "logged"):\(name)" }
    let name: String
    let hours: Double
    let color: Color
    let symbol: String
    let isUnlogged: Bool
}

enum InsightSegmentID: Hashable {
    case visit(ObjectIdentifier)
    case unlogged(Int)
    case commute(Date)
}

struct InsightSegment: Identifiable {
    let id: InsightSegmentID
    let visit: Visit?
    let category: String
    let activity: String
    let placeName: String?
    let start: Date
    let end: Date
    let hours: Double
    let color: Color
    let symbol: String
    let isUnlogged: Bool
    let isLive: Bool

    var isSleep: Bool {
        category.localizedCaseInsensitiveContains("sleep") || activity.localizedCaseInsensitiveContains("sleep")
    }

    static func visit(_ visit: Visit, visibleFrom: Date, visibleTo: Date, now: Date) -> InsightSegment {
        let category = visit.insightCategory
        return InsightSegment(
            id: .visit(ObjectIdentifier(visit)), visit: visit, category: category,
            activity: visit.suspectedActivity, placeName: visit.displayPlaceName,
            start: visibleFrom, end: visibleTo,
            hours: visibleTo.timeIntervalSince(visibleFrom) / 3600,
            color: insightColor(for: category), symbol: insightSymbol(for: category),
            isUnlogged: false, isLive: visit.departure == nil && visibleTo >= now
        )
    }

    /// The journey between home and work. It has no visit behind it because nothing
    /// is stored: this is the interval between two real arrivals, counted rather than
    /// recorded, so it cannot outlive the stays that define it.
    static func commute(_ commute: Commute, from start: Date, to end: Date) -> InsightSegment {
        InsightSegment(
            id: .commute(commute.start), visit: nil, category: CommuteDetection.categoryName,
            activity: commute.direction.label, placeName: nil, start: start, end: end,
            hours: end.timeIntervalSince(start) / 3600,
            color: insightColor(for: CommuteDetection.categoryName),
            symbol: insightSymbol(for: CommuteDetection.categoryName),
            isUnlogged: false, isLive: false
        )
    }

    static func unlogged(index: Int, from start: Date, to end: Date) -> InsightSegment {
        InsightSegment(
            id: .unlogged(index), visit: nil, category: "Unlogged",
            activity: "Unlogged", placeName: nil, start: start, end: end,
            hours: end.timeIntervalSince(start) / 3600,
            color: .gray.opacity(0.35), symbol: "moon.zzz.fill",
            isUnlogged: true, isLive: false
        )
    }
}

/// One row a slice's detail screen (`InsightSliceEditor`) can show: either a
/// Visit's own post-resolution contribution, or -- for commute time, which has
/// no backing Visit -- the commute segment itself. Grouped by `InsightSegmentID`
/// rather than by `Visit` alone so a commute row (identified by its start date,
/// not an object identity) groups the same way a visit row does.
struct SliceRow: Identifiable {
    let id: InsightSegmentID
    let visit: Visit?
    let activity: String
    let placeName: String?
    let start: Date
    let end: Date
    /// This row's actual contribution to the selected slice, in hours, after
    /// overlap resolution -- the sum of every segment this record won. Never a
    /// raw `Visit.duration`: two overlapping records (an overnight Home stay
    /// under a Sleep record, a duplicate automatic callback) would each claim
    /// the same minutes and the rows would add up to more than the slice total.
    let hours: Double
    /// True when this row's own recorded span extends beyond what it won here
    /// -- part of its time was awarded to another, competing record. Lets the
    /// UI say so rather than showing a number smaller than the visit's own
    /// arrival/departure would suggest, with no explanation.
    let isPartial: Bool
}

extension InsightsSnapshot {
    /// The one place slice detail rows are computed, for both the category
    /// (donut) and place entry points into `InsightSliceEditor`. Reuses the
    /// exact `InsightSegment`s the donut and its header total are built from --
    /// grouping and summing already-resolved, non-overlapping slivers -- so a
    /// row's hours can never disagree with what produced the header.
    private static func sliceRows(matching predicate: (InsightSegment) -> Bool, in segments: [InsightSegment],
                                  interval: DateInterval, now: Date) -> [SliceRow] {
        var order: [InsightSegmentID] = []
        var byID: [InsightSegmentID: [InsightSegment]] = [:]
        for segment in segments where !segment.isUnlogged && predicate(segment) {
            if byID[segment.id] == nil { order.append(segment.id) }
            byID[segment.id, default: []].append(segment)
        }
        return order.compactMap { id -> SliceRow? in
            guard let group = byID[id], let first = group.first else { return nil }
            let hours = group.reduce(0) { $0 + $1.hours }
            let isPartial = first.visit.map { hours < $0.duration(in: interval, now: now) / 3600 - 0.01 } ?? false
            return SliceRow(
                id: id, visit: first.visit, activity: first.activity, placeName: first.placeName,
                start: group.map(\.start).min() ?? first.start, end: group.map(\.end).max() ?? first.end,
                hours: hours, isPartial: isPartial
            )
        }.sorted { $0.start > $1.start }
    }

    /// Rows for a donut/category slice: every segment whose category matches it.
    static func sliceRows(forCategory name: String, segments: [InsightSegment],
                          interval: DateInterval, now: Date = .now) -> [SliceRow] {
        sliceRows(matching: { $0.category == name }, in: segments, interval: interval, now: now)
    }

    /// Rows for a place total: every segment at that place. `makePlaceTotals`
    /// already restricts itself to location-visit segments with a place name, so
    /// matching on `placeName` alone cannot pick up an unrelated device segment
    /// (Sleep, Travel) that merely shares a category with something at the place.
    static func sliceRows(forPlace name: String, segments: [InsightSegment],
                          interval: DateInterval, now: Date = .now) -> [SliceRow] {
        sliceRows(matching: { $0.placeName == name }, in: segments, interval: interval, now: now)
    }

    /// The Day summary's own small aggregates -- built from the same resolved
    /// `segments` as everything else here, never a second pass over raw visits.

    /// Every category's hours in one pass, for a caller (the Week scorecard,
    /// the rolling-baseline comparison) that needs more than one category out
    /// of segments already built for the period being looked at — reading this
    /// off `snapshot.segments` is what keeps "this week's" numbers consistent
    /// with the donut and Timeline without a second pass over raw visits.
    static func categoryHours(in segments: [InsightSegment]) -> [String: Double] {
        var totals: [String: Double] = [:]
        for segment in segments where !segment.isUnlogged {
            totals[segment.category, default: 0] += segment.hours
        }
        return totals
    }

    /// Journey time: Travel (device-sourced movement) and Commute (the synthesised
    /// gap between Home and Work) are two different categories today, but both
    /// answer "how much of the day was spent getting somewhere."
    static func travelHours(in segments: [InsightSegment]) -> Double {
        let totals = categoryHours(in: segments)
        return (totals["Travel"] ?? 0) + (totals[CommuteDetection.categoryName] ?? 0)
    }

    /// Every category `ActivityCatalog` groups under "Fitness" — a workout
    /// summary line without a second HealthKit round-trip, since a walk, run, or
    /// tracked workout already arrived as a visit and was already categorised.
    static func fitnessHours(in segments: [InsightSegment]) -> Double {
        categoryHours(in: segments)["Fitness"] ?? 0
    }

    /// Unlogged stretches worth a person's attention: long enough that "nothing
    /// recorded" is more likely a real gap than a moment between two callbacks,
    /// and already over -- there is nothing to say yet about the part of today
    /// that has not happened.
    static func meaningfulGaps(in segments: [InsightSegment], before now: Date,
                               minimumHours: Double = 0.5) -> [InsightSegment] {
        segments.filter { $0.isUnlogged && $0.end <= now && $0.hours >= minimumHours }
            .sorted { $0.hours > $1.hours }
    }

    /// The week's commute, only once there is enough of it to call a pattern.
    struct WeekCommuteSummary {
        let days: Int
        let totalHours: Double
        let averageMinutes: Double
        /// This week's total commute hours against the rolling baseline for the
        /// same "Commute" category — `nil` when there isn't a real baseline yet
        /// (mirrors `InsightsTrends.message`'s own "not enough history" guard).
        let changeFromUsual: Double?
    }

    /// `CommuteDetection` carries no confidence of its own — this is the one
    /// place that gates on there being enough of a pattern to call a summary
    /// rather than a single coincidental day. Two distinct calendar days is a
    /// deliberately low bar: a single one-off commute is a data point, not
    /// something worth characterising as "the commute."
    static let minimumConfidentCommuteDays = 2

    static func weekCommuteSummary(commutes: [Commute], weekInterval: DateInterval,
                                   baselineHours: Double?) -> WeekCommuteSummary? {
        let weekCommutes = commutes.filter { $0.start >= weekInterval.start && $0.start < weekInterval.end }
        let days = Set(weekCommutes.map { Calendar.current.startOfDay(for: $0.start) })
        guard days.count >= minimumConfidentCommuteDays else { return nil }
        let totalHours = weekCommutes.reduce(0) { $0 + $1.duration } / 3600
        let averageMinutes = totalHours * 60 / Double(weekCommutes.count)
        let changeFromUsual = baselineHours.flatMap { $0 > 0 ? totalHours - $0 : nil }
        return WeekCommuteSummary(days: days.count, totalHours: totalHours,
                                  averageMinutes: averageMinutes, changeFromUsual: changeFromUsual)
    }
}


struct PlaceTotal: Identifiable {
    var id: String { name }
    let name: String
    let category: String
    let activity: String
    let latitude: Double
    let longitude: Double
    let hours: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

struct TrendComparison: Identifiable {
    var id: String { name }
    let name: String
    let hours: Double
    let previousHours: Double
    let delta: Double
    func message(window: InsightWindow) -> String {
        let direction = delta >= 0 ? "more" : "less"
        let percentage = previousHours > 0 ? " (\(Int((abs(delta) / previousHours * 100).rounded()))%)" : " (new)"
        return "You spent \(formatHours(abs(delta)))\(percentage) \(direction) on \(name.lowercased()) this \(window.title.lowercased())."
    }
}

/// One category's share of one weekday, which is the unit a stacked bar is drawn from.
struct WeekdayActivity: Identifiable, Hashable {
    let weekday: Int
    let category: String
    let hours: Double
    var id: String { "\(weekday):\(category)" }
    var color: Color { insightColor(for: category) }
    var symbol: String { insightSymbol(for: category) }
}

struct WeekdayPattern: Identifiable {
    let weekday: Int
    /// Waking hours only — see `InsightsSnapshot.makeWeekdayPatterns`.
    let hours: Double
    let topActivity: String
    let topHours: Double
    let activities: [WeekdayActivity]
    var id: Int { weekday }
    var shortName: String {
        Calendar.current.shortWeekdaySymbols[(weekday - 1) % 7]
    }
    var fullName: String {
        Calendar.current.weekdaySymbols[(weekday - 1) % 7]
    }
    static let empty = (1...7).map {
        WeekdayPattern(weekday: $0, hours: 0, topActivity: "Visiting", topHours: 0, activities: [])
    }
}

extension Array where Element == WeekdayPattern {
    /// The week in the order this person's calendar starts it, so a Monday-first
    /// region reads Mon–Sun rather than being told its week begins on Sunday.
    var inWeekOrder: [WeekdayPattern] {
        let first = Calendar.current.firstWeekday
        return sorted { left, right in
            ((left.weekday - first + 7) % 7) < ((right.weekday - first + 7) % 7)
        }
    }
}


extension Visit {
    func overlaps(_ range: DateInterval, now: Date = .now) -> Bool {
        arrival < range.end && (departure ?? now) > range.start
    }
    func duration(in range: DateInterval, now: Date = .now) -> TimeInterval {
        max(0, min(departure ?? now, range.end).timeIntervalSince(max(arrival, range.start)))
    }
}
