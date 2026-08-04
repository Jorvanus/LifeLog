import Foundation
import SwiftData
import CoreLocation

/// Keeps the timeline location-first by removing device activity that occurs during a place visit.
@MainActor
enum ActivityLocationPolicy {
    static let supersededLocationSource = "automatic-superseded"

    /// Movement shorter than this stays out of the daily card list, though Insights
    /// still counts it. Motion segments are already filtered at two to three minutes
    /// when they are recorded, so this mainly suppresses a stray sample either side
    /// of a stay rather than a real outing: a walk to the park and back is a journey
    /// worth seeing, and requiring an hour of it hid every one of them.
    nonisolated static let minimumTimelineMovementDuration: TimeInterval = 5 * 60

    nonisolated static func isLocationVisit(_ visit: Visit) -> Bool {
        visit.source == "automatic" || visit.source == "manual"
    }

    nonisolated static func isSupersededLocation(_ visit: Visit) -> Bool {
        visit.source == "automatic-superseded"
    }

    /// Whether a visit belongs on a given day's timeline. A stay counts for every day
    /// it covers rather than the day it began: Core Location records one arrival per
    /// stay, so a night at home arrives the evening before and is the only record of
    /// the following morning until the person next goes out.
    nonisolated static func covers(_ visit: Visit, day: DateInterval, now: Date = .now) -> Bool {
        visit.arrival < day.end && (visit.departure ?? now) > day.start
    }

    /// Single resolver for callback order and overlap. Raw callbacks remain
    /// stored; duplicates are marked superseded and older open stays bounded.
    @discardableResult
    static func resolveLocationCallbacks(context: ModelContext) throws -> Int {
        let repaired = try closeSupersededOpenLocations(context: context)
        let marked = try deduplicateAutomaticLocations(context: context)
        let total = repaired + marked
        if total > 0 {
            Diagnostics.locationMetric(context, operation: "resolver_repairs", repairs: total)
        }
        return total
    }

    nonisolated static func isDeviceActivity(_ visit: Visit) -> Bool {
        visit.source == "motion" || visit.source.hasPrefix("health-")
    }

    /// Text-only tests so the import actor can classify a record before it becomes
    /// a `Visit`, and so both paths agree on what counts as walking or travel.
    nonisolated static func describesWalking(_ text: String) -> Bool {
        text.lowercased().contains("walk")
    }

    nonisolated static func describesTravel(_ text: String) -> Bool {
        let text = text.lowercased()
        return ["travel", "transit", "automotive", "vehicle", "driv", "car", "plane", "flight"]
            .contains { text.contains($0) }
    }

    nonisolated static func isWalkingActivity(_ visit: Visit) -> Bool {
        guard isDeviceActivity(visit) else { return false }
        return describesWalking(visit.activity)
    }

    nonisolated static func isTravelActivity(_ visit: Visit) -> Bool {
        guard isDeviceActivity(visit) else { return false }
        return describesTravel("\(visit.activity) \(visit.placeName)")
    }

    nonisolated static func isMovementActivity(_ visit: Visit) -> Bool {
        isWalkingActivity(visit) || isTravelActivity(visit)
    }

    /// Finds the stored arrival represented by a departure callback. Core
    /// Location can deliver callbacks out of order, so recency alone is not a
    /// reliable identity. Arrival proximity is strongest, then coordinate
    /// distance and whether the stored visit is still open.
    static func matchDeparture(coordinate: CLLocationCoordinate2D, arrival: Date,
                               departure: Date, visits: [Visit]) -> Visit? {
        guard CLLocationCoordinate2DIsValid(coordinate), departure >= arrival else { return nil }
        let callbackLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let candidates = visits.compactMap { visit -> (visit: Visit, arrivalDelta: TimeInterval,
                                                        distance: CLLocationDistance, isClosed: Bool)? in
            guard isLocationVisit(visit), visit.resolutionState != .superseded,
                  visit.arrival <= departure else { return nil }
            let recorded = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
            let distance = callbackLocation.distance(from: recorded)
            let arrivalDelta = abs(visit.arrival.timeIntervalSince(arrival))
            let overlapsCallback = visit.arrival <= departure && (visit.departure ?? .distantFuture) >= arrival
            guard distance <= 350, overlapsCallback,
                  arrivalDelta <= 45 * 60 || visit.departure == nil else { return nil }
            return (visit, arrivalDelta, distance, visit.departure != nil)
        }
        return candidates.min {
            if $0.arrivalDelta != $1.arrivalDelta { return $0.arrivalDelta < $1.arrivalDelta }
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            return !$0.isClosed && $1.isClosed
        }?.visit
    }

