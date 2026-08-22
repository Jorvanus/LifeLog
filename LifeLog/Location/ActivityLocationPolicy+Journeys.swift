import Foundation
import SwiftData
import CoreLocation

/// What movement proves about the stays around it — whether a walk left the place it
/// started from, where a stay should be bounded, and undoing a split that was wrong.
///
/// One of six files `ActivityLocationPolicy` was split into. It had reached 985 lines
/// across six concerns, interleaved rather than merely adjacent. Same type, same call
/// sites — only the text moved.
extension ActivityLocationPolicy {

    /// How far a journey must get from a place before it counts as having left it.
    /// Wide enough that a large site, a garden, or GPS drift at a doorway is still
    /// "here", short enough that a walk to the end of the street is not.
    nonisolated static let departureRadius: CLLocationDistance = 250


    /// Whether a movement record's own path shows it leaving the stay it sits inside.
    ///
    /// This is the question Core Location cannot answer. It reports a departure only
    /// when a region is finally left, so a walk that starts and ends at home — a loop
    /// around the block — looks exactly like walking about indoors: movement, no
    /// departure, no new arrival. The path separates them, and nothing else does.
    /// Without a route this stays `nil`: unknown, not "no".
    nonisolated static func leftStay(_ movement: Visit, stay: Visit) -> Bool? {
        leftStay(route: movement.route, stay: stay)
    }


