import Foundation
import Testing
@testable import LifeLog

/// The deterministic half of Apple Intelligence gap suggestions:
/// `GapSuggestionCandidateGenerator`, `GapSuggestionHistoricalMatcher`, and
/// `GapSuggestionContextBuilder`. Nothing here touches a model — every case is
/// exercised as a pure function over plain `Visit`/`SavedPlace` fixtures, the
/// same way `ArchiveRepairTests` covers the gap logic these build on.
struct GapSuggestionCandidateGeneratorTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func home(role: SavedPlaceRole? = .home) -> SavedPlace {
        let place = SavedPlace(name: "Home", latitude: -23.378, longitude: 150.511, defaultActivity: "At home")
        place.homeWorkRole = role
        return place
    }

    private func work(role: SavedPlaceRole? = .work) -> SavedPlace {
        let place = SavedPlace(name: "Regional Office", latitude: -23.40, longitude: 150.49, defaultActivity: "Work")
        place.homeWorkRole = role
        return place
    }

    private func visit(_ offsetHours: Double, _ durationHours: Double?, place: String, activity: String,
                       latitude: Double = 0, longitude: Double = 0, source: String = "automatic") -> Visit {
        let arrival = start.addingTimeInterval(offsetHours * 3600)
        let departure = durationHours.map { arrival.addingTimeInterval($0 * 3600) }
        return Visit(arrival: arrival, departure: departure, latitude: latitude, longitude: longitude,
                    placeName: place, inferredActivity: activity, userActivity: activity, source: source)
    }

    // MARK: - Candidate generation

    @Test("A gap after a Home stay offers continuation of that stay")
    func homeToDestinationOffersContinuation() {
        let homePlace = home()
        let before = visit(0, 2, place: "Home", activity: "At home", latitude: homePlace.latitude, longitude: homePlace.longitude)
        let after = visit(5, 1, place: "Coffee Society", activity: "Eating")

        let candidates = GapSuggestionCandidateGenerator.candidates(before: before, after: after, savedPlaces: [homePlace])

        #expect(candidates.map(\.kind) == [.continuationOfBeforeStay])
        #expect(candidates.first?.placeName == "Home")
        #expect(candidates.first?.homeWorkRole == .home)
    }

    @Test("A gap before a Home stay offers continuation of that stay")
    func destinationToHomeOffersContinuation() {
        let homePlace = home()
        let before = visit(0, 1, place: "Coffee Society", activity: "Eating")
        let after = visit(3, 2, place: "Home", activity: "At home", latitude: homePlace.latitude, longitude: homePlace.longitude)

        let candidates = GapSuggestionCandidateGenerator.candidates(before: before, after: after, savedPlaces: [homePlace])

        #expect(candidates.map(\.kind) == [.continuationOfAfterStay])
        #expect(candidates.first?.placeName == "Home")
    }

    @Test("A gap between Home and Work offers a commute candidate in both directions")
    func homeWorkCommuteBothDirections() {
        let homePlace = home()
        let workPlace = work()
        let toWork = visit(0, 1, place: "Home", activity: "At home", latitude: homePlace.latitude, longitude: homePlace.longitude)
        let atWork = visit(2, 1, place: "Regional Office", activity: "Work", latitude: workPlace.latitude, longitude: workPlace.longitude)

        let outbound = GapSuggestionCandidateGenerator.candidates(before: toWork, after: atWork, savedPlaces: [homePlace, workPlace])
        #expect(outbound.contains { $0.kind == .homeWorkTransition })
        #expect(outbound.first { $0.kind == .homeWorkTransition }?.activity == CommuteDetection.activityName)

        let inbound = GapSuggestionCandidateGenerator.candidates(before: atWork, after: toWork, savedPlaces: [homePlace, workPlace])
        #expect(inbound.contains { $0.kind == .homeWorkTransition })
    }

    @Test("A long commute still produces the same commute candidate — duration doesn't change the shape")
    func longCommuteStillOffersTransition() {
        let homePlace = home()
        let workPlace = work()
        let before = visit(0, 1, place: "Home", activity: "At home", latitude: homePlace.latitude, longitude: homePlace.longitude)
        // A 3-hour gap between Home and Work — well beyond a typical commute, but
        // the candidate generator's job is only to notice the role pattern; the
        // model (or a person) judges plausibility from the duration in context.
        let after = visit(4, 1, place: "Regional Office", activity: "Work", latitude: workPlace.latitude, longitude: workPlace.longitude)

        let candidates = GapSuggestionCandidateGenerator.candidates(before: before, after: after, savedPlaces: [homePlace, workPlace])
        #expect(candidates.contains { $0.kind == .homeWorkTransition })
    }

    @Test("Walking recorded within Home's own geofence reads as continuation, not travel")
    func walkingWithinHomeIsContinuation() {
        let homePlace = home()
        // A Health walking fragment whose coordinates still fall inside Home's own
        // geofence — movement within the stay, not evidence of leaving it. See
        // `ArchiveRepair.isWalkingFragment`'s own doc comment for the same rule
        // applied to routine gap fill.
        let before = visit(0, 1, place: "Home", activity: "At home", latitude: homePlace.latitude, longitude: homePlace.longitude)
        let after = visit(2, 1, place: "Walking", activity: "Walking",
                          latitude: homePlace.latitude, longitude: homePlace.longitude, source: "health-walking")

        let candidates = GapSuggestionCandidateGenerator.candidates(before: before, after: after, savedPlaces: [homePlace])

        #expect(candidates.map(\.kind) == [.continuationOfBeforeStay])
        #expect(candidates.first?.placeName == "Home")
    }

    @Test("Existing Archive Repair transitions become a direct editable Home, Work, or sleep draft")
    func archiveRepairRulesBecomeDirectDraftCandidates() {
        let homePlace = home()
        let workPlace = work()
        let gapStart = start.addingTimeInterval(2 * 3600)
        let gapEnd = start.addingTimeInterval(3 * 3600)

        let walking = Visit(arrival: start, departure: gapStart, latitude: 0, longitude: 0,
                            placeName: "Walking", inferredActivity: "Walking", source: "health-walking")
        let sleep = Visit(arrival: gapEnd, departure: gapEnd.addingTimeInterval(3600), latitude: 0, longitude: 0,
                          placeName: "Sleep", inferredActivity: "Sleeping", source: "health-sleep")
        let homeCandidate = GapSuggestionCandidateGenerator.candidates(
            before: walking, after: sleep, savedPlaces: [homePlace, workPlace],
            gapStart: gapStart, gapEnd: gapEnd)
        #expect(homeCandidate.map(\.kind) == [.resolverRuleStay])
        #expect(homeCandidate.first?.placeName == "Home")
        #expect(homeCandidate.first?.activity == "At home")

        let workVisit = Visit(arrival: start, departure: gapStart, latitude: workPlace.latitude, longitude: workPlace.longitude,
                              placeName: "Regional Office", inferredActivity: "Work", source: "automatic")
        let walkingAfter = Visit(arrival: gapEnd, departure: gapEnd.addingTimeInterval(3600), latitude: 0, longitude: 0,
                                 placeName: "Walking", inferredActivity: "Walking", source: "health-walking")
        let workCandidate = GapSuggestionCandidateGenerator.candidates(
            before: workVisit, after: walkingAfter, savedPlaces: [homePlace, workPlace],
            gapStart: gapStart, gapEnd: gapEnd)
        #expect(workCandidate.first?.placeName == "Regional Office")
        #expect(workCandidate.first?.activity == "Work")

        let travelling = Visit(arrival: start, departure: gapStart, latitude: 0, longitude: 0,
                               placeName: "Imported journal", inferredActivity: "Travelling", source: "imported-journal")
        let travelCandidate = GapSuggestionCandidateGenerator.candidates(
            before: travelling, after: sleep, savedPlaces: [homePlace, workPlace],
            gapStart: gapStart, gapEnd: gapEnd)
        #expect(travelCandidate.first?.placeName == "Home")
        #expect(travelCandidate.first?.activity == "At home")
    }

    @Test("Two unrelated neighbouring businesses with no Home/Work role offer nothing")
    func neighbouringBusinessesOfferNoCandidate() {
        let before = visit(0, 1, place: "Coffee Society", activity: "Eating")
        let after = visit(2, 1, place: "Woolworths Gracemere", activity: "Groceries")

        let candidates = GapSuggestionCandidateGenerator.candidates(before: before, after: after, savedPlaces: [])

        #expect(candidates.isEmpty, "Neither side is a known role and the places differ — nothing here is safe to assert")
    }

    @Test("The same resolved place on both sides offers a nearby-place-stay candidate")
    func sameNonRolePlaceOffersNearbyStay() {
        let before = visit(0, 1, place: "Coffee Society", activity: "Eating")
        let after = visit(3, 1, place: "Coffee Society", activity: "Eating")

        let candidates = GapSuggestionCandidateGenerator.candidates(before: before, after: after, savedPlaces: [])

        #expect(candidates.map(\.kind) == [.nearbyResolvedPlaceStay])
        #expect(candidates.first?.placeName == "Coffee Society")
    }

    @Test("A placeholder-named visit is never treated as a Home/Work endpoint even inside the geofence")
    func placeholderNameNeverBecomesAnEndpoint() {
        let homePlace = home()
        let before = visit(0, 1, place: "Home", activity: "At home", latitude: homePlace.latitude, longitude: homePlace.longitude)
        let after = visit(2, 1, place: Visit.identifyingPlaceName, activity: "Visiting",
                          latitude: homePlace.latitude, longitude: homePlace.longitude)

        let candidates = GapSuggestionCandidateGenerator.candidates(before: before, after: after, savedPlaces: [homePlace])

        // `before` still offers continuation; `after` never becomes its own
        // candidate because it has no real name to show.
        #expect(candidates.map(\.kind) == [.continuationOfBeforeStay])
    }

    @Test("Candidate IDs are stable literals, one per kind, never depending on array order")
    func candidateIDsAreStableAndUnique() {
        let homePlace = home()
        let workPlace = work()
        let before = visit(0, 1, place: "Home", activity: "At home", latitude: homePlace.latitude, longitude: homePlace.longitude)
        let after = visit(2, 1, place: "Regional Office", activity: "Work", latitude: workPlace.latitude, longitude: workPlace.longitude)

        let candidates = GapSuggestionCandidateGenerator.candidates(before: before, after: after, savedPlaces: [homePlace, workPlace])
        #expect(Set(candidates.map(\.id)).count == candidates.count, "no two candidates ever share an id")
        #expect(candidates.contains { $0.id == "continuation-before" })
        #expect(candidates.contains { $0.id == "home-work-transition" })
    }

    // MARK: - Context builder: timing classification

    @Test("A gap bordering a still-open (live) record is marked isLive")
    func gapBorderingLiveHistoryIsMarkedLive() {
        let homePlace = home()
        let before = visit(0, 1, place: "Home", activity: "At home", latitude: homePlace.latitude, longitude: homePlace.longitude)
        let after = Visit(arrival: start.addingTimeInterval(3 * 3600), departure: nil, latitude: 0, longitude: 0,
                         placeName: "Regional Office", inferredActivity: "Work", userActivity: "Work", source: "automatic")

        let context = GapSuggestionContextBuilder.build(
            gapStart: before.departure!, gapEnd: after.arrival, before: before, after: after,
            savedPlaces: [homePlace], allVisits: [before, after], now: after.arrival.addingTimeInterval(3600))

        #expect(context.after?.isLive == true)
        #expect(context.before?.isLive == false)
    }

    @Test("An overnight gap is classified as overnight, not merely long")
    func overnightGapClassifiedCorrectly() {
        let homePlace = home()
        let before = visit(20, 1, place: "Home", activity: "At home", latitude: homePlace.latitude, longitude: homePlace.longitude)
        // 9pm to 7am the next day: crosses a day boundary and spans the night.
        let after = visit(35, 1, place: "Home", activity: "At home", latitude: homePlace.latitude, longitude: homePlace.longitude)

        let context = GapSuggestionContextBuilder.build(
            gapStart: before.departure!, gapEnd: after.arrival, before: before, after: after,
            savedPlaces: [homePlace], allVisits: [before, after], now: after.arrival)

        #expect(context.timing.lengthClass == .overnight)
        #expect(context.timing.crossesDayBoundary == true)
    }

    @Test("A gap longer than the routine-gap-fill cap is offered no candidates at all")
    func excessivelyLongGapSuppressesCandidates() {
        let homePlace = home()
        let workPlace = work()
        let before = visit(0, 1, place: "Home", activity: "At home", latitude: homePlace.latitude, longitude: homePlace.longitude)
        // 48 hours later — well past `ArchiveRepair.gapFillCap` (24h). Even a
        // clean Home→Work role pattern must not be offered as a candidate: a
        // gap this long is far more likely a genuine, unrecorded absence.
        let after = visit(49, 1, place: "Regional Office", activity: "Work", latitude: workPlace.latitude, longitude: workPlace.longitude)

        let context = GapSuggestionContextBuilder.build(
            gapStart: before.departure!, gapEnd: after.arrival, before: before, after: after,
            savedPlaces: [homePlace, workPlace], allVisits: [before, after], now: after.arrival)

        #expect(context.candidates.isEmpty)
    }

    @Test("Already-resolved travel overlapping the gap is surfaced as existing travel")
    func alreadyResolvedTravelIsSurfaced() {
        let homePlace = home()
        let workPlace = work()
        let before = visit(0, 1, place: "Home", activity: "At home", latitude: homePlace.latitude, longitude: homePlace.longitude)
        let after = visit(1.5, 1, place: "Regional Office", activity: "Work", latitude: workPlace.latitude, longitude: workPlace.longitude)

        let context = GapSuggestionContextBuilder.build(
            gapStart: before.departure!, gapEnd: after.arrival, before: before, after: after,
            savedPlaces: [homePlace, workPlace], allVisits: [before, after], now: after.arrival)

        // `CommuteDetection` already computes this exact stretch as a Home→Work
        // commute even though no Visit row covers it — the deterministic
        // homeWorkTransition candidate and the existing-travel context should
        // agree, not contradict each other.
        #expect(context.existingTravel != nil)
        #expect(context.existingTravel?.direction == "toWork")
        #expect(context.candidates.contains { $0.kind == .homeWorkTransition })
    }

    // MARK: - Historical matcher

    @Test("A comparable historical Home→Work transition is counted and summarised")
    func historicalCommutePatternIsSummarized() {
        let homePlace = home()
        let workPlace = work()
        func commuteLeg(dayOffset: Double) -> (Visit, Visit) {
            let before = visit(dayOffset * 24, 1, place: "Home", activity: "At home",
                              latitude: homePlace.latitude, longitude: homePlace.longitude)
            let after = visit(dayOffset * 24 + 2, 1, place: "Regional Office", activity: "Work",
                             latitude: workPlace.latitude, longitude: workPlace.longitude)
            return (before, after)
        }
        let day0 = commuteLeg(dayOffset: 0)
        let day1 = commuteLeg(dayOffset: 1)
        let day2 = commuteLeg(dayOffset: 2)
        let allVisits = [day0.0, day0.1, day1.0, day1.1, day2.0, day2.1]

        let summary = GapSuggestionHistoricalMatcher.summarize(
            before: day2.0, after: day2.1, allVisits: allVisits, savedPlaces: [homePlace, workPlace], now: day2.1.arrival)

        // day0 and day1 are comparable historical matches; day2 is the current
        // gap itself and must be excluded from its own history.
        #expect(summary.matchingTransitionCount == 2)
        #expect(summary.medianDurationMinutes != nil)
        #expect(summary.samples.count <= GapSuggestionHistoricalMatcher.sampleCap)
    }

    @Test("No comparable historical pattern reports zero, not a guess")
    func noHistoricalPatternReportsZero() {
        let before = visit(0, 1, place: "Coffee Society", activity: "Eating")
        let after = visit(2, 1, place: "Woolworths Gracemere", activity: "Groceries")

        let summary = GapSuggestionHistoricalMatcher.summarize(
            before: before, after: after, allVisits: [before, after], savedPlaces: [], now: after.arrival)

        #expect(summary.matchingTransitionCount == 0)
        #expect(summary.medianDurationMinutes == nil)
        #expect(summary.samples.isEmpty)
    }

    // MARK: - Validator: never invents an ID

    @Test("The validator rejects a candidate kind the current gap's context never supplied")
    func validatorRejectsInventedCandidateKind() {
        let homePlace = home()
        let before = visit(0, 1, place: "Home", activity: "At home", latitude: homePlace.latitude, longitude: homePlace.longitude)
        let after = visit(2, 1, place: "Coffee Society", activity: "Eating")
        // Only a continuation-of-before candidate exists for this gap — no
        // homeWorkTransition or nearby-place candidate was ever offered.
        let candidates = GapSuggestionCandidateGenerator.candidates(before: before, after: after, savedPlaces: [homePlace])

        let raw = GapSuggestionRawOutcome(kind: "possibleTravel", candidateKind: "homeWorkTransition",
                                          confidence: "high", explanation: "Looks like a commute.")
        #expect(GapSuggestionValidator.validate(raw, candidates: candidates) == nil)
    }

    @Test("The validator rejects an outcome kind that doesn't match the chosen candidate's own kind")
    func validatorRejectsMismatchedOutcomeAndCandidateKind() {
        let homePlace = home()
        let before = visit(0, 1, place: "Home", activity: "At home", latitude: homePlace.latitude, longitude: homePlace.longitude)
        let after = visit(2, 1, place: "Coffee Society", activity: "Eating")
        let candidates = GapSuggestionCandidateGenerator.candidates(before: before, after: after, savedPlaces: [homePlace])

        // possibleTravel can never point at a continuation-of-stay candidate.
        let raw = GapSuggestionRawOutcome(kind: "possibleTravel", candidateKind: "continuationOfBeforeStay",
                                          confidence: "medium", explanation: "Still travelling maybe.")
        #expect(GapSuggestionValidator.validate(raw, candidates: candidates) == nil)
    }

    @Test("The validator accepts a well-formed outcome and copies the real candidate ID, never model text")
    func validatorAcceptsWellFormedOutcome() throws {
        let homePlace = home()
        let before = visit(0, 1, place: "Home", activity: "At home", latitude: homePlace.latitude, longitude: homePlace.longitude)
        let after = visit(2, 1, place: "Coffee Society", activity: "Eating")
        let candidates = GapSuggestionCandidateGenerator.candidates(before: before, after: after, savedPlaces: [homePlace])

        let raw = GapSuggestionRawOutcome(kind: "possibleStay", candidateKind: "continuationOfBeforeStay",
                                          confidence: "medium", explanation: "Bordering stay before was Home.")
        let outcome = try #require(GapSuggestionValidator.validate(raw, candidates: candidates))
        #expect(outcome.candidateID == candidates.first?.id)
        #expect(outcome.confidence == .medium)
    }

    @Test("The validator rejects an empty explanation")
    func validatorRejectsEmptyExplanation() {
        let raw = GapSuggestionRawOutcome(kind: "noSuggestion", candidateKind: "none", confidence: "low", explanation: "  ")
        #expect(GapSuggestionValidator.validate(raw, candidates: []) == nil)
    }

    @Test("The validator rejects an unrecognised outcome or confidence value")
    func validatorRejectsMalformedVocabulary() {
        let badKind = GapSuggestionRawOutcome(kind: "definitelyHome", candidateKind: "none", confidence: "low", explanation: "x")
        #expect(GapSuggestionValidator.validate(badKind, candidates: []) == nil)

        let badConfidence = GapSuggestionRawOutcome(kind: "noSuggestion", candidateKind: "none", confidence: "certain", explanation: "x")
        #expect(GapSuggestionValidator.validate(badConfidence, candidates: []) == nil)
    }
}