    /// Reads a movement record as the moment a stay ended.
    ///
    /// Core Location times a departure from the *next* arrival, so a stay looks like
    /// it covered the walk out the door, and reconciliation then deletes that walk
    /// rather than showing it. When a stay's departure falls at or before the end of
    /// a walk or drive, the movement is how the person left: bound the stay where the
    /// movement began, and the journey survives.
    ///
    /// A stay with no departure is never treated this way. LifeLog has not seen the
    /// person leave, so movement inside it is movement *at* that place — pacing at
    /// home, a lap of the office — and that is the only honest reading. Deciding that
    /// a walk was a loop around the block instead needs to know where the walk went,
    /// which is the route work on the roadmap; duration cannot stand in for it.
    @discardableResult
    nonisolated static func boundStay(departedWith movement: DateInterval, stays: [Visit]) -> Bool {
        guard movement.duration > 0 else { return false }
        let containing = stays.filter { stay in
            // Only Core Location's own timing is adjusted. A manual entry states when
            // the person says they were somewhere, and no device sample overrides that.
            guard stay.source == "automatic", let departure = stay.departure else { return false }
            return stay.arrival < movement.start && departure > movement.start
        }
        guard let stay = containing.max(by: { $0.arrival < $1.arrival }),
              let departure = stay.departure, departure <= movement.end else { return false }
        stay.departure = movement.start
        return true
    }

    /// Applies `boundStay` to every movement record in date order, so a day with
    /// several outings resolves against the stay each one actually left.
    private static func boundStays(around activities: [Visit], stays: [Visit]) {
        let movement = activities
            .filter { isMovementActivity($0) && $0.departure != nil }
            .sorted { $0.arrival < $1.arrival }
        for record in movement {
            guard let end = record.departure, end > record.arrival else { continue }
            boundStay(departedWith: DateInterval(start: record.arrival, end: end), stays: stays)
        }
    }

    /// Repairs stays an earlier build split in two. A walk inside an unbounded stay
    /// was read as leaving and returning, which invented an arrival at a place the
    /// person had never left: "Home, walking, Home" while they were home throughout.
    /// Two consecutive stays describing the same place, with nothing between them but
    /// a short stretch of walking, were one stay.
    @discardableResult
    static func rejoinStaysSplitByMovement(context: ModelContext) throws -> Int {
        let visits = try fetchPolicyVisits(context: context)
        let stays = visits.filter { isLocationVisit($0) && !isSupersededLocation($0) }
            .sorted { $0.arrival < $1.arrival }
        let walking = visits.filter(isWalkingActivity)
        var rejoined = 0
        var open: Visit?
        for stay in stays {
            guard let previous = open else { open = stay; continue }
            guard canRejoin(previous, stay, walking: walking) else { open = stay; continue }
            previous.departure = stay.departure
            // Closed and marked the way de-duplication marks a merged callback, so the
            // row is kept for inspection but never reaches Timeline or Insights again.
            stay.departure = stay.arrival
            stay.source = supersededLocationSource
            rejoined += 1
        }
        return rejoined
    }

    private static func canRejoin(_ previous: Visit, _ stay: Visit, walking: [Visit]) -> Bool {
        // Only LifeLog's own inference is undone; a manual entry is left as written.
        guard previous.source == "automatic", stay.source == "automatic",
              let departure = previous.departure, stay.arrival > departure else { return false }
        let gap = DateInterval(start: departure, end: stay.arrival)
        // A long absence is not repaired. Whatever happened in an hour away, claiming
        // the person never left would be a bigger error than leaving the two rows.
        guard gap.duration <= 60 * 60 else { return false }
        guard normalized(previous.placeName) == normalized(stay.placeName),
              !Visit.isPlaceholderName(stay.placeName) else { return false }
        let distance = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
            .distance(from: CLLocation(latitude: stay.latitude, longitude: stay.longitude))
        guard distance <= 150 else { return false }
        // Only a split made by walking is undone. A gap containing a drive, or nothing
        // at all, is a real absence LifeLog simply has no destination for.
        return walking.contains { record in
            record.arrival < gap.end && (record.departure ?? gap.end) > gap.start
        }
    }

    /// Movement is useful as a travel segment only when it sits between two destinations.
    /// This also hides stale records that were imported before Core Location delivered
    /// the surrounding visits.
    static func isBetweenDestinations(_ activity: Visit, locationVisits: [Visit], now: Date = .now) -> Bool {
        guard isMovementActivity(activity) else { return true }
        let activityEnd = activity.departure ?? now
        guard activityEnd > activity.arrival else { return false }
        let overlapsDestination = locationVisits.contains { location in
            let locationEnd = location.departure ?? now
            return location.arrival < activityEnd && locationEnd > activity.arrival
        }
        guard !overlapsDestination else { return false }
        let hasPreviousDestination = locationVisits.contains { location in
            let locationEnd = location.departure ?? now
            return locationEnd <= activity.arrival
        }
        let hasNextDestination = locationVisits.contains { $0.arrival >= activityEnd }
        return hasPreviousDestination && hasNextDestination
    }

