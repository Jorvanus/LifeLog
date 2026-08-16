import Foundation
import SwiftData
import CoreLocation

/// Resolving what Core Location actually reported: duplicate callbacks, overlapping
/// stays at one place, departures matched to arrivals, and stays left open.
///
/// One of six files `ActivityLocationPolicy` was split into. It had reached 985 lines
/// across six concerns, interleaved rather than merely adjacent. Same type, same call
/// sites — only the text moved.
extension ActivityLocationPolicy {

    /// The small amount of evidence a normal callback is allowed to repair. The
    /// stable ID is deliberately carried alongside the callback interval: row IDs
    /// are store-local, while a delayed Maps/departure callback must keep referring
    /// to the same visit after a save or a resolver pass.
    struct IncrementalMutation: Sendable {
        let affectedVisitID: UUID
        let callbackInterval: DateInterval
        let coordinate: CLLocationCoordinate2D?
        let reason: String

        init(affectedVisit: Visit, callbackInterval: DateInterval? = nil,
             coordinate: CLLocationCoordinate2D? = nil, reason: String) {
            self.affectedVisitID = affectedVisit.stableID
            let end = affectedVisit.departure ?? affectedVisit.arrival
            self.callbackInterval = callbackInterval ?? DateInterval(start: affectedVisit.arrival, end: end)
            self.coordinate = coordinate
            self.reason = reason
        }
    }

    /// A delayed Core Location callback may be hours old, but it only changes its
    /// own neighbouring stays. This window contains the earlier/later destination
    /// needed to clamp an overlap plus a modest spatial halo for GPS drift. Open
    /// stays are fetched separately, regardless of age, because any one of them
    /// can be the stay a new arrival closes.
    nonisolated static let incrementalRepairPadding: TimeInterval = 12 * 60 * 60
    nonisolated static let incrementalSpatialRadius: CLLocationDistance = 1_500

    /// Normal arrival, departure, correction, and Maps mutations use this bounded
    /// path. It never hydrates the complete Visit or correction archive: it fetches
    /// open stays and a temporal repair window around the callback, then repairs only
    /// the local ordering and adjacent journeys.
    @discardableResult
    static func resolveAfterLocationMutation(context: ModelContext,
                                             mutation: IncrementalMutation) throws -> Int {
        let startedAt = Date.now
        let candidates = try incrementalRepairVisits(context: context, mutation: mutation)
        let repairs = resolveLocationCallbacks(in: candidates, context: context)
        let stateChanges = reconcileResolutionStates(in: candidates)
        try updateTravelDescriptions(context: context, around: mutation.callbackInterval,
                                     candidates: candidates)
        Diagnostics.budget(context, subsystem: "Location resolver", operation: "incremental mutation",
                           startedAt: startedAt, budget: Diagnostics.PerformanceBudget.locationMutation,
                           itemCount: candidates.count)
        Diagnostics.locationMetric(context, operation: "incremental_resolution",
                                   durationMs: Int((Date.now.timeIntervalSince(startedAt) * 1000).rounded()),
                                   candidateCount: candidates.count, repairs: repairs + stateChanges)
        return repairs + stateChanges
    }

    /// Full-store recovery is intentionally explicit. It is appropriate after a
    /// migration, restore, relaunch recovery, Diagnostics validation, or a manual
    /// repair — never as the ordinary callback path above.
    @discardableResult
    static func runFullStoreAudit(context: ModelContext, reason: String) throws -> Int {
        let startedAt = Date.now
        let repairs = try resolveLocationCallbacks(context: context)
        try reconcileAll(context: context)
        try updateTravelDescriptions(context: context)
        let stateChanges = try reconcileResolutionStates(context: context)
        let report = try validateLocationResolution(context: context)
        report.record(context: context, reason: reason, repairs: repairs + stateChanges)
        let visits = try context.fetch(FetchDescriptor<Visit>())
        for visit in visits {
            visit.stageUnreadablePayloadDiagnostics(in: context)
        }
        let count = visits.count
        Diagnostics.budget(context, subsystem: "Location resolver", operation: "full-store audit",
                           startedAt: startedAt, budget: Diagnostics.PerformanceBudget.locationFullAudit,
                           itemCount: count)
        return repairs + stateChanges
    }

