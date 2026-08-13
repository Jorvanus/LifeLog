import Foundation
import SwiftData
import CoreLocation

/// What a started workout proves about the stays recorded around it.
///
/// Split out of `ActivityLocationPolicy`, which had grown to 985 lines across six
/// concerns. This one is genuinely separable: a workout is the person's own account of
/// a stretch of time, and everything here follows from taking that account seriously —
/// which stays it explains away, and how a session cut into pieces is put back
/// together. Nothing in the policy reaches back into it.
@MainActor
enum WorkoutJourneys {
    /// Marks `repairSplitWorkouts` as done, so it runs once rather than on every
    /// appearance. Cleared by a Health re-import, which restores the routes the repair
    /// needs to judge the stays it could not decide the first time.
    static let splitWorkoutRepairKey = "workout-splits-repaired-v1"


    /// Puts back together the workouts an earlier build cut up as it imported them.
    ///
    /// Every fragment of one workout carries that workout's HealthKit sample UUID, so
    /// this needs no heuristic about gaps or timing: rows sharing a sample id are rows
    /// of one session, and one session is one row. The surviving row takes the full
    /// span and every fragment's share of the path.
    ///
    /// The path still has a hole in it — the stretch inside the stay was subtracted
    /// before it was ever written, and nothing here can invent it. Health still holds
    /// the original, so *Settings → Reimport Health history* restores it, and clears
    /// this repair's flag so the pass runs again with a complete route to judge by.
    @discardableResult
    static func repairSplitWorkouts(context: ModelContext, now: Date = .now) throws -> Int {
        let visits = try ActivityLocationPolicy.fetchPolicyVisits(context: context)
        var fragments: [[UUID]: [Visit]] = [:]
        for workout in visits where ActivityLocationPolicy.isWorkoutSession(workout) {
            guard let ids = workout.healthKitSampleIDs, !ids.isEmpty else { continue }
            fragments[ids, default: []].append(workout)
        }

        var rejoined = 0
        var discarded: Set<PersistentIdentifier> = []
        for group in fragments.values where group.count > 1 {
            let ordered = group.sorted { $0.arrival < $1.arrival }
            guard let host = ordered.first else { continue }
            for extra in ordered.dropFirst() {
                host.departure = max(host.departure ?? host.arrival, extra.departure ?? extra.arrival)
                host.route = merge(host.route, extra.route)
                discarded.insert(extra.persistentModelID)
                context.delete(extra)
                rejoined += 1
            }
            LocationDiagnostics.record(.merged, subject: "Split workout",
                                       reason: "\(group.count) rows shared one HealthKit session",
                                       evidence: "\(host.placeName) rejoined as a single journey",
                                       context: context)
        }

        // Now that each workout covers its whole session again, the stays it merely
        // walked past overlap it once more, which is what makes them recognisable.
        let sessions = visits
            .filter { ActivityLocationPolicy.isWorkoutSession($0) && !discarded.contains($0.persistentModelID) }
            .compactMap { WorkoutSession($0, now: now) }
        let live = visits.filter { ActivityLocationPolicy.isLocationVisit($0) && !ActivityLocationPolicy.isSupersededLocation($0) }
        let superseded = WorkoutJourneys.supersedePassingStays(during: sessions, stays: live, context: context, now: now)
        return rejoined + superseded
    }

    /// One path from two, in time order and without repeating a point a re-import has
    /// already delivered to both halves.
    private nonisolated static func merge(_ route: [RoutePoint], _ other: [RoutePoint]) -> [RoutePoint] {
        var seen = Set<Date>()
        return (route + other).sorted { $0.time < $1.time }.filter { seen.insert($0.time).inserted }
    }

    /// A stay recorded while a workout was running is the walk going past, not a
    /// destination.
    ///
    /// Core Location is at its least reliable in exactly this situation: moving through
    /// an area that has businesses in it, it reports an arrival, and Maps names whatever
    /// sits nearest. LifeLog then puts "Is this right? Gracemere Lake Golf Club" in the
    /// review queue about a lap of the lake. The workout is the person's own account of
    /// that time, so it wins and the guess is superseded rather than asked about.
    ///
    /// Guarded so a genuine stop survives, because these are places people really do go:
    ///
    /// - a stay that mostly outlives the workout is never touched — coverage does this,
    ///   not the place's name, so stopping home for good after a walk leaves a stay
    ///   reaching well past the session and survives without anything knowing it is Home;
    /// - a stay the person named or corrected themselves is never touched;
    /// - with a route, the path itself decides: kept moving throughout supersedes it,
    ///   stayed put keeps it, regardless of anything else known about the place.
    ///
    /// Without a route, a stay survives unless it is both unanswered and brief — until
    /// 2026-08-09, `recognitionConfidence == "learned"` protected it regardless of
    /// duration, on the theory that a confidently named place was a real destination.
    /// It is not: "learned" means Core Location has matched this coordinate to a Saved
    /// Place before, which is a fact about the *place*, not about whether the person
    /// stopped *this time*. Cedric Archer Park sits on a walking route and is passed
    /// most days; every pass came back "learned" and none of them were ever asked
    /// about, however briefly the walk was there. The brief-stay requirement is what
    /// still protects Home when a workout happens to cover it whole. A route can still
    /// prove a genuine stop outright — the branch above this one — so this only affects
    /// cases with no path to consult at all.
    ///
    /// Superseded, not deleted: the row keeps its coordinates and can be read back in
    /// Diagnostics, which matters when the guard turns out to be wrong.
    /// A stretch of time the person declared a workout, with whatever path it recorded.
    /// Carried as a value so the import actor can ask about a record it has not written
    /// yet, and the repair pass can ask about one it has just put back together.
    struct WorkoutSession: Sendable {
        let interval: DateInterval
        let route: [RoutePoint]

