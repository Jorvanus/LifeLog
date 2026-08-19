import Foundation
import Testing
@testable import LifeLog

struct AnnualInsightsTests {
    private let calendar = Calendar(identifier: .gregorian)

    @Test("Incomplete current year keeps all months and does not claim a comparison")
    func incompleteCurrentYear() {
        let yearStart = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let year = calendar.dateInterval(of: .year, for: yearStart)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 15))!
        let result = AnnualInsights.make(current: [segment("Work", start: yearStart, hours: 4)],
                                         previous: [], yearInterval: year, now: now)
        #expect(result.months.count == 12)
        #expect(result.months.filter(\.isPartial).count == 1)
        #expect(!result.comparisonSupported)
        #expect(result.placesNotVisited.isEmpty)
    }

    @Test("Sparse years do not produce unsupported annual milestones")
    func sparseYear() {
        let start = calendar.date(from: DateComponents(year: 2025, month: 1, day: 1))!
        let year = calendar.dateInterval(of: .year, for: start)!
        let result = AnnualInsights.make(current: [segment("Travel", start: start, hours: 1)],
                                         previous: [segment("Travel", start: start.addingTimeInterval(-365 * 86_400), hours: 1)],
                                         yearInterval: year, now: start.addingTimeInterval(365 * 86_400))
        #expect(!result.comparisonSupported)
        #expect(result.milestones.leadingIncrease == nil)
        #expect(result.milestones.longestActivityStreak == nil)
    }

    @Test("Imported-only segments remain measurable without inventing place confidence")
    func importedOnlyHistory() {
        let start = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let year = calendar.dateInterval(of: .year, for: start)!
        let imported = segment("Travel", start: start, hours: 6, source: "imported-journal", place: nil)
        let result = AnnualInsights.make(current: [imported], previous: [imported],
                                         yearInterval: year, now: year.end)
        #expect(result.currentLoggedHours == 6)
        #expect(result.placesByTime.isEmpty)
        #expect(result.travel.hours == 6)
    }

    @Test("The imported journal's own placeholder never shows as a place")
    func importedJournalPlaceholderIsExcludedFromPlaces() {
        // The real shape: an imported visit's placeName is the literal string
        // "Imported journal", not nil -- `place: nil` above tests a different,
        // easier case (`makePlaceTotals`-style visits) that this bug never hit.
        let start = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let year = calendar.dateInterval(of: .year, for: start)!
        let placeholder = segment("Travel", start: start, hours: 6, source: "imported-journal",
                                  place: "Imported journal")
        let real = segment("Food & Drink", start: start.addingTimeInterval(7 * 3_600), hours: 1,
                           source: "imported-journal", place: "The Two Professors")

        let result = AnnualInsights.make(current: [placeholder, real], previous: [],
                                         yearInterval: year, now: year.end)

        #expect(result.currentLoggedHours == 7, "the hours are still counted, only the Places entry is withheld")
        #expect(result.placesByTime.map(\.name) == ["The Two Professors"])
    }

    @Test("Comparison boundaries require meaningful history in both years")
    func comparisonBoundary() {
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let year = calendar.dateInterval(of: .year, for: start)!
        let current = segment("Work", start: start, hours: 24)
        let prior = segment("Work", start: start.addingTimeInterval(-365 * 86_400), hours: 24)
        let result = AnnualInsights.make(current: [current], previous: [prior],
                                         yearInterval: year, now: year.end)
        #expect(result.comparisonSupported)
        #expect(result.milestones.leadingIncrease == nil)
    }

    @Test("New places exclude anything in the historical name set; not-visited needs a real prior pattern")
    func placesUseHistoricalNameSet() {
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let year = calendar.dateInterval(of: .year, for: start)!
        // "Old Gym" appeared often enough last year (3 visits, >= 8h) to count
        // as a real pattern -- `placesNotVisited` requires both.
        let priorGym = (0..<3).map { offset in
            segment("Exercising", start: start.addingTimeInterval(Double(-300 + offset) * 86_400), hours: 3, place: "Old Gym")
        }
        // "Café" is in this year's segments and also in the historical name set —
        // not new. "New Café" is in this year's segments but not in the
        // historical set — genuinely new. Both years need >= 24h logged for
        // `placesNotVisited` to be computed at all, hence "Work" padding both.
        let currentWork = segment("Work", start: start.addingTimeInterval(3 * 86_400), hours: 30, place: "Office")
        let currentCafe = segment("Coffee", start: start.addingTimeInterval(86_400), hours: 2, place: "Café")
        let currentNewCafe = segment("Coffee", start: start.addingTimeInterval(2 * 86_400), hours: 2, place: "New Café")
        let priorWork = segment("Work", start: start.addingTimeInterval(-310 * 86_400), hours: 30, place: "Office")

        let result = AnnualInsights.make(current: [currentWork, currentCafe, currentNewCafe], previous: priorGym + [priorWork],
                                         yearInterval: year, now: year.end,
                                         historicalPlaceNames: ["Café", "Old Gym", "Office"])

        #expect(result.newPlaces.map(\.name) == ["New Café"], "Café is in the historical set, so it is not new")
        #expect(result.placesNotVisited.map(\.name) == ["Old Gym"],
                "a real prior pattern absent from this year's segments is reported")
    }

    @Test("Annual chart keeps the five strongest groups and folds the rest into Other")
    func annualChartDataUsesFiveGroupsAndOther() {
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let months = (0..<12).map { offset in
            AnnualInsights.Month(date: calendar.date(byAdding: .month, value: offset, to: start)!,
                                 label: "M\(offset)", isPartial: false,
                                 hours: ["Home": 100, "Work": 80, "Travel": 60,
                                         "Social": 40, "Fitness": 20,
                                         "Food & Drink": 10, "Errands": 0.2])
        }
        let rows = AnnualGroupChartDataBuilder.make(months: months)
        #expect(rows.map(\.group) == ["Home", "Work", "Travel", "Social", "Fitness", "Other"])
        // Summing a repeating decimal twelve times lands a few ulps from the literal,
        // so these compare within a tolerance. They were written as `==` and failed on
        // every run for exactly that reason -- 122.40000000000002 != 122.4 -- which
        // read as a permanently broken test rather than as arithmetic behaving.
        #expect(abs((rows.last?.totalHours ?? 0) - 122.4) < 0.0001)
        #expect(abs(rows.reduce(0) { $0 + $1.totalHours } - 12 * 310.2) < 0.0001)
        // The folded row has to name the groups it stands for, or opening it shows
        // less than the bar it was tapped from.
        #expect(rows.last?.foldedGroups == ["Errands", "Food & Drink"])
    }

    /// Groups earn a series from history rather than from a fixed list, so one a
    /// person added themselves can appear. The retired "life area" vocabulary was
    /// fixed at nine names and could not.
    @Test("A group the app never shipped still gets its own series")
    func customGroupAppearsInTheChart() {
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let months = [AnnualInsights.Month(date: start, label: "M0", isPartial: false,
                                           hours: ["Volunteering": 40, "Home": 10])]
        let rows = AnnualGroupChartDataBuilder.make(months: months)
        #expect(rows.map(\.group) == ["Volunteering", "Home"])
    }

    /// `CategoryPalette` is keyed by group name, and anything missing from it draws
    /// the shared grey fallback. That is exactly how the retired life-area names
    /// ("Sleep & Rest", "Health & Fitness", "Errands") went grey -- they were never
    /// palette keys -- putting most of a real year into indistinguishable series.
    @Test("Every shipped group resolves its own colour, not the grey fallback")
    func shippedGroupsDoNotFallBackToGrey() {
        let fallback = insightColor(for: "unmatched-category-xyz")
        for group in ActivityCatalog.defaultCategories where group != ActivityCatalog.fallbackCategory {
            #expect(insightColor(for: group) != fallback,
                    "group \"\(group)\" resolved to the grey fallback")
        }
    }

    private func segment(_ category: String, start: Date, hours: Double,
                         source: String = "automatic", place: String? = "Test place") -> InsightSegment {
        let visit = Visit(arrival: start, departure: start.addingTimeInterval(hours * 3_600),
                          latitude: place == nil ? 0 : -27.47, longitude: place == nil ? 0 : 153.03,
                          placeName: place ?? "", inferredActivity: category, source: source)
        return InsightSegment(id: .visit(ObjectIdentifier(visit)), visit: visit, commute: nil,
                              category: category, activity: category, placeName: place,
                              start: start, end: start.addingTimeInterval(hours * 3_600), hours: hours,
                              color: insightColor(for: category), symbol: insightSymbol(for: category),
                              isUnlogged: false, isLive: false)
    }
}