    /// Route-only form, so the import path can ask before a record becomes a `Visit`.
    nonisolated static func leftStay(route: [RoutePoint], stay: Visit) -> Bool? {
        guard !route.isEmpty else { return nil }
        let origin = CLLocation(latitude: stay.latitude, longitude: stay.longitude)
        guard let farthest = route.map({ $0.location.distance(from: origin) }).max() else { return nil }
        return farthest > departureRadius
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
    ///
    /// Nor may the movement consume the stay. A walk out the door covers the tail of a
    /// stay; a stay that is *almost entirely* walking was never a stay at all, and
    /// reading it as one erases the visit and keeps the walking. On 8 August a shop
    /// visit ran 9:36 to 10:07 and the steps taken inside it began at 9:38, so bounding
    /// left two minutes of shopping and twenty-nine minutes of "Walking" that ended at
    /// a shop 455 m away — reported, correctly, as nonsense. The share below is a
    /// threshold and not a measurement: only the route settles the middle ground, and
    /// this refuses just the end of the range where the reading is plainly wrong.
    nonisolated static let maximumStayShareConsumedByJourney = 0.75

    @discardableResult
    nonisolated static func boundStay(departedWith movement: DateInterval, stays: [Visit]) -> Bool {
        guard movement.duration > 0,
              let stay = containingStay(at: movement.start, stays: stays, requiringDeparture: true),
              let departure = stay.departure, departure <= movement.end else { return false }
        let recorded = departure.timeIntervalSince(stay.arrival)
        let consumed = departure.timeIntervalSince(movement.start)
        guard recorded > 0, consumed / recorded <= maximumStayShareConsumedByJourney else { return false }
        stay.departure = movement.start
        return true
    }


    /// The mirror of `boundStay`: a stay Core Location closed *before* the journey that
    /// left it, leaving a hole where the person was still there.
    ///
    /// A departure is timed from a geofence crossing or implied by a later arrival, not
    /// from the moment somewhere stopped being where you were. On 8 August a Home stay
    /// closed at 07:02:44 and the morning's walk began at 07:16:22, so fourteen minutes
    /// of getting up and getting ready belonged to nothing and Insights reported them,
    /// correctly, as unlogged.
    ///
    /// Nothing is invented here. If the person had gone anywhere in that gap there would
    /// be a record of it, and the guard below refuses to act when one exists. What is
    /// left is a stay, a journey out of it, and no evidence of anything in between —
    /// under which the only reading the records allow is that they had not left yet.
    ///
    /// Bounded by `departureCatchUp` because the inference weakens with time: minutes
    /// after a departure the person is almost certainly still there, hours after it they
    /// could be anywhere, and "must have been home" would then be a guess wearing the
    /// clothes of a measurement.
    /// Landed diagnostics-only first, on purpose: `boundStay`/`extendStay` already
    /// caused a nine-day repair loop from an earlier tuning attempt (see above), so
    /// this logs what `showsDeparture` would have refused for a real trial period
    /// before it is trusted to actually hold a stay closed. Flip once logged
    /// decisions have been compared against a few real mornings, not on first read
    /// of the code.
    nonisolated static let enforceLocationJournalDepartureCheck = false

    /// The stay `extendStay` would reach forward to meet `movement`, before any
    /// location-journal check. Split out so `boundStays` can ask the same question
    /// for dry-run logging without duplicating the selection rule, and without
    /// `extendStay` itself needing to touch `Diagnostics` (which is `@MainActor`;
    /// this stays `nonisolated` so reconciliation can run off the main actor).
    /// Internal rather than private: tests exercise the location-evidence decision
    /// directly, independent of `enforceLocationJournalDepartureCheck`'s current
    /// value, the same reason `boundStays` itself is internal rather than private.
    nonisolated static func candidateToExtend(upTo movement: DateInterval, stays: [Visit],
                                                       activities: [Visit]) -> Visit? {
        let candidates = stays.filter { stay in
            guard stay.visitSource == .automatic, let departure = stay.departure else { return false }
            guard departure < movement.start,
                  movement.start.timeIntervalSince(departure) <= departureCatchUp else { return false }
            // Anything recorded inside the gap is evidence of what happened in it, and
            // it is not this. A stay is only stretched across silence.
            //
            // `stays` as well as `activities`, because a gap containing another *place*
            // is the least silent gap there is, and checking movement alone could not
            // see one. `reconcileAll` passes only movement records here, so a stay in
            // the gap did not block the extension and the person was read as never
            // having left the first place -- straight over the top of somewhere they
            // demonstrably were.
            //
            // That produced a permanent repair loop, because the two halves run in one
            // audit: `resolveLocationCallbacks` trims the earlier stay back to the later
            // arrival, then `reconcileAll` stretches it forward again to the journey
            // that follows, restoring the exact overlap that was just removed. A real
            // one (Home 2026-08-07 22:04:45Z, Gracemere Shoppingworld at 23:36:03Z, walk
            // at 23:48:19Z) logged "Overlapping stay closed ... trimmed" on every launch
            // for nine days while the store never changed.
            let occupants = activities + stays
            return !occupants.contains { other in
                other !== stay && other.arrival < movement.start
                    && (other.departure ?? other.arrival) > departure
            }
        }
        return candidates.max(by: { ($0.departure ?? $0.arrival) < ($1.departure ?? $1.arrival) })
    }

    /// Whether the location journal shows `stay` was already away, beyond
    /// `departureRadius`, sometime between its recorded departure and `movement`
    /// starting -- the evidence `extendStay`'s own occupancy check cannot see,
    /// because neither a HealthKit walking/workout record nor silence itself carries
    /// coordinates. `nil` when there is nothing to check (no context, or the stay has
    /// no departure yet).
    nonisolated static func extensionRefusedByLocationEvidence(
        for stay: Visit, upTo movement: DateInterval, context: ModelContext?
    ) -> Bool {
        guard let context, let departure = stay.departure else { return false }
        return LocationJournal.showsDeparture(fromStayAt: stay.coordinate,
                                              in: DateInterval(start: departure, end: movement.start),
                                              beyond: departureRadius, context: context)
    }

    @discardableResult
    nonisolated static func extendStay(upTo movement: DateInterval, stays: [Visit],
                                       activities: [Visit], context: ModelContext? = nil) -> Bool {
        guard let stay = candidateToExtend(upTo: movement, stays: stays, activities: activities)
        else { return false }
        if enforceLocationJournalDepartureCheck,
           extensionRefusedByLocationEvidence(for: stay, upTo: movement, context: context) {
            return false
        }
        stay.departure = movement.start
        return true
    }

    /// How long after a stay closes a following journey can still be read as the moment
    /// the person actually left. Half an hour: long enough for waking up, getting ready
    /// and finding your shoes, short enough that it cannot swallow a real absence.
    nonisolated static let departureCatchUp: TimeInterval = 30 * 60

    /// The stay a movement record began inside. Only Core Location's own timing is
    /// ever adjusted: a manual entry states when the person says they were somewhere,
    /// and no device sample overrides that.
    private nonisolated static func containingStay(at moment: Date, stays: [Visit],
                                                   requiringDeparture: Bool,
                                                   now: Date = .now) -> Visit? {
        stays.filter { stay in
            guard stay.visitSource == .automatic, stay.arrival < moment else { return false }
            guard let departure = stay.departure else { return !requiringDeparture }
            return departure > moment
        }.max { $0.arrival < $1.arrival }
    }


    /// Splits a stay around a journey that its own path proves left the place.
    ///
    /// This is the case Core Location cannot report: leave home on foot, walk a
    /// kilometre, come back, and no region was ever exited, so there is no departure
    /// and no new arrival. Reading that as leaving used to be a guess — it invented a
    /// return that never happened for anyone who simply walked about indoors. With a
    /// route it is a measurement, so the stay is bounded at the walk, and resumed
    /// afterwards only when the path came back to it.
    /// Returns the resumed stay, for the caller to insert.
    private static func separateStay(around movement: Visit, stays: [Visit], now: Date) -> Visit? {
        guard let end = movement.departure, end > movement.arrival,
              let stay = containingStay(at: movement.arrival, stays: stays, requiringDeparture: false, now: now),
              leftStay(movement, stay: stay) == true else { return nil }
        let wasOpen = stay.departure == nil
        let stayEnd = stay.departure ?? now
        stay.departure = movement.arrival
        // The walk ends back inside the place, so the person returned to it. A walk
        // that ends elsewhere is left alone: the next arrival says where they went.
        guard let last = movement.route.last,
              last.location.distance(from: CLLocation(latitude: stay.latitude, longitude: stay.longitude))
                <= departureRadius else { return nil }
        // A closed stay that outlived the walk resumes to its recorded end; an open
        // one resumes as the current stay.
        let resumedEnd: Date? = wasOpen ? nil : (stayEnd > end ? stayEnd : nil)
        guard resumedEnd == nil || resumedEnd! > end else { return nil }
        return continuation(of: stay, from: end, until: resumedEnd)
    }


    /// The same stay, resumed. Confidence and candidates carry over because it is the
    /// same place; the note does not, since it was written about the earlier stay.
    private nonisolated static func continuation(of stay: Visit, from arrival: Date,
                                                 until departure: Date?) -> Visit {
        Visit(arrival: arrival, departure: departure,
              latitude: stay.latitude, longitude: stay.longitude,
              placeName: stay.placeName, inferredActivity: stay.inferredActivity,
              userActivity: stay.userActivity, source: stay.source,
              recognitionConfidence: stay.recognitionConfidence,
              candidateData: stay.candidateData)
    }


    /// How long after a health-walking or motion record ends a started workout may
    /// still begin and be read as the same excursion, rather than a separate outing.
    /// Waking up, moving around, and pressing start on a workout is minutes, not hours
    /// — wide enough for that, narrow enough that a real gap before a much later,
    /// unrelated walk is not mistaken for one long lead-in.
    private nonisolated static let workoutLeadInWindow: TimeInterval = 15 * 60

    /// Whether a weaker movement record is steps taken before a workout began, rather
    /// than an outing of its own.
    ///
    /// `boundStays` processes every movement record independently, earliest first, and
    /// the first one to reach a stay wins. A `health-walking` or `motion` record for the
    /// same walk as a workout routinely starts earlier — steps taken getting ready
    /// before the workout is started — so it reached the stay first and pulled its
    /// departure back to *those* steps rather than to when the workout actually began.
    /// "I don't need those steps at home included in the walking time... the workout
    /// can just be the walk" — so a record answering this is excluded from binding or
    /// extending anything at all; the workout's own record does that, and the stay it
    /// is bound to then naturally absorbs this record's time as its own, the same way
    /// it already absorbs any other movement recorded inside it.
    private nonisolated static func isWorkoutLeadIn(_ record: Visit, sessions: [WorkoutJourneys.WorkoutSession]) -> Bool {
        guard VisitSource(rawValue: record.source) == .healthWalking || VisitSource(rawValue: record.source) == .motion,
              let departure = record.departure else { return false }
        return sessions.contains { session in
            let gap = session.interval.start.timeIntervalSince(departure)
            return gap >= 0 && gap <= workoutLeadInWindow
        }
    }

    /// Resolves every movement record against the stay it left, in date order, so a day
    /// with several outings settles each one against the right stay.
    ///
    /// Internal rather than private: reconciliation drives this, and the two live in
    /// different files now. It is the one member of this concern another one reaches for.
    @discardableResult
    static func boundStays(around activities: [Visit], stays: [Visit],
                                   context: ModelContext? = nil, now: Date = .now) -> [Visit] {
        var stays = stays
        var resumed: [Visit] = []
        let sessions = activities.filter(isWorkoutSession).compactMap { WorkoutJourneys.WorkoutSession($0, now: now) }
        // Excluded here, not only from the loop below: `extendStay` separately treats
        // anything recorded inside a gap as evidence the gap should not be stretched
        // across, and a lead-in record left in that list would still block the very
        // extension this whole exclusion exists to allow.
        let consideredActivities = activities.filter { !isWorkoutLeadIn($0, sessions: sessions) }
        let movement = consideredActivities
            .filter { isMovementActivity($0) && $0.departure != nil }
            .sorted { $0.arrival < $1.arrival }
        for record in movement {
            guard let end = record.departure, end > record.arrival else { continue }
            let interval = DateInterval(start: record.arrival, end: end)
            // A recorded path is the stronger evidence, so it is asked first; the
            // timing rule only decides journeys with no route to consult.
            if let context, let stay = separateStay(around: record, stays: stays, now: now) {
                context.insert(stay)
                stays.append(stay)
                resumed.append(stay)
                continue
            }
            // The two timing corrections are opposites and cannot both apply: a stay's
            // departure either lands after this journey began, or before it. Try to pull
            // it back first, and only reach forward when there was nothing to pull.
            let bounded = boundStay(departedWith: interval, stays: stays)
            // Computed on the unmutated stays, before extendStay can change anything,
            // so the dry-run log reflects what was actually decided rather than a
            // stale re-evaluation against a departure that has already moved.
            if !bounded, let context, record.arrival > now.addingTimeInterval(-24 * 60 * 60),
               let candidate = candidateToExtend(upTo: interval, stays: stays, activities: consideredActivities),
               extensionRefusedByLocationEvidence(for: candidate, upTo: interval, context: context) {
                Diagnostics.record(context, subsystem: "Timeline",
                                   message: "Would have held \(candidate.placeName) open until "
                                          + "\(interval.start.formatted(date: .omitted, time: .shortened)), but "
                                          + "the location journal shows a real departure inside that gap. "
                                          + (enforceLocationJournalDepartureCheck
                                             ? "Not extending." : "Extending anyway (dry run)."),
                                   severity: "info")
            }
            let extended = bounded ? false : extendStay(upTo: interval, stays: stays,
                                                        activities: consideredActivities, context: context)
            // Reported for recent journeys only, and only when a context is driving this,
            // so the log says what happened to today's records without writing hundreds
            // of lines about months of history. Everything else about this pass has been
            // invisible, which is why it took four wrong theories to get here.
            if let context, record.arrival > now.addingTimeInterval(-24 * 60 * 60) {
                let outcome = bounded ? "bounded the stay it left"
                    : extended ? "held the stay open until it began"
                    : "changed nothing"
                Diagnostics.record(context, subsystem: "Timeline",
                                   message: "Journey \(record.arrival.formatted(date: .omitted, time: .shortened)): \(outcome).",
                                   severity: "info")
            }
        }
        return resumed
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
            stay.locationResolutionExplanation = .movement
            stay.setResolutionState(.superseded, actor: .automation)
            rejoined += 1
        }
        return rejoined
    }

    private static func canRejoin(_ previous: Visit, _ stay: Visit, walking: [Visit]) -> Bool {
        // Only LifeLog's own inference is undone; a manual entry is left as written.
        guard previous.visitSource == .automatic, stay.visitSource == .automatic,
              let departure = previous.departure, stay.arrival > departure else { return false }
        let gap = DateInterval(start: departure, end: stay.arrival)
        // A long absence is not repaired. Whatever happened in an hour away, claiming
        // the person never left would be a bigger error than leaving the two rows.
        guard gap.duration <= 60 * 60 else { return false }
        guard NameKey.matching(previous.placeName) == NameKey.matching(stay.placeName),
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
}
