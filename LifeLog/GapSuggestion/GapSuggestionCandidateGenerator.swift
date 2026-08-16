import Foundation
import SwiftData

/// Builds the small set of valid, deterministic candidate explanations for one
/// gap, from existing resolver rules, Saved Place roles, and travel logic —
/// never from a model. A model may only rank or decline what this produces (see
/// `GapSuggestionValidator`); it never gets to invent a fifth option.
///
/// Exactly one candidate of each `GapSuggestionCandidateKind` can ever exist for
/// a given `before`/`after` pair, which is what lets a model response name a
/// *kind* rather than an ID and still be unambiguous.
enum GapSuggestionCandidateGenerator {
    static let maximumCandidates = 4

    /// The Home/Work role a bordering visit contributes, or `nil`. A
    /// placeholder-named visit is never treated as a Home/Work endpoint even if
    /// its coordinates happen to fall inside a geofence — the same guard
    /// `CommuteDetection`'s own (private) `endpoint(_:savedPlaces:)` applies, so
    /// an "Identifying…" row can never read as a confirmed commute leg here
    /// either.
    static func role(of visit: Visit, savedPlaces: [SavedPlace]) -> SavedPlaceRole? {
        guard !visit.hasPlaceholderName else { return nil }
        return SavedPlaceRole.of(visit, in: savedPlaces)
    }

    static func candidates(before: Visit, after: Visit, savedPlaces: [SavedPlace],
                           gapStart: Date? = nil, gapEnd: Date? = nil,
                           calendar: Calendar = .current) -> [GapSuggestionCandidate] {
        if let gapStart, let gapEnd,
           let ruleCandidate = resolverRuleCandidate(before: before, after: after, savedPlaces: savedPlaces,
                                                     gapStart: gapStart, gapEnd: gapEnd, calendar: calendar) {
            // This is an existing, deterministic resolver conclusion, rather
            // than competing evidence for a model to weigh. Presenting only it
            // keeps a direct Home/Work/sleep/travel/walking repair actionable.
            return [ruleCandidate]
        }
        let beforeRole = role(of: before, savedPlaces: savedPlaces)
        let afterRole = role(of: after, savedPlaces: savedPlaces)
        let beforeNamed = !before.hasPlaceholderName
        let afterNamed = !after.hasPlaceholderName
        let sameName = beforeNamed && afterNamed
            && before.displayPlaceName.caseInsensitiveCompare(after.displayPlaceName) == .orderedSame

        var results: [GapSuggestionCandidate] = []

        if let beforeRole, beforeRole == .home || beforeRole == .work {
            let roleLabel = beforeRole == .home ? "Home" : "Work"
            results.append(GapSuggestionCandidate(
                id: "continuation-before", kind: .continuationOfBeforeStay,
                placeName: before.displayPlaceName, activity: before.activity, homeWorkRole: beforeRole,
                rationale: "The stay immediately before the gap was at \(before.displayPlaceName), a \(roleLabel) saved place."
            ))
        }
        // Skipped when `sameName`, or when both sides resolve to the *same*
        // Home/Work role even under different labels — a Health walking
        // fragment recorded inside Home's own geofence is still Home, just
        // under a different name, and offering "after" too would only repeat
        // `continuation-before`'s evidence as a second, redundant candidate.
        let sameRole = beforeRole != nil && beforeRole == afterRole
        if !sameName, !sameRole, let afterRole, afterRole == .home || afterRole == .work {
            let roleLabel = afterRole == .home ? "Home" : "Work"
            results.append(GapSuggestionCandidate(
                id: "continuation-after", kind: .continuationOfAfterStay,
                placeName: after.displayPlaceName, activity: after.activity, homeWorkRole: afterRole,
                rationale: "The stay immediately after the gap was at \(after.displayPlaceName), a \(roleLabel) saved place."
            ))
        }
        if let beforeRole, let afterRole, Set([beforeRole, afterRole]) == [.home, .work] {
            let fromLabel = beforeRole == .home ? "Home" : "Work"
            let toLabel = afterRole == .home ? "Home" : "Work"
            results.append(GapSuggestionCandidate(
                id: "home-work-transition", kind: .homeWorkTransition,
                placeName: nil, activity: CommuteDetection.activityName, homeWorkRole: nil,
                rationale: "The gap sits between a \(fromLabel) stay and a \(toLabel) stay — LifeLog's own travel logic already recognises this pattern as a commute."
            ))
        }
        // Home/Work pairs are excluded — that evidence already produced
        // `continuation-before` above, and offering the same place again as a
        // "nearby place" would be a duplicate, not a second option.
        if sameName, beforeRole != .home, beforeRole != .work {
            results.append(GapSuggestionCandidate(
                id: "nearby-place-stay", kind: .nearbyResolvedPlaceStay,
                placeName: before.displayPlaceName, activity: before.activity, homeWorkRole: nil,
                rationale: "The same resolved place, \(before.displayPlaceName), is recorded on both sides of the gap."
            ))
        }
        return Array(results.prefix(maximumCandidates))
    }