    static func shouldShow(_ visit: Visit, alongside allVisits: [Visit], now: Date = .now) -> Bool {
        shouldShow(
            visit,
            locationVisits: allVisits.filter(isLocationVisit),
            now: now
        )
    }

    /// Use this overload in batch processing so the caller can filter locations once
    /// instead of rescanning the entire timeline for every movement record.
    static func shouldShow(_ visit: Visit, locationVisits: [Visit], now: Date = .now) -> Bool {
        guard isMovementActivity(visit) else { return true }
        return isBetweenDestinations(
            visit,
            locationVisits: locationVisits,
            now: now
        )
    }

    /// Timeline stays location-first: momentary movement between destinations is
    /// retained for Insights but omitted from the daily card list. A real journey
    /// — the walk to the park, the drive to work — is an event in its own right.
    static func shouldShowInTimeline(_ visit: Visit, locationVisits: [Visit], now: Date = .now) -> Bool {
        guard !isSupersededLocation(visit) else { return false }
        // Timeline is destination-first: device activity that occurs inside a
        // recorded place is retained for Insights but does not become another
        // simultaneous card. Sleep is the intentional exception.
        if isDeviceActivity(visit), !visit.source.hasPrefix("health-sleep") {
            let end = visit.departure ?? now
            let overlapsDestination = locationVisits.contains { location in
                let locationEnd = location.departure ?? now
                return location.arrival < end && locationEnd > visit.arrival
            }
            if overlapsDestination { return false }
        }
        guard isMovementActivity(visit) else { return true }
        let duration = (visit.departure ?? now).timeIntervalSince(visit.arrival)
        return duration >= minimumTimelineMovementDuration &&
            isBetweenDestinations(visit, locationVisits: locationVisits, now: now)
    }

    /// Insights retains every valid between-destination travel segment, including
    /// short commutes, so time spent travelling is not lost from the day total.
    static func shouldShowInInsights(_ visit: Visit, locationVisits: [Visit], now: Date = .now) -> Bool {
        guard !isSupersededLocation(visit) else { return false }
        return shouldShow(visit, locationVisits: locationVisits, now: now)
    }

    /// Gives movement records a useful destination label once the next place is known.
    /// Work and home are stable labels; other places need to recur across multiple days
    /// before they are used as a learned destination name.
    static func updateTravelDescriptions(context: ModelContext) throws {
        let visits = try fetchPolicyVisits(context: context)
        let locations = visits.filter { isLocationVisit($0) && !$0.isIgnored }
        for activity in visits where isTravelActivity(activity) && !activity.isIgnored {
            let end = activity.departure ?? .now
            guard let destination = locations
                .filter({ $0.arrival >= end })
                .min(by: { $0.arrival < $1.arrival }),
                  let label = destinationLabel(for: destination, locations: locations) else {
                continue
            }

            let description = "Travelling to \(label)"
            // Generated labels may evolve as the destination becomes known, but a custom
            // activity entered by the user remains authoritative.
            let isGeneratedActivity = activity.userActivity == nil ||
                activity.userActivity == activity.inferredActivity ||
                activity.userActivity == "Travelling" ||
                activity.userActivity == "In transit"
            activity.inferredActivity = description
            activity.recognitionConfidence = destinationConfidence(for: destination, locations: locations)
            if isGeneratedActivity {
                activity.userActivity = description
            }
        }
    }

    private static func destinationLabel(for destination: Visit, locations: [Visit]) -> String? {
        let destinationText = destination.placeName.lowercased()
        if InferenceEngine.activity(placeName: destination.placeName) == "Working" {
            return "Work"
        }
        if destinationText.contains("home") {
            return "Home"
        }

        let key = normalized(destination.placeName)
        guard !key.isEmpty, !Visit.isPlaceholderName(destination.placeName) else { return nil }
        let matches = locations.filter { normalized($0.placeName) == key }
        let distinctDays = Set(matches.map { Calendar.current.startOfDay(for: $0.arrival) }).count
        // Avoid learning a destination name from a one-off or same-day GPS duplicate.
        guard matches.count >= 3, distinctDays >= 2 else { return nil }
        return TextSafety.clean(destination.placeName, maximumLength: 80)
    }

