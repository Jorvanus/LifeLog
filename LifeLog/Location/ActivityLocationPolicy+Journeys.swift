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
    @discardableResult
    nonisolated static func boundStay(departedWith movement: DateInterval, stays: [Visit]) -> Bool {
        guard movement.duration > 0,
              let stay = containingStay(at: movement.start, stays: stays, requiringDeparture: true),
              let departure = stay.departure, departure <= movement.end else { return false }
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
    @discardableResult
    nonisolated static func extendStay(upTo movement: DateInterval, stays: [Visit],
                                       activities: [Visit]) -> Bool {
        let candidates = stays.filter { stay in
            guard stay.source == "automatic", let departure = stay.departure else { return false }
            guard departure < movement.start,
                  movement.start.timeIntervalSince(departure) <= departureCatchUp else { return false }
            // Anything recorded inside the gap is evidence of what happened in it, and
            // it is not this. A stay is only stretched across silence.
            return !activities.contains { other in
                other !== stay && other.arrival < movement.start
                    && (other.departure ?? other.arrival) > departure
            }
        }
        guard let stay = candidates.max(by: { ($0.departure ?? $0.arrival) < ($1.departure ?? $1.arrival) })
        else { return false }
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
            guard stay.source == "automatic", stay.arrival < moment else { return false }
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
        let movement = activities
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
            let extended = bounded ? false : extendStay(upTo: interval, stays: stays,
                                                        activities: activities)
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
