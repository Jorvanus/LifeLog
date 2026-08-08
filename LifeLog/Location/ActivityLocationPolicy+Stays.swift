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
        var retained: [Visit] = []
        var merged = 0
        for stay in stays {
            guard let host = retained.last(where: { describesSameStay($0, stay, now: now) }) else {
                retained.append(stay)
                continue
            }
            host.arrival = min(host.arrival, stay.arrival)
            switch (host.departure, stay.departure) {
            case (nil, _), (_, nil): host.departure = nil
            case let (left?, right?): host.departure = max(left, right)
            }
            if locationQuality(stay) > locationQuality(host) {
                host.placeName = stay.placeName
                host.inferredActivity = stay.inferredActivity
                host.userActivity = stay.userActivity
                host.recognitionConfidence = stay.recognitionConfidence
            }
            // Kept for inspection, the way a merged duplicate callback is, but closed
            // so its duration cannot grow and excluded from every screen.
            stay.departure = stay.arrival
            stay.source = supersededLocationSource
            merged += 1
            LocationDiagnostics.record(.merged, subject: "Overlapping stay",
                                       reason: "two records claim the same minutes at one place",
                                       evidence: "\(stay.placeName) folded into \(host.placeName)",
                                       context: context)
        }
        return merged
    }


    /// Two records of one stay: overlapping in time, agreeing on the place, and close
    /// enough together that GPS drift explains the difference. A placeholder name is
    /// never matched — "Identifying…" says nothing about which place this is.
    private static func describesSameStay(_ host: Visit, _ candidate: Visit, now: Date) -> Bool {
        let hostEnd = host.departure ?? now
        let candidateEnd = candidate.departure ?? now
        guard host.arrival < candidateEnd, hostEnd > candidate.arrival else { return false }
        guard !Visit.isPlaceholderName(host.placeName), !Visit.isPlaceholderName(candidate.placeName),
              NameKey.matching(host.placeName) == NameKey.matching(candidate.placeName) else { return false }
        return CLLocation(latitude: host.latitude, longitude: host.longitude)
            .distance(from: CLLocation(latitude: candidate.latitude, longitude: candidate.longitude)) <= 250
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
                    LocationDiagnostics.record(.closed, subject: "Overlapping stay",
                                               reason: "a later arrival precedes this stay's recorded departure",
                                               evidence: "\(previous.placeName) trimmed to \(candidate.placeName)'s arrival",
                                               context: context)
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
            LocationDiagnostics.record(.closed, subject: "Stranded open stay",
                                       reason: "only the newest stay may be open",
                                       evidence: "\(visit.placeName) bounded by \(next.placeName)",
                                       context: context)
        }
        return repaired
    }
}