    private static func resolverRuleCandidate(before: Visit, after: Visit, savedPlaces: [SavedPlace],
                                              gapStart: Date, gapEnd: Date, calendar: Calendar) -> GapSuggestionCandidate? {
        let gap = ArchiveRepair.UnloggedGap(start: gapStart, end: gapEnd, before: before, after: after)
        guard let segment = ArchiveRepair.singleSegmentSuggestion(for: gap, calendar: calendar) else { return nil }

        let role: SavedPlaceRole?
        let placeName: String
        switch segment.activity {
        case "At home":
            role = .home
            placeName = savedPlaces.first(where: { $0.homeWorkRole == .home })?.name ?? "At home"
        case "Work":
            role = .work
            placeName = savedPlaces.first(where: { $0.homeWorkRole == .work })?.name ?? "Work"
        case "Sleeping":
            role = nil
            placeName = ArchiveRepair.sleepPlaceName
        default:
            return nil
        }

        return GapSuggestionCandidate(
            id: "resolver-rule-stay", kind: .resolverRuleStay,
            placeName: placeName, activity: segment.activity, homeWorkRole: role,
            rationale: "LifeLog's existing Home, Work, sleep, travel, and walking repair rules resolve this whole gap as \(segment.activity)."
        )
    }
}

/// Summarises comparable historical gaps for the current one — bounded,
/// aggregate-only evidence, never a list of raw visits. Reuses
/// `ArchiveRepair.unloggedGaps` as the historical pool: the same rule that finds
/// *this* gap is what finds every comparable one, so the two can never disagree
/// about what counts as a gap.
enum GapSuggestionHistoricalMatcher {
    /// How many individual matches are described in `HistoricalSummary.samples`
    /// — everything beyond this is still counted in `matchingTransitionCount`,
    /// just not named one by one.
    static let sampleCap = 3

    private enum Signature: Equatable {
        case roles(SavedPlaceRole, SavedPlaceRole)
        case samePlace(String)
    }

    private static func signature(before: Visit, after: Visit, savedPlaces: [SavedPlace]) -> Signature? {
        let beforeRole = GapSuggestionCandidateGenerator.role(of: before, savedPlaces: savedPlaces)
        let afterRole = GapSuggestionCandidateGenerator.role(of: after, savedPlaces: savedPlaces)
        if let beforeRole, let afterRole, beforeRole != afterRole {
            return .roles(beforeRole, afterRole)
        }
        let beforeNamed = !before.hasPlaceholderName
        let afterNamed = !after.hasPlaceholderName
        if beforeNamed, afterNamed,
           before.displayPlaceName.caseInsensitiveCompare(after.displayPlaceName) == .orderedSame {
            return .samePlace(before.displayPlaceName.lowercased())
        }
        return nil
    }

    private static func dayLabel(_ date: Date, calendar: Calendar) -> String {
        calendar.weekdaySymbols[calendar.component(.weekday, from: date) - 1]
    }

    /// `allVisits` is the whole archive, already fetched by the caller — bounded
    /// evidence only leaves this function in the returned `HistoricalSummary`;
    /// scanning broadly to compute it is no different from what
    /// `ArchiveRepairActor.scan()` already does for the same archive.
    static func summarize(before: Visit, after: Visit, allVisits: [Visit], savedPlaces: [SavedPlace],
                          now: Date, calendar: Calendar = .current) -> GapSuggestionContext.HistoricalSummary {
        guard let target = signature(before: before, after: after, savedPlaces: savedPlaces) else {
            return GapSuggestionContext.HistoricalSummary(
                matchingTransitionCount: 0, medianDurationMinutes: nil,
                occurrenceDescription: "No comparable historical pattern found.", samples: [])
        }
        let matches = ArchiveRepair.unloggedGaps(in: allVisits, now: now)
            .filter { !($0.before === before && $0.after === after) }
            .filter { signature(before: $0.before, after: $0.after, savedPlaces: savedPlaces) == target }
        guard !matches.isEmpty else {
            return GapSuggestionContext.HistoricalSummary(
                matchingTransitionCount: 0, medianDurationMinutes: nil,
                occurrenceDescription: "No comparable historical pattern found.", samples: [])
        }
        let durationsMinutes = matches.map { Int($0.hours * 60) }.sorted()
        let median = durationsMinutes[durationsMinutes.count / 2]
        let samples = matches.prefix(sampleCap).map { gap in
            GapSuggestionContext.HistoricalSample(description: "~\(Int(gap.hours * 60)) min, a \(dayLabel(gap.start, calendar: calendar))")
        }
        let plural = matches.count == 1 ? "" : "s"
        return GapSuggestionContext.HistoricalSummary(
            matchingTransitionCount: matches.count, medianDurationMinutes: median,
            occurrenceDescription: "\(matches.count) similar transition\(plural) found in your history, typically ~\(median) min.",
            samples: Array(samples))
    }
}