    private static func destinationConfidence(for destination: Visit, locations: [Visit]) -> String {
        let text = destination.placeName.lowercased()
        if InferenceEngine.activity(placeName: destination.placeName) == "Working" || text.contains("home") {
            return "learned"
        }
        let key = normalized(destination.placeName)
        let matches = locations.filter { normalized($0.placeName) == key }
        let days = Set(matches.map { Calendar.current.startOfDay(for: $0.arrival) }).count
        return matches.count >= 3 && days >= 2 ? "learned" : "medium"
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }

    static func minimumRetainedDuration(for source: String) -> TimeInterval {
        switch source {
        case "health-sleep": 20 * 60
        case "motion", "health-walking": 2 * 60
        default: 60
        }
    }

    static func remainingSegments(for activity: DateInterval, locationVisits: [Visit], now: Date = .now) -> [DateInterval] {
        let occupied = locationVisits.compactMap { visit -> DateInterval? in
            guard isLocationVisit(visit) else { return nil }
            let end = visit.departure ?? now
            guard end > visit.arrival else { return nil }
            return DateInterval(start: visit.arrival, end: end)
        }
        return subtract(occupied, from: activity)
    }

    /// Reconciles activity imported before a location visit arrived from Core Location.
    static func reconcile(locationVisit: Visit, context: ModelContext, now: Date = .now) throws {
        guard isLocationVisit(locationVisit) else { return }
        let visits = try fetchPolicyVisits(context: context)
        let activities = visits.filter(isMovementActivity)
        // The arriving visit is what supplies the previous stay's departure, so
        // bounding runs against every stay rather than just this one. It is scoped to
        // the last day because this runs inside a Core Location callback; repairing
        // older history is `reconcileAll`'s job, once per installation.
        let recent = activities.filter { ($0.departure ?? now) >= now.addingTimeInterval(-24 * 60 * 60) }
        boundStays(around: recent, stays: visits.filter(isLocationVisit))
        try reconcile(
            activities: activities,
            against: [locationVisit],
            context: context,
            now: now
        )
    }

    /// Cleans timelines created by earlier app versions when the model container opens.
    static func reconcileAll(context: ModelContext, now: Date = .now) throws {
        let visits = try fetchPolicyVisits(context: context)
        let activities = visits.filter(isMovementActivity)
        let locations = visits.filter(isLocationVisit)
        boundStays(around: activities, stays: locations)
        try reconcile(
            activities: activities,
            against: locations,
            context: context,
            now: now
        )
    }

