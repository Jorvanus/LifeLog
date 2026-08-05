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

    static func make(visits: [Visit], window: InsightWindow, anchorDate: Date, now: Date) -> InsightsSnapshot {
        let interval = window.interval(containing: anchorDate)
        // Current periods end “now”; otherwise future time would dominate the donut as unlogged.
        let analysisInterval = interval.contains(now)
            ? DateInterval(start: interval.start, end: min(interval.end, now))
            : interval
        let previousStart = interval.start.addingTimeInterval(-interval.duration)
        let previousInterval = DateInterval(
            start: previousStart,
            end: min(interval.start, previousStart.addingTimeInterval(analysisInterval.duration))
        )

        // Location visits are prepared once and reused by both periods. This avoids an
        // all-history scan for each individual walking or travel record.
        let locationVisits = visits.filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
        let segments = makeSegments(
            visits: visits,
            locationVisits: locationVisits,
            range: analysisInterval,
            now: now
        )
        let previousSegments = makeSegments(
            visits: visits,
            locationVisits: locationVisits,
            range: previousInterval,
            now: now
        )
        let slices = makeSlices(from: segments)
        let previousSlices = makeSlices(from: previousSegments)
        let placeTotals = makePlaceTotals(visits: visits, range: analysisInterval, now: now)
        let mappablePlaces = placeTotals.filter { $0.latitude != 0 || $0.longitude != 0 }
        let loggedHours = segments.filter { !$0.isUnlogged }.reduce(0) { $0 + $1.hours }
        let awayFromHomeHours = segments.filter {
            !$0.isUnlogged && !$0.activity.localizedCaseInsensitiveContains("home") &&
            !($0.placeName?.localizedCaseInsensitiveContains("home") ?? false)
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

    private static func makeSegments(visits: [Visit], locationVisits: [Visit],
                                     range: DateInterval, now: Date) -> [InsightSegment] {
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
        let commutes = CommuteDetection.commutes(in: visits, now: now)
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

    private static func makePlaceTotals(visits: [Visit], range: DateInterval, now: Date) -> [PlaceTotal] {
        Dictionary(
            grouping: visits.filter {
                $0.overlaps(range, now: now) && ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored
            },
            by: \.displayPlaceName
        ).compactMap { name, items in
            guard let first = items.first else { return nil }
            return PlaceTotal(
                name: name, category: first.insightCategory, activity: first.suspectedActivity,
                latitude: first.latitude, longitude: first.longitude,
                hours: items.reduce(0) { $0 + $1.duration(in: range, now: now) } / 3600
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

    private static func makeWeekdayPatterns(from segments: [InsightSegment]) -> [WeekdayPattern] {
        let calendar = Calendar.current
        var totals = Array(repeating: 0.0, count: 7)
        var activities = Array(repeating: [String: Double](), count: 7)
        for segment in segments where !segment.isUnlogged {
            let weekday = max(1, min(7, calendar.component(.weekday, from: segment.start))) - 1
            totals[weekday] += segment.hours
            activities[weekday][segment.activity, default: 0] += segment.hours
        }
        return (0..<7).map { index in
            let top = activities[index].max { $0.value < $1.value }
            return WeekdayPattern(weekday: index + 1, hours: totals[index],
                                  topActivity: top?.key ?? "Visiting", topHours: top?.value ?? 0)
        }
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

struct WeekdayPattern: Identifiable {
    let weekday: Int
    let hours: Double
    let topActivity: String
    let topHours: Double
    var id: Int { weekday }
    var shortName: String {
        Calendar.current.shortWeekdaySymbols[(weekday - 1) % 7]
    }
    static let empty = (1...7).map { WeekdayPattern(weekday: $0, hours: 0, topActivity: "Visiting", topHours: 0) }
}


extension Visit {
    func overlaps(_ range: DateInterval, now: Date = .now) -> Bool {
        arrival < range.end && (departure ?? now) > range.start
    }
    func duration(in range: DateInterval, now: Date = .now) -> TimeInterval {
        max(0, min(departure ?? now, range.end).timeIntervalSince(max(arrival, range.start)))
    }
}
