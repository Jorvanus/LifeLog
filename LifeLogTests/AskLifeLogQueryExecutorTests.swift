import Foundation
import SwiftData
import Testing
@testable import LifeLog

/// `AskLifeLogQueryExecutor`: every supported query type answered deterministically
/// from LifeLog's own aggregation/comparison/place-history/gap logic, with the
/// same source-scope enforcement, bounded reads, and archive-scale budget every
/// other bounded reader in this file already guarantees.
@MainActor
struct AskLifeLogQueryExecutorTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000) // a Monday

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func askContext(now: Date, window: InsightWindow = .week, scope: InsightsScope = .allHistory) -> AskLifeLogQuestionContext {
        .current(window: window, interval: window.interval(containing: now), now: now, scope: scope)
    }

    // MARK: - Place / activity totals

    @Test("placeTotal sums only the resolved place's hours in the selected window")
    func placeTotalSumsResolvedPlace() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Visit(arrival: base, departure: base.addingTimeInterval(3_600), latitude: 0, longitude: 0,
                             placeName: "Work", inferredActivity: "Working", userActivity: "Working"))
        context.insert(Visit(arrival: base.addingTimeInterval(7_200), departure: base.addingTimeInterval(9_000),
                             latitude: 0, longitude: 0, placeName: "Gym", inferredActivity: "Exercising", userActivity: "Exercising"))
        try context.save()

        let now = base.addingTimeInterval(10_000)
        let result = try await AskLifeLogQueryExecutor.execute(
            .placeTotal(place: .init("Work"), window: .thisWeek), context: askContext(now: now),
            reader: VisitArchiveReader(modelContainer: container), repairActor: ArchiveRepairActor(modelContainer: container),
            catalogue: [])
        guard case .answer(let answer) = result else { Issue.record("Expected an answer, got \(result)"); return }
        #expect(answer.headline == "1h")
        #expect(answer.drillDown == .place(name: "Work"))
    }

    @Test("activityTotal resolves a renamed activity's legacy label and sums under its current name")
    func activityTotalResolvesRenamedLabel() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Visit(arrival: base, departure: base.addingTimeInterval(1_800), latitude: 0, longitude: 0,
                             placeName: "Home", inferredActivity: "Working", userActivity: "Working"))
        try context.save()

        var definition = ActivityDefinition(name: "Deep Work", category: "Work")
        definition.legacyNames = ["Working"]

        let now = base.addingTimeInterval(3_600)
        let result = try await AskLifeLogQueryExecutor.execute(
            .activityTotal(activity: .init("Working"), window: .thisWeek), context: askContext(now: now),
            reader: VisitArchiveReader(modelContainer: container), repairActor: ArchiveRepairActor(modelContainer: container),
            catalogue: [definition])
        guard case .answer(let answer) = result else { Issue.record("Expected an answer, got \(result)"); return }
        #expect(answer.headline == "30m")
        #expect(answer.interpretedQuestion.contains("Deep Work"))
    }

    // MARK: - Ranking

    @Test("placeRanking by hours and by visit count can disagree, and each honours order")
    func placeRankingHonoursMetricAndOrder() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        // Cafe: one long visit. Gym: three short visits -- more visits, fewer hours.
        context.insert(Visit(arrival: base, departure: base.addingTimeInterval(7_200), latitude: 0, longitude: 0,
                             placeName: "Cafe", inferredActivity: "Coffee", userActivity: "Coffee"))
        for index in 0..<3 {
            let start = base.addingTimeInterval(Double(index) * 3_600 + 10_000)
            context.insert(Visit(arrival: start, departure: start.addingTimeInterval(600), latitude: 0, longitude: 0,
                                 placeName: "Gym", inferredActivity: "Exercising", userActivity: "Exercising"))
        }
        try context.save()

        let now = base.addingTimeInterval(20_000)
        let reader = VisitArchiveReader(modelContainer: container)
        let repairActor = ArchiveRepairActor(modelContainer: container)

        let byHours = try await AskLifeLogQueryExecutor.execute(
            .placeRanking(metric: .totalHours, order: .most, window: .thisWeek), context: askContext(now: now),
            reader: reader, repairActor: repairActor, catalogue: [])
        guard case .answer(let hoursAnswer) = byHours else { Issue.record("Expected an answer"); return }
        #expect(hoursAnswer.headline.hasPrefix("Cafe"))

        let byVisits = try await AskLifeLogQueryExecutor.execute(
            .placeRanking(metric: .visitCount, order: .most, window: .thisWeek), context: askContext(now: now),
            reader: reader, repairActor: repairActor, catalogue: [])
        guard case .answer(let visitsAnswer) = byVisits else { Issue.record("Expected an answer"); return }
        #expect(visitsAnswer.headline.hasPrefix("Gym"))
    }

    // MARK: - Last visit

    @Test("lastVisitToPlace returns the most recent of several occurrences")
    func lastVisitReturnsMostRecent() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Visit(arrival: base, departure: base.addingTimeInterval(1_800), latitude: 0, longitude: 0,
                             placeName: "Riverside Cafe", inferredActivity: "Coffee"))
        let recent = base.addingTimeInterval(86_400 * 5)
        context.insert(Visit(arrival: recent, departure: recent.addingTimeInterval(1_800), latitude: 0, longitude: 0,
                             placeName: "Riverside Cafe", inferredActivity: "Coffee"))
        try context.save()

        let now = recent.addingTimeInterval(86_400)
        let result = try await AskLifeLogQueryExecutor.execute(
            .lastVisitToPlace(place: .init("Riverside Cafe")), context: askContext(now: now),
            reader: VisitArchiveReader(modelContainer: container), repairActor: ArchiveRepairActor(modelContainer: container),
            catalogue: [])
        guard case .answer(let answer) = result else { Issue.record("Expected an answer"); return }
        #expect(Calendar.current.isDate(recent, inSameDayAs: try #require(dateOnly(answer.headline))))
    }

    private func dateOnly(_ formatted: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: formatted)
    }

    // MARK: - Weekday/time pattern

    @Test("weekdayTimePattern finds where time was spent on a specific weekday and time band")
    func weekdayTimePatternFindsMatchingPlace() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        // 2 Jan 2026 is a Friday.
        var fridayComponents = DateComponents(year: 2026, month: 1, day: 2, hour: 18, minute: 30)
        fridayComponents.calendar = .current
        let fridayEvening = Calendar.current.date(from: fridayComponents)!
        context.insert(Visit(arrival: fridayEvening, departure: fridayEvening.addingTimeInterval(3_600),
                             latitude: 0, longitude: 0, placeName: "The Tavern", inferredActivity: "Socialising"))
        // A decoy on the same day but a different time band.
        let fridayMorning = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: fridayEvening)!
        context.insert(Visit(arrival: fridayMorning, departure: fridayMorning.addingTimeInterval(1_800),
                             latitude: 0, longitude: 0, placeName: "Home", inferredActivity: "At home"))
        try context.save()

        let now = Calendar.current.date(byAdding: .day, value: 10, to: fridayEvening)!
        let result = try await AskLifeLogQueryExecutor.execute(
            .weekdayTimePattern(weekday: .friday, timeBand: .evening, window: .thisMonth), context: askContext(now: now, window: .month),
            reader: VisitArchiveReader(modelContainer: container), repairActor: ArchiveRepairActor(modelContainer: container),
            catalogue: [])
        guard case .answer(let answer) = result else { Issue.record("Expected an answer, got \(result)"); return }
        #expect(answer.headline.hasPrefix("The Tavern"))
    }

    // MARK: - Comparison

    @Test("strongestComparison finds the category with the largest change, with a baseline explanation")
    func strongestComparisonFindsLargestChange() async throws {
        ActivityCatalog.resetForTesting()
        let container = try makeContainer()
        let context = ModelContext(container)
        // This week: 3 hours of Exercising. Last week: none. A clear, large delta.
        context.insert(Visit(arrival: base, departure: base.addingTimeInterval(3 * 3_600), latitude: 0, longitude: 0,
                             placeName: "Gym", inferredActivity: "Exercising", userActivity: "Exercising"))
        try context.save()

        let now = base.addingTimeInterval(4 * 3_600)
        let result = try await AskLifeLogQueryExecutor.execute(
            .strongestComparison(window: .thisWeek), context: askContext(now: now),
            reader: VisitArchiveReader(modelContainer: container), repairActor: ArchiveRepairActor(modelContainer: container),
            catalogue: [])
        guard case .answer(let answer) = result else { Issue.record("Expected an answer, got \(result)"); return }
        #expect(answer.headline.lowercased().contains("more"))
        #expect(answer.detail != nil)
    }

    @Test("An ongoing period's comparison note names the matching elapsed span, not the whole previous period")
    func ongoingComparisonNotesElapsedSpan() async throws {
        ActivityCatalog.resetForTesting()
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Visit(arrival: base, departure: base.addingTimeInterval(3_600), latitude: 0, longitude: 0,
                             placeName: "Gym", inferredActivity: "Exercising", userActivity: "Exercising"))
        try context.save()

        // "now" sits inside the current month, so the month window is ongoing.
        let now = base.addingTimeInterval(2 * 3_600)
        let result = try await AskLifeLogQueryExecutor.execute(
            .strongestComparison(window: .thisMonth), context: askContext(now: now, window: .month),
            reader: VisitArchiveReader(modelContainer: container), repairActor: ArchiveRepairActor(modelContainer: container),
            catalogue: [])
        guard case .answer(let answer) = result else { Issue.record("Expected an answer, got \(result)"); return }
        #expect(answer.detail?.contains("first") == true)
    }

    @Test("No qualifying change over the noise floor reports no baseline, not a false comparison")
    func noQualifyingChangeReportsNoBaseline() async throws {
        ActivityCatalog.resetForTesting()
        let container = try makeContainer()
        let now = base.addingTimeInterval(3_600)
        let result = try await AskLifeLogQueryExecutor.execute(
            .strongestComparison(window: .thisWeek), context: askContext(now: now),
            reader: VisitArchiveReader(modelContainer: container), repairActor: ArchiveRepairActor(modelContainer: container),
            catalogue: [])
        guard case .noBaseline = result else { Issue.record("Expected noBaseline, got \(result)"); return }
    }

    // MARK: - Unlogged time

    @Test("unloggedTimeReview reports gaps overlapping the selected window, scoped")
    func unloggedTimeReviewFindsGapsInWindow() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Visit(arrival: base, departure: base.addingTimeInterval(3_600), latitude: 0, longitude: 0,
                             placeName: "Home", inferredActivity: "At home", userActivity: "At home"))
        // A two-hour gap, then a following visit that closes it.
        let after = base.addingTimeInterval(3_600 + 7_200)
        context.insert(Visit(arrival: after, departure: after.addingTimeInterval(1_800), latitude: 0, longitude: 0,
                             placeName: "Work", inferredActivity: "Working", userActivity: "Working"))
        try context.save()

        let now = after.addingTimeInterval(3_600)
        let result = try await AskLifeLogQueryExecutor.execute(
            .unloggedTimeReview(window: .thisWeek), context: askContext(now: now),
            reader: VisitArchiveReader(modelContainer: container), repairActor: ArchiveRepairActor(modelContainer: container),
            catalogue: [])
        guard case .answer(let answer) = result else { Issue.record("Expected an answer, got \(result)"); return }
        #expect(answer.headline.contains("1 gap"))
        #expect(answer.headline.contains("2h"))
    }

    // MARK: - Navigation

    @Test("navigation to a resolved place/activity carries a real drill-down route")
    func navigationToResolvedTargetsCarriesRoute() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Visit(arrival: base, departure: base.addingTimeInterval(600), latitude: 0, longitude: 0,
                             placeName: "Riverside Cafe", inferredActivity: "Coffee"))
        try context.save()

        let now = base.addingTimeInterval(3_600)
        let result = try await AskLifeLogQueryExecutor.execute(
            .navigation(.place(.init("Riverside Cafe"))), context: askContext(now: now),
            reader: VisitArchiveReader(modelContainer: container), repairActor: ArchiveRepairActor(modelContainer: container),
            catalogue: [])
        guard case .answer(let answer) = result else { Issue.record("Expected an answer, got \(result)"); return }
        #expect(answer.drillDown == .place(name: "Riverside Cafe"))
    }

    @Test("navigation to comparison/timeline degrades to guidance text rather than a fabricated route")
    func navigationToUnroutableTargetsHasNoDrillDown() async throws {
        let container = try makeContainer()
        let now = base.addingTimeInterval(3_600)
        let result = try await AskLifeLogQueryExecutor.execute(
            .navigation(.comparison), context: askContext(now: now),
            reader: VisitArchiveReader(modelContainer: container), repairActor: ArchiveRepairActor(modelContainer: container),
            catalogue: [])
        guard case .answer(let answer) = result else { Issue.record("Expected an answer, got \(result)"); return }
        #expect(answer.drillDown == nil)
    }

    // MARK: - Ambiguity and no-match, end to end through the executor

    @Test("A phrase matching several places surfaces ambiguity with the original plan intact")
    func ambiguousPlaceSurfacesThroughExecutor() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Visit(arrival: base, departure: base.addingTimeInterval(600), latitude: 0, longitude: 0,
                             placeName: "Riverside Cafe", inferredActivity: "Coffee"))
        context.insert(Visit(arrival: base.addingTimeInterval(1_000), departure: base.addingTimeInterval(1_600),
                             latitude: 0, longitude: 0, placeName: "Riverside Gym", inferredActivity: "Exercising"))
        try context.save()

        let now = base.addingTimeInterval(3_600)
        let plan = AskLifeLogQueryPlan.placeTotal(place: .init("Riverside"), window: .thisWeek)
        let result = try await AskLifeLogQueryExecutor.execute(
            plan, context: askContext(now: now),
            reader: VisitArchiveReader(modelContainer: container), repairActor: ArchiveRepairActor(modelContainer: container),
            catalogue: [])
        guard case .ambiguousPlace(let candidates, let returnedPlan) = result else {
            Issue.record("Expected ambiguousPlace, got \(result)"); return
        }
        #expect(candidates.count == 2)
        #expect(returnedPlan == plan)
    }

    @Test("A phrase matching nothing at all reports no match")
    func noMatchReportedForUnknownPhrase() async throws {
        let container = try makeContainer()
        let now = base.addingTimeInterval(3_600)
        let result = try await AskLifeLogQueryExecutor.execute(
            .placeTotal(place: .init("Nowhere At All"), window: .thisWeek), context: askContext(now: now),
            reader: VisitArchiveReader(modelContainer: container), repairActor: ArchiveRepairActor(modelContainer: container),
            catalogue: [])
        guard case .noMatch = result else { Issue.record("Expected noMatch, got \(result)"); return }
    }

    // MARK: - No data / sparse data

    @Test("A resolved place with zero hours in the window reports no data, not a zero total")
    func resolvedPlaceWithNoHoursReportsNoData() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        // The place exists in history, but entirely outside the queried window.
        context.insert(Visit(arrival: base.addingTimeInterval(-30 * 86_400),
                             departure: base.addingTimeInterval(-30 * 86_400 + 600),
                             latitude: 0, longitude: 0, placeName: "Old Office", inferredActivity: "Working"))
        try context.save()

        let now = base.addingTimeInterval(3_600)
        let result = try await AskLifeLogQueryExecutor.execute(
            .placeTotal(place: .init("Old Office"), window: .thisWeek), context: askContext(now: now),
            reader: VisitArchiveReader(modelContainer: container), repairActor: ArchiveRepairActor(modelContainer: container),
            catalogue: [])
        guard case .noData = result else { Issue.record("Expected noData, got \(result)"); return }
    }

    // MARK: - Source-scope enforcement

    @Test("deviceAndManual scope excludes imported-journal visits from a place total")
    func scopeExcludesImportedJournal() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Visit(arrival: base, departure: base.addingTimeInterval(3_600), latitude: 0, longitude: 0,
                             placeName: "Office", inferredActivity: "Working", source: "automatic"))
        context.insert(Visit(arrival: base.addingTimeInterval(7_200), departure: base.addingTimeInterval(10_800),
                             latitude: 0, longitude: 0, placeName: "Office", inferredActivity: "Working",
                             source: "imported-journal"))
        try context.save()

        let now = base.addingTimeInterval(11_000)
        let allHistory = try await AskLifeLogQueryExecutor.execute(
            .placeTotal(place: .init("Office"), window: .thisWeek), context: askContext(now: now, scope: .allHistory),
            reader: VisitArchiveReader(modelContainer: container), repairActor: ArchiveRepairActor(modelContainer: container),
            catalogue: [])
        let deviceOnly = try await AskLifeLogQueryExecutor.execute(
            .placeTotal(place: .init("Office"), window: .thisWeek), context: askContext(now: now, scope: .deviceAndManual),
            reader: VisitArchiveReader(modelContainer: container), repairActor: ArchiveRepairActor(modelContainer: container),
            catalogue: [])
        guard case .answer(let allAnswer) = allHistory, case .answer(let deviceAnswer) = deviceOnly else {
            Issue.record("Expected answers for both scopes"); return
        }
        #expect(allAnswer.headline == "2h")
        #expect(deviceAnswer.headline == "1h")
    }

    // MARK: - Archive-scale budget

    @Test("A place-ranking query stays within budget against a 32,000-row archive")
    func placeRankingBudgetOnLargeArchive() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        for index in 0..<32_000 {
            let arrival = base.addingTimeInterval(Double(index) * 1_800)
            context.insert(Visit(arrival: arrival, departure: arrival.addingTimeInterval(1_200),
                                 latitude: 0, longitude: 0, placeName: "Place \(index % 500)",
                                 inferredActivity: "Visiting", source: "automatic"))
        }
        try context.save()

        // "This week" narrows the fetch to a small slice of the 32,000 rows -- the
        // budget is on the bounded query itself, not on scanning the whole archive.
        let now = base.addingTimeInterval(Double(1_000) * 1_800)
        let startedAt = Date.now
        let result = try await AskLifeLogQueryExecutor.execute(
            .placeRanking(metric: .totalHours, order: .most, window: .thisWeek), context: askContext(now: now),
            reader: VisitArchiveReader(modelContainer: container), repairActor: ArchiveRepairActor(modelContainer: container),
            catalogue: [])
        let elapsed = Date.now.timeIntervalSince(startedAt)
        #expect(elapsed < Diagnostics.PerformanceBudget.askLifeLogQuery,
                "placeRanking took \(elapsed)s for the 32,000-row fixture")
        guard case .answer = result else { Issue.record("Expected an answer, got \(result)"); return }
    }
}
