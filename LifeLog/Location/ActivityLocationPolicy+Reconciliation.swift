import Foundation
import SwiftData
import CoreLocation

/// Orchestration. Runs the rules above over the store: subtracting occupied time from
/// device activity, and repairing timelines earlier versions left behind.
///
/// One of six files `ActivityLocationPolicy` was split into. It had reached 985 lines
/// across six concerns, interleaved rather than merely adjacent. Same type, same call
/// sites — only the text moved.
extension ActivityLocationPolicy {
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
        // A live callback only needs its recent neighbours plus any open stay. The
        // complete non-imported archive belongs to versioned maintenance, never this
        // interaction-path reconciliation.
        let visits = try fetchRecentPolicyVisits(
            context: context,
            since: min(locationVisit.arrival, now).addingTimeInterval(-defaultReapplyLookback)
        )
        let activities = visits.filter(isMovementActivity)
        // The arriving visit is what supplies the previous stay's departure, so
        // bounding runs against every stay rather than just this one. It is scoped to
        // the last day because this runs inside a Core Location callback; repairing
        // older history is `reconcileAll`'s job, once per installation.
        let recent = activities.filter { ($0.departure ?? now) >= now.addingTimeInterval(-24 * 60 * 60) }
        // Before any stay is allowed to absorb a journey, drop the stays that a running
        // workout explains. Otherwise the drive-by guess both survives and eats the walk.
        // Scoped to the same day's window as `recent`: this runs inside a Core Location
        // callback, and only a workout that could overlap the arriving stay matters.
        // Nine years of workouts would otherwise be compared against every callback.
        let recentWorkouts = visits.filter {
            isWorkoutSession($0) && ($0.departure ?? now) >= now.addingTimeInterval(-24 * 60 * 60)
        }
        WorkoutJourneys.supersedePassingStays(during: recentWorkouts,
                              stays: [locationVisit], context: context, now: now)
        let resumed = boundStays(around: recent, stays: visits.filter(isLocationVisit),
                                 context: context, now: now)
        try reconcile(
            activities: activities,
            against: ([locationVisit] + resumed).filter { !isSupersededLocation($0) },
            context: context,
            now: now
        )
    }


    /// Default lookback for all three `reapplyRecent*` passes below — a day, cheap
    /// enough to run on every appearance and every invalidation regardless of cause.
    static let defaultReapplyLookback: TimeInterval = 24 * 60 * 60

    /// Re-applies the journey timing rules to the recent past, every time, cheaply.
    ///
    /// The one-shot repair cannot be relied on. `ActivityImportActor` is a `@ModelActor`
    /// with its own `ModelContext`, and it runs on every launch — so it holds copies of
    /// the same visits loaded before the repair, and its save writes them back over the
    /// top. Timeline saved 07:16:22 and the store read 07:02:44 in the same second, on
    /// every launch, which is why four correct fixes all looked like no fix at all.
    ///
    /// Rather than sequence two writers, the correction is simply re-applied. It is
    /// idempotent — a stay already ending at the journey it left is left alone — and
    /// scoped to `lookback`, so it costs a filter over recent records rather than a pass
    /// over the archive. Losing a race then costs a moment instead of a release.
    ///
    /// `lookback` defaults to a day for the routine appearance/invalidation callers, but
    /// a caller that knows it just replayed a wider window — `ActivityDataService`,
    /// after a Health/Motion import whose own `healthDays`/`motionDays` reached back
    /// further than a day — passes that same width, so the correction covers everywhere
    /// the import's stale snapshot could have just overwritten. A day was never a
    /// property of the race; it was only ever a guess at how wide the import's replay
    /// window usually was, and `walkingRecords`' unanchored re-scan can reach back up
    /// to 30 days after any gap in successful imports (see `healthImportWindowDays`).
    @discardableResult
    static func reapplyRecentJourneyTiming(context: ModelContext, now: Date = .now,
                                           lookback: TimeInterval = defaultReapplyLookback) throws -> Bool {
        let since = now.addingTimeInterval(-lookback)
        let visits = try fetchRecentPolicyVisits(context: context, since: since)
        let recent = visits.filter { isMovementActivity($0) && ($0.departure ?? now) >= since }
        guard !recent.isEmpty else { return false }
        let live = visits.filter { isLocationVisit($0) && !isSupersededLocation($0) }
        let before = live.map(\.departure)
        boundStays(around: recent, stays: live, now: now)
        let changed = zip(before, live.map(\.departure)).contains { $0 != $1 }
        if changed, context.hasChanges { try context.save() }
        return changed
    }

    /// Re-applies workout-vs-movement absorption to the recent past, every time,
    /// cheaply — the same shape as `reapplyRecentJourneyTiming`, for the same reason
    /// and the same `lookback` (see its doc comment). A health-walking or motion
    /// record for a walk is routinely imported in an earlier batch than the workout
    /// that explains it — different HealthKit queries, different delivery timing —
    /// so catching this once, at the moment either side is written, misses the
    /// ordinary case rather than the rare one.
    @discardableResult
    static func reapplyRecentMovementAbsorption(context: ModelContext, now: Date = .now,
                                                lookback: TimeInterval = defaultReapplyLookback) throws -> Bool {
        let since = now.addingTimeInterval(-lookback)
        let visits = try fetchRecentPolicyVisits(context: context, since: since)
        let recent = visits.filter { isMovementActivity($0) && ($0.departure ?? now) >= since }
        guard !recent.isEmpty else { return false }
        let sessions = recent.filter(isWorkoutSession).compactMap { WorkoutJourneys.WorkoutSession($0, now: now) }
        let changed = WorkoutJourneys.recordAbsorbedMovement(during: sessions, activities: recent,
                                                              context: context, now: now)
        if changed > 0, context.hasChanges { try context.save() }
        return changed > 0
    }

    /// Re-applies stay-vs-activity absorption to the recent past, every time, cheaply
    /// — the same shape as the two reapplies above, for a gap neither covers, and the
    /// same `lookback` (see `reapplyRecentJourneyTiming`'s doc comment).
    ///
    /// HealthKit's walking/motion queries are not anchored — they re-scan a rolling
    /// window on every import rather than reading only what's new. If a burst is first
    /// imported before the stay it happened inside exists yet (Core Location arrival
    /// detection routinely lags 20+ minutes behind the phone actually being there), it's
    /// inserted untrimmed. The next import re-scans, finds the stay now open, and
    /// `remainingSegments` correctly recomputes an empty segment list for it — but an
    /// empty result only tells `insertBatch` to insert nothing more; nothing goes back to
    /// retract the row already sitting in the store from the first pass. It stays
    /// orphaned, scattered across the day as though it happened nowhere in particular.
    ///
    /// `reconcile(locationVisit:)` would catch this — it runs the same underlying
    /// absorption — but only fires from a live Core Location callback, and a stay left
    /// open all day with nothing else happening never gets a further one. This calls the
    /// same general absorption `reconcileAll` runs once at launch, scoped to `lookback`
    /// so it costs a filter over recent records rather than a pass over the archive.
    @discardableResult
    static func reapplyRecentOpenStayAbsorption(context: ModelContext, now: Date = .now,
                                                lookback: TimeInterval = defaultReapplyLookback) throws -> Bool {
        let since = now.addingTimeInterval(-lookback)
        let visits = try fetchRecentPolicyVisits(context: context, since: since)
        let recent = visits.filter { isMovementActivity($0) && ($0.departure ?? now) >= since }
        guard !recent.isEmpty else { return false }
        let live = visits.filter { isLocationVisit($0) && !isSupersededLocation($0) }
        try reconcile(activities: recent, against: live, context: context, now: now)
        // Same reasoning as `reconcileAll`'s own last step, scoped the same way as
        // the rest of this function: catches a coordinate-less fragment sitting
        // between two same-place stays within `lookback`, without waiting for the
        // next full archive pass.
        coalesceStaysAcrossUnlocatedMovement(in: visits, context: context, now: now)
        let changed = context.hasChanges
        if changed { try context.save() }
        return changed
    }

    /// Cleans timelines created by earlier app versions when the model container opens.
    static func reconcileAll(context: ModelContext, now: Date = .now) throws {
        let visits = try fetchPolicyVisits(context: context)
        coalesceFragmentedTravel(in: visits, context: context, now: now)
        let afterTravelCoalescing = try fetchPolicyVisits(context: context)
        // Before anything else: a health-walking or motion record a workout already
        // explains is not independent evidence of a second walk. Run first and re-fetch
        // afterward, rather than filter the in-memory list by hand, so a record this
        // deletes is never seen again by the passes below that further mutate whatever
        // they are handed.
        let sessions = afterTravelCoalescing.filter(isWorkoutSession).compactMap { WorkoutJourneys.WorkoutSession($0, now: now) }
        WorkoutJourneys.recordAbsorbedMovement(during: sessions, activities: afterTravelCoalescing.filter(isMovementActivity),
                                               context: context, now: now)
        let remaining = try fetchPolicyVisits(context: context)
        let activities = remaining.filter(isMovementActivity)
        let locations = remaining.filter(isLocationVisit)
        WorkoutJourneys.supersedePassingStays(during: remaining.filter(isWorkoutSession),
                              stays: locations, context: context, now: now)
        let live = locations.filter { !isSupersededLocation($0) }
        let resumed = boundStays(around: activities, stays: live, context: context, now: now)
        try reconcile(
            activities: activities,
            against: (live + resumed).filter { !isSupersededLocation($0) },
            context: context,
            now: now
        )
        // Last, and re-fetched: everything above trims a fragment against the one
        // stay it directly overlaps. What's left over is only the fragments sitting
        // in a genuine gap *between* two stays — exactly what this needs to see to
        // decide whether both sides are the same place.
        let afterReconcile = try fetchPolicyVisits(context: context)
        coalesceStaysAcrossUnlocatedMovement(in: afterReconcile, context: context, now: now)
    }

    /// Merges a stay Apple Health split with a "Walking"/"In transit" fragment that
    /// carries no coordinates at all.
    ///
    /// `reconcile(activities:against:)` above only ever subtracts a movement record
    /// against a stay whose own recorded window already covers it — it has no way to
    /// notice that two *separate* stays either side of the gap are the same resolved
    /// place. That's the ordinary shape of this problem: Core Location logs Home as
    /// several short arrivals rather than one continuous stay, and a location-less
    /// Health sample lands in each gap between them. The fragment has no coordinate
    /// to check against a geofence — there is nothing to check — but the same resolved
    /// place recorded on both sides is exactly the evidence
    /// `GapSuggestionCandidateGenerator`'s `nearbyResolvedPlaceStay` candidate already
    /// trusts for an unlogged gap, reused here to fold the fragment away rather than
    /// merely suggest it.
    ///
    /// Deliberately conservative: every record strictly between the two stays must be
    /// a movement record with no coordinates, or nothing merges — a real visit, or a
    /// fragment that does have a coordinate elsewhere, still blocks it exactly the way
    /// `coalesceFragmentedTravel`'s own destination check does below.
    static func coalesceStaysAcrossUnlocatedMovement(in visits: [Visit], context: ModelContext,
                                                      now: Date = .now) {
        var locations = visits
            .filter { isLocationVisit($0) && !isSupersededLocation($0) && !$0.isIgnored }
            .sorted { $0.arrival < $1.arrival }
        guard locations.count > 1 else { return }

        var index = 0
        while index < locations.count - 1 {
            let current = locations[index]
            let next = locations[index + 1]
            guard let currentDeparture = current.departure, next.arrival >= currentDeparture,
                  // A cap, not load-bearing evidence: everything between is already
                  // required to be a coordinate-less movement fragment below, which
                  // does the real work. This only guards against folding together two
                  // same-named stays separated by an implausibly long, otherwise
                  // fragment-only stretch — the same role `CommuteDetection.longestPlausible`
                  // plays for a journey rather than a stay.
                  next.arrival.timeIntervalSince(currentDeparture) <= 4 * 60 * 60,
                  sameResolvedPlace(current, next) else {
                index += 1
                continue
            }
            let between = visits.filter {
                $0.arrival >= currentDeparture && $0.arrival < next.arrival && $0 !== current && $0 !== next
            }
            guard !between.isEmpty,
                  // A workout's own `latitude`/`longitude` are always the same 0,0
                  // placeholder as a passive movement sample — real evidence of a
                  // departure lives in its `route`, not those fields — so it must be
                  // excluded by kind, not just by coordinate. "Someone pressing Start"
                  // is a first-hand statement `isDeclaredJourney`'s own doc comment
                  // already refuses to silently absorb; folding it away here on a
                  // false "no location" reading would be exactly that.
                  between.allSatisfy({ isMovementActivity($0) && !isWorkoutSession($0) && hasNoCoordinate($0) }) else {
                index += 1
                continue
            }
            for fragment in between { context.delete(fragment) }
            current.departure = next.departure
            context.delete(next)
            locations.remove(at: index + 1)
            // Re-check the merged `current` against whatever is now next — a chain of
            // several fragments between more than two same-place stays collapses in
            // one pass instead of needing the whole function to run again.
        }
    }

    /// Whichever it lacks, this fragment has nothing to place it anywhere on its own —
    /// the exact shape of an Apple Health movement sample with no route or GPS fix.
    private static func hasNoCoordinate(_ visit: Visit) -> Bool {
        visit.latitude == 0 && visit.longitude == 0
    }

    /// The same resolved place, recorded on both sides — by Apple Maps identifier when
    /// both sides have one (two visits only share it by being the same physical place),
    /// falling back to a punctuation/case-insensitive name match. Never true for a
    /// placeholder name: "Identifying…" on both sides is not evidence they agree.
    private static func sameResolvedPlace(_ a: Visit, _ b: Visit) -> Bool {
        guard !a.hasPlaceholderName, !b.hasPlaceholderName else { return false }
        if let idA = a.mapsIdentifier, let idB = b.mapsIdentifier { return idA == idB }
        return NameKey.matching(a.placeName) == NameKey.matching(b.placeName)
    }

    /// Repairs older rolling-motion imports that split a car trip whenever Core Motion
    /// briefly stopped calling it automotive. A location stay in the gap is a real
    /// destination, not a classifier blip, so it keeps the trips separate.
    static func coalesceFragmentedTravel(in visits: [Visit], context: ModelContext,
                                         now: Date = .now) {
        let locations = visits.filter { isLocationVisit($0) && !isSupersededLocation($0) }
        let travel = visits.filter {
            $0.visitSource == .motion && $0.recognition != .confirmed && isTravelActivity($0)
        }.sorted { $0.arrival < $1.arrival }
        var leader: Visit?
        for candidate in travel {
            guard let end = candidate.departure, end > candidate.arrival else { continue }
            guard let previous = leader, let previousEnd = previous.departure else {
                leader = candidate
                continue
            }
            let gap = candidate.arrival.timeIntervalSince(previousEnd)
            let gapHasDestination = locations.contains { stay in
                stay.arrival < candidate.arrival && (stay.departure ?? now) > previousEnd
            }
            guard gap >= 0, gap <= 10 * 60, !gapHasDestination else {
                leader = candidate
                continue
            }
            previous.departure = end
            context.delete(candidate)
        }
    }

    static func fetchPolicyVisits(context: ModelContext) throws -> [Visit] {
        // Imported journals already contain resolved activity/location pairs and never
        // participate in live movement reconciliation. Excluding them avoids loading a
        // large archive during location updates.
        let descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source != "imported-journal" }
        )
        return try context.fetch(descriptor)
    }

    /// The recurring return/import repairs concern only the last day plus a stay
    /// still open from before it. Querying that small slice before filtering avoids
    /// hydrating the complete archive every time Timeline becomes visible.
    static func fetchRecentPolicyVisits(context: ModelContext, since: Date) throws -> [Visit] {
        let descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate {
                $0.source != "imported-journal" && ($0.arrival >= since || $0.departure == nil)
            }
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
            // A stay the journey's own path shows it left cannot also have occupied
            // that time. Subtracting it would delete the walk that proves the point.
            //
            // A started workout is never occupied at all. Without this, a walk with no
            // route — which is every walk until Health grants route access — is
            // subtracted by whatever stays overlap it, and `remaining` comes back empty:
            // `case 0` below then *deletes* the workout outright. A walk out of the
            // house and back, with a drive-by stay recorded partway round, disappears
            // from Timeline and Insights entirely rather than merely being absorbed.
            let occupying = isDeclaredJourney(activity, stays: locations)
                ? []
                : locations.filter { leftStay(activity, stay: $0) != true }
            let remaining = remainingSegments(for: interval, locationVisits: occupying, now: now)
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

    // Internal rather than private: WorkoutJourneys reuses both to subtract a workout's
    // own span from a weaker device record of the same walk, rather than duplicating
    // interval-splitting logic a second place for a second kind of "occupied" time.
    nonisolated static func subtract(_ occupied: [DateInterval], from activity: DateInterval) -> [DateInterval] {
        occupied.sorted { $0.start < $1.start }.reduce([activity]) { segments, location in
            segments.flatMap { segment in subtract(location, from: segment) }
        }
    }

    nonisolated static func subtract(_ occupied: DateInterval, from activity: DateInterval) -> [DateInterval] {
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

    nonisolated static func copy(of activity: Visit, interval: DateInterval) -> Visit {
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