        init(interval: DateInterval, route: [RoutePoint] = []) {
            self.interval = interval
            self.route = route
        }

        init?(_ workout: Visit, now: Date = .now) {
            let end = workout.departure ?? now
            guard end > workout.arrival else { return nil }
            self.init(interval: DateInterval(start: workout.arrival, end: end), route: workout.route)
        }
    }

    @discardableResult
    static func supersedePassingStays(during workouts: [Visit], stays: [Visit],
                                      context: ModelContext, now: Date = .now) -> Int {
        supersedePassingStays(during: workouts.filter(ActivityLocationPolicy.isWorkoutSession).compactMap { WorkoutSession($0, now: now) },
                              stays: stays, context: context, now: now)
    }

    @discardableResult
    static func supersedePassingStays(during sessions: [WorkoutSession], stays: [Visit],
                                      context: ModelContext, now: Date = .now) -> Int {
        let passed = passingStays(during: sessions, stays: stays, now: now)
        for entry in passed {
            LocationDiagnostics.record(.superseded, subject: "Stay during a workout",
                                       reason: entry.reason,
                                       evidence: "\(entry.stay.placeName) passed through, not visited",
                                       context: context)
        }
        return passed.count
    }

    /// Marks and returns the stays a workout shows were walked past rather than visited.
    ///
    /// Nonisolated so the import actor can apply the rule on its own context, ahead of
    /// letting any stay cut up the record it is about to write. The main-actor overload
    /// above is the same pass with a diagnostic line per decision.
    @discardableResult
    nonisolated static func passingStays(during sessions: [WorkoutSession], stays: [Visit],
                                         now: Date = .now) -> [(stay: Visit, reason: String)] {
        guard !sessions.isEmpty else { return [] }

        var passed: [(stay: Visit, reason: String)] = []
        for stay in stays where ActivityLocationPolicy.isLocationVisit(stay) && !ActivityLocationPolicy.isSupersededLocation(stay) {
            // Only Core Location's own guess is ever withdrawn. A place the person
            // entered themselves is not a guess and is never touched.
            guard stay.source == "automatic", !stay.isIgnored else { continue }
            let stayEnd = stay.departure ?? now
            let duration = stayEnd.timeIntervalSince(stay.arrival)
            guard duration > 0 else { continue }
            let window = DateInterval(start: stay.arrival, end: stayEnd)
            let covered = sessions.reduce(0.0) { total, session in
                total + max(0, min(stayEnd, session.interval.end)
                    .timeIntervalSince(max(stay.arrival, session.interval.start)))
            }
            guard covered / duration >= passingStayCoverage else { continue }
            let share = "\(Int((covered / duration * 100).rounded()))% of it fell inside a started workout"

            // The path is asked first, and it settles the question outright: ground
            // covered at a walking pace for the whole time a stay claims to have been
            // holding someone is a measurement that they never stopped there. That
            // outranks how confident Core Location was and how the place was named,
            // which is the whole point — a saved place walked through is still walked
            // through, and its geofence should not cut the walk into pieces.
            let verdicts = sessions.compactMap { keptMoving($0, through: window) }
            let reason: String
            if verdicts.isEmpty {
                // No path to consult. Fall back to the weaker test, which only withdraws
                // a guess nobody has personally agreed with and that was brief enough to
                // be a pass in the first place — the same `briefStayLimit` the review
                // queue itself uses to decide whether something is "somewhere passed"
                // rather than "somewhere spent time". Being a known Saved Place is not
                // agreement: it is Core Location recognising a coordinate it has seen
                // before, a fact about the place rather than about this particular pass.
                // A workout begun before leaving the house can cover an entire half-hour
                // stay at Home, and full coverage there must not read as evidence of
                // nothing — the duration is the evidence, and only an explicit answer
                // (a chosen activity) or a short stay overrides it.
                guard stay.userActivity == nil,
                      duration <= ReviewQueue.briefStayLimit else { continue }
                reason = share
            } else {
                guard verdicts.contains(true) else { continue }
                reason = "\(share), and its path kept moving throughout"
            }

            stay.departure = stay.arrival
            stay.source = ActivityLocationPolicy.supersededLocationSource
            stay.locationResolutionExplanation = .movement
            stay.setResolutionState(.superseded, actor: .automation)
            passed.append((stay, reason))
        }
        return passed
    }