/// Assembles the complete `GapSuggestionContext` for one gap from already-fetched
/// archive data — the pure, testable half of context building. The actor
/// extension below owns the fetch; this owns the reasoning.
enum GapSuggestionContextBuilder {
    static func build(gapStart: Date, gapEnd: Date, before: Visit, after: Visit, savedPlaces: [SavedPlace],
                      allVisits: [Visit], now: Date, calendar: Calendar = .current,
                      timeZone: TimeZone = .current) -> GapSuggestionContext {
        let durationSeconds = gapEnd.timeIntervalSince(gapStart)
        let durationMinutes = Int(durationSeconds / 60)
        let crossesDayBoundary = !calendar.isDate(gapStart, inSameDayAs: gapEnd)
        let hours = durationSeconds / 3600
        let lengthClass: GapSuggestionContext.LengthClass
        if crossesDayBoundary && hours >= 3 {
            lengthClass = .overnight
        } else if hours > 4 {
            lengthClass = .long
        } else {
            lengthClass = .short
        }
        let hour = calendar.component(.hour, from: gapStart)
        let timeBand = AskLifeLogTimeBand.allCases.first { $0.contains(hour: hour) }?.rawValue ?? AskLifeLogTimeBand.night.rawValue
        let weekday = calendar.weekdaySymbols[calendar.component(.weekday, from: gapStart) - 1]

        let timing = GapSuggestionContext.Timing(
            start: gapStart, end: gapEnd, durationMinutes: durationMinutes,
            timeZoneIdentifier: timeZone.identifier, weekday: weekday, timeBand: timeBand,
            lengthClass: lengthClass, crossesDayBoundary: crossesDayBoundary
        )

        let commutes = CommuteDetection.commutes(in: allVisits, savedPlaces: savedPlaces, now: now)
        let existingTravel = commutes
            .first { $0.start < gapEnd && $0.end > gapStart }
            .map { commute in
                GapSuggestionContext.ExistingTravel(
                    direction: commute.direction.rawValue, durationMinutes: Int(commute.duration / 60),
                    overlapsGapStart: commute.start <= gapStart, overlapsGapEnd: commute.end >= gapEnd)
            }

        // A gap this long is far more likely a genuine, unrecorded absence than
        // any single continuation or commute — the same reasoning
        // `ArchiveRepair.gapFillCap` already applies to the routine template
        // fill, reused here rather than a second, possibly-diverging threshold.
        let candidates = durationSeconds > ArchiveRepair.gapFillCap
            ? []
            : GapSuggestionCandidateGenerator.candidates(
                before: before, after: after, savedPlaces: savedPlaces,
                gapStart: gapStart, gapEnd: gapEnd, calendar: calendar)

        let historicalSummary = GapSuggestionHistoricalMatcher.summarize(
            before: before, after: after, allVisits: allVisits, savedPlaces: savedPlaces, now: now, calendar: calendar)

        return GapSuggestionContext(
            timing: timing,
            before: borderingRecord(before, relationship: .immediatelyBefore, savedPlaces: savedPlaces),
            after: borderingRecord(after, relationship: .immediatelyAfter, savedPlaces: savedPlaces),
            existingTravel: existingTravel,
            historicalSummary: historicalSummary,
            candidates: candidates
        )
    }

    private static func borderingRecord(_ visit: Visit, relationship: GapSuggestionContext.BorderingRecord.Relationship,
                                        savedPlaces: [SavedPlace]) -> GapSuggestionContext.BorderingRecord {
        GapSuggestionContext.BorderingRecord(
            relationship: relationship, displayLabel: visit.displayPlaceName,
            homeWorkRole: GapSuggestionCandidateGenerator.role(of: visit, savedPlaces: savedPlaces),
            activity: visit.activity, resolutionStatus: visit.resolutionState, isLive: visit.departure == nil
        )
    }
}

extension ArchiveRepairActor {
    /// Builds the complete `GapSuggestionContext` for one gap, identified by its
    /// own start and end — re-found here the same way `fillSingleGap` re-finds
    /// its gap, rather than trusting a listing built in a different actor's
    /// context. Returns `nil` when the gap no longer exists — something else
    /// already filled, merged, or otherwise resolved it since it was last shown
    /// — so a caller can treat "gap disappeared" and "stale request" the same way.
    func gapSuggestionContext(gapStart: Date, gapEnd: Date, now: Date = .now) throws -> GapSuggestionContext? {
        let visits = try modelContext.fetch(FetchDescriptor<Visit>())
        guard let gap = ArchiveRepair.unloggedGaps(in: visits, now: now)
            .first(where: { $0.start == gapStart && $0.end == gapEnd }) else { return nil }
        let savedPlaces = try modelContext.fetch(FetchDescriptor<SavedPlace>())
        return GapSuggestionContextBuilder.build(gapStart: gap.start, gapEnd: gap.end, before: gap.before,
                                                 after: gap.after, savedPlaces: savedPlaces, allVisits: visits, now: now)
    }
}