    /// Compatibility for older maintenance call sites. New normal mutations must
    /// pass an `IncrementalMutation`; this overload remains an explicit audit so a
    /// missed migration/recovery call cannot silently become a partial repair.
    @available(*, deprecated, message: "Use IncrementalMutation for callbacks or runFullStoreAudit for maintenance.")
    @discardableResult
    static func resolveAfterLocationMutation(context: ModelContext, reason: String) throws -> Int {
        try runFullStoreAudit(context: context, reason: reason)
    }

    private static func incrementalRepairVisits(context: ModelContext,
                                                mutation: IncrementalMutation) throws -> [Visit] {
        let start = mutation.callbackInterval.start.addingTimeInterval(-incrementalRepairPadding)
        let end = mutation.callbackInterval.end.addingTimeInterval(incrementalRepairPadding)
        let descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate {
                $0.source != "imported-journal" &&
                (($0.arrival >= start && $0.arrival <= end) || $0.departure == nil)
            },
            sortBy: [SortDescriptor(\.arrival)]
        )
        let temporal = try context.fetch(descriptor)
        guard let coordinate = mutation.coordinate, CLLocationCoordinate2DIsValid(coordinate) else {
            return temporal
        }
        let callbackLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        // Keep every temporal neighbour (a trip can join different businesses), and
        // retain nearby open records even if their timestamp is malformed/old. This is
        // a repair halo, not a place-identity matcher; Maps identifiers still win in
        // the resolver itself.
        return temporal.filter { visit in
            let location = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
            return visit.arrival >= start && visit.arrival <= end ||
                location.distance(from: callbackLocation) <= incrementalSpatialRadius || visit.departure == nil
        }
    }

    /// Applies `derivedAutomaticResolutionState` to every visit as the resolver's
    /// automation actor. A visit the person has ignored, or confirmed, is left
    /// exactly as it was — `setResolutionState` enforces both, not this loop —
    /// so this can safely run unconditionally on every resolve rather than trying
    /// to track which visits actually need a second look.
    @discardableResult
    static func reconcileResolutionStates(context: ModelContext) throws -> Int {
        let visits = try context.fetch(FetchDescriptor<Visit>())
        return reconcileResolutionStates(in: visits)
    }

    @discardableResult
    static func reconcileResolutionStates(in visits: [Visit]) -> Int {
        visits.reduce(into: 0) { changed, visit in
            if visit.setResolutionState(derivedAutomaticResolutionState(for: visit), actor: .automation) {
                changed += 1
            }
        }
    }

    /// Read-only validation for the resolved location timeline. Raw, superseded
    /// callbacks intentionally remain in the store for diagnostics, but no consumer
    /// may treat them as a visible resolved visit.
    static func validateLocationResolution(context: ModelContext, now: Date = .now) throws -> LocationResolutionValidation {
        let visits = try context.fetch(FetchDescriptor<Visit>(sortBy: [SortDescriptor(\.arrival)]))
        let locations = visits.filter(isLocationVisit)
        let resolved = locations.filter { $0.resolutionState == .resolved }
        let currentCount = resolved.filter { $0.departure == nil }.count
        let negativeDurations = resolved.filter { ($0.departure ?? $0.arrival) < $0.arrival }.count

        var overlaps = 0
        for (index, visit) in resolved.enumerated() where index > 0 {
            let preceding = resolved[index - 1]
            let precedingEnd = preceding.departure ?? now
            if precedingEnd > visit.arrival { overlaps += 1 }
        }

        let visibleSuperseded = locations.filter { visit in
            guard visit.resolutionState == .superseded else { return false }
            // Both presentation policies must reject superseded callbacks. This
            // catches an accidental future policy regression in Diagnostics.
            return shouldShowInTimeline(visit, locationVisits: resolved, now: now) ||
                shouldShowInInsights(visit, locationVisits: resolved, now: now)
        }.count

        let manualCorrections = try context.fetch(FetchDescriptor<VisitCorrection>())
            .filter { $0.reason.localizedCaseInsensitiveContains("manual") }
        // Corrections predate stable visit IDs, so their composite is retained only
        // here as a legacy index. This replaces the old every-correction-against-
        // every-correction scan on each full diagnostics audit.
        let latestCorrections = Dictionary(manualCorrections.map { (legacyCorrectionKey($0.visitArrival, $0.latitude, $0.longitude), $0) },
                                           uniquingKeysWith: { latest, candidate in
            latest.changedAt >= candidate.changedAt ? latest : candidate
        })
        let visibleLocations = Dictionary(locations.filter { $0.resolutionState != .superseded }
            .map { (legacyCorrectionKey($0.arrival, $0.latitude, $0.longitude), $0) },
            uniquingKeysWith: { existing, candidate in existing.arrival >= candidate.arrival ? existing : candidate })
        let automationReplacements = latestCorrections.values.filter { correction in
            guard let visit = visibleLocations[legacyCorrectionKey(correction.visitArrival,
                                                                     correction.latitude, correction.longitude)] else { return false }
            // A user activity takes precedence over an inferred activity. If neither
            // the confirmed place nor their effective activity still agrees, some
            // later automation has replaced the correction.
            return visit.placeName != correction.newPlaceName || visit.activity != correction.newActivity
        }.count

        return LocationResolutionValidation(
            currentResolvedVisits: currentCount,
            resolvedOverlaps: overlaps,
            negativeDurations: negativeDurations,
            visibleSupersededVisits: visibleSuperseded,
            automationReplacements: automationReplacements
        )
    }

    /// Single resolver for callback order and overlap. Raw callbacks remain
    /// stored; duplicates are marked superseded and older open stays bounded.
    @discardableResult
    static func resolveLocationCallbacks(context: ModelContext) throws -> Int {
        let repaired = try closeSupersededOpenLocations(context: context)
        let marked = try deduplicateAutomaticLocations(context: context)
        let merged = try mergeOverlappingStays(context: context)
        let total = repaired + marked + merged
        if total > 0 {
            Diagnostics.locationMetric(context, operation: "resolver_repairs", repairs: total)
        }
        return total
    }

    @discardableResult
    static func resolveLocationCallbacks(in visits: [Visit], context: ModelContext) -> Int {
        let repaired = closeSupersededOpenLocations(in: visits, context: context)
        let marked = deduplicateAutomaticLocations(in: visits, context: context)
        let merged = mergeOverlappingStays(in: visits, context: context)
        let total = repaired + marked + merged
        if total > 0 {
            Diagnostics.locationMetric(context, operation: "incremental_resolver_repairs", repairs: total)
        }
        return total
    }


    /// Collapses stays that claim overlapping time at the same place.
    ///
    /// A large site is entered and re-entered as the phone moves around it, and a
    /// delayed departure callback can stretch the first arrival across all of them.
    /// A real capture held three "Work" stays for one day: 9:09am–3:49pm, with
    /// 10:17–11:04 and 11:17–12:42 sitting inside it, so Timeline listed one working
    /// day three times. Insights was unaffected — it already resolves overlap by
    /// slicing the day and awarding each slice to a single visit.
    ///
    /// Nothing is inferred here. A person cannot be at one place twice over the same
    /// minutes, so one continuous stay is the only reading the records allow — which
    /// is why this runs on every resolve rather than behind a one-time repair flag.
    @discardableResult
    static func mergeOverlappingStays(context: ModelContext, now: Date = .now) throws -> Int {
        let stays = try context.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source == "automatic" },
            sortBy: [SortDescriptor(\.arrival)]
        ))
        return mergeOverlappingStays(in: stays, context: context, now: now, recordsDiagnostics: true)
    }

    /// Incremental equivalent of the full archive merger. The dictionary keeps the
    /// active overlap host by strong Maps identity (or the old normalised-name
    /// fallback), avoiding the retained-array backwards search that made one callback
    /// grow quadratically with a dense archive.
    @discardableResult
    static func mergeOverlappingStays(in visits: [Visit], context: ModelContext,
                                      now: Date = .now) -> Int {
        mergeOverlappingStays(in: visits, context: context, now: now, recordsDiagnostics: false)
    }

    private static func mergeOverlappingStays(in visits: [Visit], context: ModelContext,
                                              now: Date, recordsDiagnostics: Bool) -> Int {
        let stays = visits.filter { $0.visitSource == .automatic }
            .sorted { $0.arrival < $1.arrival }
        var hosts: [String: Visit] = [:]
        var merged = 0
        for stay in stays {
            let keys = sameStayKeys(stay)
            guard !keys.isEmpty else { continue }
            guard let host = keys.lazy.compactMap({ hosts[$0] })
                .first(where: { describesSameStay($0, stay, now: now) }) else {
                for key in keys { hosts[key] = stay }
                continue
            }
            guard host !== stay else { continue }
            host.arrival = min(host.arrival, stay.arrival)
            switch (host.departure, stay.departure) {
            case (nil, _), (_, nil): host.departure = nil
            case let (left?, right?): host.departure = max(left, right)
            }
            if locationQuality(stay) > locationQuality(host), host.recognition != .confirmed {
                host.placeName = stay.placeName
                host.inferredActivity = stay.inferredActivity
                host.userActivity = stay.userActivity
                host.recognitionConfidence = stay.recognitionConfidence
            }
            stay.departure = stay.arrival
            stay.source = supersededLocationSource
            stay.locationResolutionExplanation = .duplicate
            stay.setResolutionState(.superseded, actor: .automation)
            merged += 1
            // Both the Maps and legacy name keys point to the retained row, so a
            // later delayed callback takes the strong identifier first but can still
            // meet an older identifier-less record at the same stay.
            for key in keys { hosts[key] = host }
            if recordsDiagnostics {
                LocationDiagnostics.record(.merged, subject: "Overlapping stay",
                                           reason: "two records claim the same minutes at one place",
                                           evidence: "\(stay.placeName) folded into \(host.placeName)",
                                           context: context)
            }
        }
        return merged
    }


    /// Two records of one stay: overlapping in time, agreeing on the place, and close
    /// enough together that GPS drift explains the difference. A placeholder name is
    /// never matched — "Identifying…" says nothing about which place this is.
    private static func describesSameStay(_ host: Visit, _ candidate: Visit, now: Date) -> Bool {
        let hostEnd = host.departure ?? now
        let candidateEnd = candidate.departure ?? now
        // Touching counts, not only overlapping. One stay recorded as two consecutive
        // rows meets exactly, and strict `>` read that as two separate stays.
        //
        // The shape that produced it: a walk whose route proves it left home ends, and
        // `separateStay` opens a continuation at the walk's end -- while Core Location's
        // own geofence has already recorded the arrival a minute or two earlier, because
        // the person got home and stood still while the workout was still running. On
        // 2026-08-16 that was Home 07:50:02-07:51:43 and Home 07:51:43-08:53:14: the same
        // arrival home, from two mechanisms, meeting at the instant the walk ended.
        // Nothing folded them -- `isDuplicateArrival` wants arrivals within 60s and these
        // were 101s apart, and this test wanted an overlap and they had none -- so the
        // pair sat on the timeline as two Home rows and a new pair appeared with each
        // walk. Only a zero gap is admitted: a stay that genuinely resumes after being
        // away has whatever it did in between sitting in the gap, and that keeps its own
        // row rather than being swallowed here.
        guard host.arrival <= candidateEnd, hostEnd >= candidate.arrival else { return false }
        let sameIdentity: Bool
        if let hostIdentifier = host.mapsIdentifier, let candidateIdentifier = candidate.mapsIdentifier {
            sameIdentity = hostIdentifier == candidateIdentifier
        } else {
            // Records before V6 and hand-pinned places have no Maps identifier.
            // NameKey is deliberately retained only as their compatibility fallback.
            sameIdentity = !Visit.isPlaceholderName(host.placeName) &&
                !Visit.isPlaceholderName(candidate.placeName) &&
                NameKey.matching(host.placeName) == NameKey.matching(candidate.placeName)
        }
        guard sameIdentity else { return false }
        return CLLocation(latitude: host.latitude, longitude: host.longitude)
            .distance(from: CLLocation(latitude: candidate.latitude, longitude: candidate.longitude)) <= 250
    }

    private static func sameStayKeys(_ visit: Visit) -> [String] {
        var keys: [String] = []
        if let identifier = visit.mapsIdentifier, !identifier.isEmpty { keys.append("maps:\(identifier)") }
        guard !Visit.isPlaceholderName(visit.placeName) else { return keys }
        let name = NameKey.matching(visit.placeName)
        if !name.isEmpty { keys.append("name:\(name)") }
        return keys
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
        // Stays closed or trimmed against a later arrival below. Counted for the same
        // reason `healed` is: a caller that saves only on a non-zero count discards an
        // uncounted mutation when trimming is the only work the pass did. `TimelineView`
        // is exactly such a caller (`if removed > 0 { try context.save() }`), so a pass
        // that trimmed an overlap and found no duplicate returned 0 and threw the trim
        // away. The incremental `deduplicateAutomaticLocations(in:context:)` has always
        // counted these two branches; only this full-store variant did not.
        //
        // Note what this does *not* explain: the relaunch audit reaches this through
        // `VisitMutationService.perform`, which saves unconditionally, so trims on that
        // path were already persisting. An overlap that survives repeated launches is a
        // different fault -- something re-widening the stay afterwards -- and is not
        // addressed here.
        var bounded = 0
        for stale in visits where isSupersededLocation(stale) && stale.departure == nil {
            stale.departure = stale.arrival
            healed += 1
        }
        for candidate in visits where !isSupersededLocation(candidate) {
            guard let previous = retained.last else {
                retained.append(candidate)
                continue
            }

            let sameIdentity: Bool
            if let previousIdentifier = previous.mapsIdentifier,
               let candidateIdentifier = candidate.mapsIdentifier {
                // A Maps identity is specific to one POI. In particular, do not let
                // neighbouring businesses merge just because Core Location delivered
                // two close callbacks while the person was moving between them.
                sameIdentity = previousIdentifier == candidateIdentifier
            } else if previous.hasPlaceholderName || candidate.hasPlaceholderName {
                // A still-identifying callback carries no venue claim of its own. It
                // may refine the named arrival it represents, but only at a much
                // tighter radius than a confirmed same-venue replay.
                sameIdentity = true
            } else {
                // Older and hand-pinned visits have no Maps identifier. Their stable
                // normalised name remains the compatibility identity in that case.
                sameIdentity = NameKey.matching(previous.placeName) == NameKey.matching(candidate.placeName)
            }
            let distance = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                .distance(from: CLLocation(latitude: candidate.latitude, longitude: candidate.longitude))
            // A named Saved Place and an earlier “Identifying…” callback can be
            // the same Core Location arrival. Names need not match, but the tighter
            // placeholder radius keeps a nearby business from being folded in.
            let replayTolerance: CLLocationDistance
            if previous.hasPlaceholderName || candidate.hasPlaceholderName {
                replayTolerance = 60
            } else if previous.mapsIdentifier != nil && previous.mapsIdentifier == candidate.mapsIdentifier {
                // An exact Maps POI identity is stronger than either GPS fix. Its
                // entrance, car park, and indoor location can legitimately land a
                // few hundred metres apart without becoming a different business.
                replayTolerance = 350
            } else {
                replayTolerance = 250
            }
            let sameArrival = abs(previous.arrival.timeIntervalSince(candidate.arrival)) <= 60 &&
                sameIdentity && distance <= replayTolerance
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
                previous.locationResolutionExplanation =
                    (previous.mapsIdentifier != nil && previous.mapsIdentifier == candidate.mapsIdentifier)
                    ? .mapsIdentifier : .coordinateTime
                // The candidate's interval now lives on `previous`, including its
                // open-endedness, so the superseded row must not stay open itself.
                // `closeSupersededOpenLocations` only fetches live locations and can
                // never reach it, which otherwise leaves a row whose `duration` grows
                // for the life of the store.
                candidate.departure = candidate.arrival
                candidate.source = supersededLocationSource
                candidate.locationResolutionExplanation = .duplicate
                candidate.setResolutionState(.superseded, actor: .automation)
                removed += 1
                LocationDiagnostics.record(.superseded, subject: "Duplicate callback",
                                           reason: "same arrival within 60s and \(Int(distance.rounded())) m",
                                           evidence: "\(candidate.placeName) folded into \(previous.placeName)",
                                           context: context)
            } else {
                // A later destination proves that an earlier open stay ended when this
                // visit began. Closing it prevents an open stay from consuming the
                // entire Insights interval.
                if previous.departure == nil, candidate.arrival > previous.arrival {
                    previous.departure = candidate.arrival
                    previous.locationResolutionExplanation = .coordinateTime
                    bounded += 1
                    LocationDiagnostics.record(.closed, subject: "Open stay",
                                               reason: "a later arrival proves it ended",
                                               evidence: "\(previous.placeName) closed at \(candidate.placeName)'s arrival",
                                               context: context)
                } else if let departure = previous.departure, departure > candidate.arrival {
                    // A departure callback can be delayed and is only ever clamped against
                    // `.now`, so it can land after a different place has already opened.
                    // A person cannot be at two places at once, so it's the earlier stay's
                    // own recorded departure that's wrong here, not the later arrival.
                    previous.departure = max(previous.arrival, candidate.arrival)
                    previous.locationResolutionExplanation = .coordinateTime
                    bounded += 1
                    LocationDiagnostics.record(.closed, subject: "Overlapping stay",
                                               reason: "a later arrival precedes this stay's recorded departure",
                                               evidence: "\(previous.placeName) trimmed to \(candidate.placeName)'s arrival",
                                               context: context)
                }
                retained.append(candidate)
            }
        }
        // Healed and bounded rows are counted so the caller still saves, and is still
        // told it repaired something, on a pass that only closed stranded records or
        // trimmed an overlap.
        return removed + healed + bounded
    }

    /// Local deduplication for the sorted repair window. A duplicate can only be
    /// within 60 seconds of the callback, so the preceding retained automatic visit
    /// is the only candidate that needs comparison; older rows are intentionally not
    /// fetched or reconsidered.
    @discardableResult
    static func deduplicateAutomaticLocations(in visits: [Visit], context: ModelContext) -> Int {
        let automatic = visits.filter {
            $0.source == "automatic" || $0.source == supersededLocationSource
        }.sorted { $0.arrival < $1.arrival }
        var retained: Visit?
        var repaired = 0
        for candidate in automatic {
            if isSupersededLocation(candidate) {
                if candidate.departure == nil {
                    candidate.departure = candidate.arrival
                    repaired += 1
                }
                continue
            }
            guard let previous = retained else {
                retained = candidate
                continue
            }
            if isDuplicateArrival(previous, candidate) {
                previous.arrival = min(previous.arrival, candidate.arrival)
                switch (previous.departure, candidate.departure) {
                case (nil, _), (_, nil): previous.departure = nil
                case let (left?, right?): previous.departure = max(left, right)
                }
                if locationQuality(candidate) > locationQuality(previous), previous.recognition != .confirmed {
                    previous.placeName = candidate.placeName
                    previous.inferredActivity = candidate.inferredActivity
                    previous.userActivity = candidate.userActivity
                    previous.recognitionConfidence = candidate.recognitionConfidence
                }
                candidate.departure = candidate.arrival
                candidate.source = supersededLocationSource
                candidate.locationResolutionExplanation = .duplicate
                candidate.setResolutionState(.superseded, actor: .automation)
                repaired += 1
            } else {
                if previous.departure == nil, candidate.arrival > previous.arrival {
                    previous.departure = candidate.arrival
                    previous.locationResolutionExplanation = .coordinateTime
                    repaired += 1
                } else if let departure = previous.departure, departure > candidate.arrival {
                    previous.departure = max(previous.arrival, candidate.arrival)
                    previous.locationResolutionExplanation = .coordinateTime
                    repaired += 1
                }
                retained = candidate
            }
        }
        return repaired
    }

    private static func isDuplicateArrival(_ previous: Visit, _ candidate: Visit) -> Bool {
        let sameIdentity: Bool
        if let left = previous.mapsIdentifier, let right = candidate.mapsIdentifier {
            sameIdentity = left == right
        } else if previous.hasPlaceholderName || candidate.hasPlaceholderName {
            sameIdentity = true
        } else {
            sameIdentity = NameKey.matching(previous.placeName) == NameKey.matching(candidate.placeName)
        }
        let distance = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
            .distance(from: CLLocation(latitude: candidate.latitude, longitude: candidate.longitude))
        let tolerance: CLLocationDistance = (previous.hasPlaceholderName || candidate.hasPlaceholderName) ? 60
            : (previous.mapsIdentifier != nil && previous.mapsIdentifier == candidate.mapsIdentifier ? 350 : 250)
        return abs(previous.arrival.timeIntervalSince(candidate.arrival)) <= 60 &&
            sameIdentity && distance <= tolerance
    }


    /// Higher-quality recognition wins when Core Location supplies two views of
    /// the same arrival. This prevents a placeholder from outliving a learned
    /// Saved Place while never letting an uncertain Maps result replace a user
    /// confirmation.
    private static func locationQuality(_ visit: Visit) -> Int {
        if visit.recognition == .confirmed { return 4 }
        if !visit.needsCategorisation && visit.recognition == .learned { return 3 }
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
            LocationDiagnostics.record(.closed, subject: "Stranded open stay",
                                       reason: "only the newest stay may be open",
                                       evidence: "\(visit.placeName) bounded by \(next.placeName)",
                                       context: context)
        }
        return repaired
    }

    @discardableResult
    static func closeSupersededOpenLocations(in visits: [Visit], context: ModelContext) -> Int {
        let locations = visits.filter { isLocationVisit($0) }.sorted { $0.arrival < $1.arrival }
        guard let latest = locations.last else { return 0 }
        var repaired = 0
        for visit in locations where visit.departure == nil && visit !== latest {
            guard let next = locations.first(where: { $0.arrival > visit.arrival }) else { continue }
            visit.departure = next.arrival
            repaired += 1
        }
        return repaired
    }

    private static func legacyCorrectionKey(_ arrival: Date, _ latitude: Double, _ longitude: Double) -> String {
        // Corrections historically record arrival/coordinates rather than a stable
        // visit ID. Quantising exactly to the old matching tolerances makes the index
        // equivalent to the former nested scan while keeping the audit linear.
        "\(Int(arrival.timeIntervalSince1970.rounded())):\(Int((latitude * 100_000).rounded())):\(Int((longitude * 100_000).rounded()))"
    }
}

/// Compact store health result for diagnostics and focused fixtures. It names the
/// invariant failures rather than trying to conceal them in a UI-only filter.
struct LocationResolutionValidation: Equatable {
    let currentResolvedVisits: Int
    let resolvedOverlaps: Int
    let negativeDurations: Int
    let visibleSupersededVisits: Int
    let automationReplacements: Int

    var isValid: Bool {
        currentResolvedVisits <= 1 && resolvedOverlaps == 0 && negativeDurations == 0 &&
            visibleSupersededVisits == 0 && automationReplacements == 0
    }

    @MainActor
    func record(context: ModelContext, reason: String, repairs: Int) {
        guard repairs > 0 || !isValid else { return }
        let message = "Resolution \(reason): \(repairs) repair(s); current \(currentResolvedVisits), overlaps \(resolvedOverlaps), negative durations \(negativeDurations), visible superseded \(visibleSupersededVisits), correction replacements \(automationReplacements)."
        Diagnostics.record(context, subsystem: "Location resolver", message: message,
                           severity: isValid ? "info" : "warning", category: LocationDiagnostics.category)
    }
}