    /// Whether a session's own path was still moving across a stay's whole window.
    ///
    /// This is the question that separates "I walked through the park" from "I stopped
    /// at the park", and distance from the place cannot answer it: a two-minute stay
    /// recorded mid-walk never gets far from its own centre, yet nothing about it was
    /// a stop. Pace does answer it. Standing still leaves a few centimetres per second
    /// of GPS noise; any real walking is several times that.
    ///
    /// `nil` when there is no usable path — too few points, or samples covering less
    /// than half the window, which a route with a gap in it would otherwise fail.
    private nonisolated static func keptMoving(_ session: WorkoutSession,
                                               through window: DateInterval) -> Bool? {
        let points = session.route.filter { window.contains($0.time) }.sorted { $0.time < $1.time }
        guard points.count > 1, let first = points.first, let last = points.last else { return nil }
        let sampled = last.time.timeIntervalSince(first.time)
        guard sampled > 0, sampled >= window.duration / 2 else { return nil }
        let covered = zip(points, points.dropFirst()).reduce(0.0) { total, pair in
            total + pair.1.location.distance(from: pair.0.location)
        }
        return covered / sampled >= passingStayPace
    }

    /// How much of a stay must fall inside a workout before it reads as passing through.
    /// Deliberately a clear majority rather than "any overlap": a walk that ends when the
    /// person arrives somewhere overlaps that arrival slightly, and that arrival is real.
    private nonisolated static let passingStayCoverage = 0.75

    /// Metres per second — about 1.8 km/h — below which a path is not going anywhere.
    /// Well under a walking pace, so a slow amble still reads as movement, and well
    /// above the drift of a phone sitting on a table.
    private nonisolated static let passingStayPace: CLLocationDistance = 0.5

    /// A started workout is also the person's own account of *their own movement*, not
    /// only of whether a nearby stay was real. `health-walking` and `motion` are both
    /// weaker, inferred guesses at the same underlying event — step counts, or Core
    /// Motion's own classification — and once a workout explains a stretch of time, a
    /// weaker record covering the same stretch is not a second walk. It is the same
    /// walk, counted twice: cross-checked against Life Cycle, run in parallel the whole
    /// time, which showed one walk on every morning this showed two or three.
    ///
    /// Unlike `passingStays`, this needs no coverage or pace threshold — the question is
    /// not whether the workout is telling the truth about a stop, it is which record
    /// already explains this stretch of time more precisely. Any overlap at all is the
    /// workout's account of that portion, so it is simply subtracted, the same way a
    /// stay's occupied time is already subtracted from movement that happens inside it.
    ///
    /// Nonisolated for the same reason `passingStays` is: the health-walking record for
    /// a walk is frequently imported in an earlier batch than the workout that explains
    /// it — different HealthKit queries, different delivery timing — so this has to be
    /// re-appliable after the fact rather than caught once at the moment either side is
    /// written. `ActivityLocationPolicy.reapplyRecentMovementAbsorption` is that re-apply.
    @discardableResult
    nonisolated static func absorbOverlappingMovement(during sessions: [WorkoutSession], activities: [Visit],
                                                       context: ModelContext, now: Date = .now)
    -> [(activity: Visit, reason: String)] {
        guard !sessions.isEmpty else { return [] }
        let occupied = sessions.map(\.interval)
        var changed: [(Visit, String)] = []
        for activity in activities where activity.source == "health-walking" || activity.source == "motion" {
            let end = activity.departure ?? now
            guard end > activity.arrival else { continue }
            let interval = DateInterval(start: activity.arrival, end: end)
            guard sessions.contains(where: { $0.interval.start < end && $0.interval.end > activity.arrival })
            else { continue }
            let minimum = ActivityLocationPolicy.minimumRetainedDuration(for: activity.source)
            let remaining = ActivityLocationPolicy.subtract(occupied, from: interval)
                .filter { $0.duration >= minimum }
            guard remaining.count != 1 || remaining[0] != interval else { continue }
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
                    context.insert(ActivityLocationPolicy.copy(of: activity, interval: segment))
                }
            }
            changed.append((activity, "a started workout already accounts for this stretch"))
        }
        return changed
    }

    /// The same rule, with a diagnostic line per decision — the pass the archive-wide
    /// reconciliation and the recent-day re-apply both call.
    @discardableResult
    static func recordAbsorbedMovement(during sessions: [WorkoutSession], activities: [Visit],
                                       context: ModelContext, now: Date = .now) -> Int {
        let changed = absorbOverlappingMovement(during: sessions, activities: activities,
                                                context: context, now: now)
        for (activity, reason) in changed {
            LocationDiagnostics.record(.superseded, subject: "\(activity.source) during a workout",
                                       reason: reason, context: context)
        }
        return changed.count
    }
}