    /// Removes exact/repeated automatic callbacks that describe the same arrival.
    /// A short time and coordinate tolerance handles Core Location replay without
    /// merging a genuine later return to the same place.
    @discardableResult
    static func deduplicateAutomaticLocations(context: ModelContext) throws -> Int {
        let visits = try context.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source == "automatic" || $0.source == "automatic-superseded" },
            sortBy: [SortDescriptor(\.arrival)]
        ))
        var retained: [Visit] = []
        var removed = 0
        // Heal rows stranded by earlier builds, which relabelled a duplicate without
        // closing it. They are excluded from every screen, so this only bounds their
        // stored duration; it never changes what is displayed.
        var healed = 0
        for stale in visits where isSupersededLocation(stale) && stale.departure == nil {
            stale.departure = stale.arrival
            healed += 1
        }
        for candidate in visits where !isSupersededLocation(candidate) {
            guard let previous = retained.last else {
                retained.append(candidate)
                continue
            }

            let sameName = previous.placeName.caseInsensitiveCompare(candidate.placeName) == .orderedSame
            let distance = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                .distance(from: CLLocation(latitude: candidate.latitude, longitude: candidate.longitude))
            // A named Saved Place and an earlier “Identifying…” callback can be
            // the same Core Location arrival. Names need not match, but require a
            // tighter coordinate tolerance in that case so nearby businesses are
            // never folded together merely because their callbacks were close.
            let sameArrival = abs(previous.arrival.timeIntervalSince(candidate.arrival)) <= 60 &&
                distance <= (sameName ? 250 : 100)
            if sameArrival {
                // Merge repeated callbacks that describe the same arrival.
                previous.arrival = min(previous.arrival, candidate.arrival)
                switch (previous.departure, candidate.departure) {
                case (nil, _), (_, nil): previous.departure = nil
                case let (left?, right?): previous.departure = max(left, right)
                }
                if locationQuality(candidate) > locationQuality(previous) {
                    previous.placeName = candidate.placeName
                    previous.inferredActivity = candidate.inferredActivity
                    previous.userActivity = candidate.userActivity
                    previous.recognitionConfidence = candidate.recognitionConfidence
                }
                // The candidate's interval now lives on `previous`, including its
                // open-endedness, so the superseded row must not stay open itself.
                // `closeSupersededOpenLocations` only fetches live locations and can
                // never reach it, which otherwise leaves a row whose `duration` grows
                // for the life of the store.
                candidate.departure = candidate.arrival
                candidate.source = supersededLocationSource
                removed += 1
            } else {
                // A later destination proves that an earlier open stay ended when this
                // visit began. Closing it prevents an open stay from consuming the
                // entire Insights interval.
                if previous.departure == nil, candidate.arrival > previous.arrival {
                    previous.departure = candidate.arrival
                }
                retained.append(candidate)
            }
        }
        // Healed rows are counted so the caller still saves, and is still told it
        // repaired something, on a pass that only closed stranded records.
        return removed + healed
    }

    /// Higher-quality recognition wins when Core Location supplies two views of
    /// the same arrival. This prevents a placeholder from outliving a learned
    /// Saved Place while never letting an uncertain Maps result replace a user
    /// confirmation.
    private static func locationQuality(_ visit: Visit) -> Int {
        if visit.recognitionConfidence == "confirmed" { return 4 }
        if !visit.needsCategorisation && visit.recognitionConfidence == "learned" { return 3 }
        if !visit.needsCategorisation { return 2 }
        return 1
    }

    /// Restores the core timeline invariant that only the newest location may be
    /// open. Older nil-departure records came from delayed callbacks in previous
    /// builds and otherwise keep growing as though they are still current.
    @discardableResult
    static func closeSupersededOpenLocations(context: ModelContext) throws -> Int {
        let locations = try context.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source == "automatic" || $0.source == "manual" },
            sortBy: [SortDescriptor(\.arrival)]
        ))
        guard let latest = locations.last else { return 0 }
        var repaired = 0
        for visit in locations where visit.departure == nil && visit.id != latest.id {
            guard let next = locations.first(where: { $0.arrival > visit.arrival }) else { continue }
            visit.departure = next.arrival
            repaired += 1
        }
        return repaired
    }

    private static func fetchPolicyVisits(context: ModelContext) throws -> [Visit] {
        // Imported journals already contain resolved activity/location pairs and never
        // participate in live movement reconciliation. Excluding them avoids loading a
        // large archive during location updates.
        let descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source != "imported-journal" }
        )
        return try context.fetch(descriptor)
    }

    private static func reconcile(activities: [Visit], against locations: [Visit],
                                  context: ModelContext, now: Date) throws {
        for activity in activities {
            let activityEnd = activity.departure ?? now
            guard activityEnd > activity.arrival else { continue }
            let interval = DateInterval(start: activity.arrival, end: activityEnd)
            let minimumDuration = minimumRetainedDuration(for: activity.source)
            let remaining = remainingSegments(for: interval, locationVisits: locations, now: now)
                .filter { $0.duration >= minimumDuration }

            switch remaining.count {
            case 0:
                context.delete(activity)
            case 1:
                activity.arrival = remaining[0].start
                activity.departure = remaining[0].end
            default:
                activity.arrival = remaining[0].start
                activity.departure = remaining[0].end
                for segment in remaining.dropFirst() {
                    context.insert(copy(of: activity, interval: segment))
                }
            }
        }
    }

    private static func subtract(_ occupied: [DateInterval], from activity: DateInterval) -> [DateInterval] {
        occupied.sorted { $0.start < $1.start }.reduce([activity]) { segments, location in
            segments.flatMap { segment in subtract(location, from: segment) }
        }
    }

    private static func subtract(_ occupied: DateInterval, from activity: DateInterval) -> [DateInterval] {
        guard occupied.start < activity.end, occupied.end > activity.start else { return [activity] }
        var result: [DateInterval] = []
        if occupied.start > activity.start {
            result.append(DateInterval(start: activity.start, end: min(occupied.start, activity.end)))
        }
        if occupied.end < activity.end {
            result.append(DateInterval(start: max(occupied.end, activity.start), end: activity.end))
        }
        return result.filter { $0.duration > 0 }
    }

    private static func copy(of activity: Visit, interval: DateInterval) -> Visit {
        Visit(
            arrival: interval.start,
            departure: interval.end,
            latitude: activity.latitude,
            longitude: activity.longitude,
            placeName: activity.placeName,
            inferredActivity: activity.inferredActivity,
            userActivity: activity.userActivity,
            note: activity.note,
            source: activity.source,
            recognitionConfidence: activity.recognitionConfidence,
            candidateData: activity.candidateData
        )
    }
}
