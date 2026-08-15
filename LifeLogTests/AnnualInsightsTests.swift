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

    @Test("Annual chart keeps the five strongest areas and folds the rest into Other")
    func annualChartDataUsesFiveAreasAndOther() {
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let months = (0..<12).map { offset in
            AnnualInsights.Month(date: calendar.date(byAdding: .month, value: offset, to: start)!,
                                 label: "M\(offset)", isPartial: false,
                                 hours: ["Home": 100, "Work": 80, "Travel": 60,
                                         "Social": 40, "Health & Fitness": 20,
                                         "Food & Drink": 10, "Errands": 0.2])
        }
        let rows = AnnualLifeAreaChartDataBuilder.make(months: months)
        #expect(rows.map(\.area.name) == ["Home", "Work", "Travel", "Social", "Health & Fitness", "Other"])
        #expect(rows.last?.totalHours == 122.4)
        #expect(rows.reduce(0) { $0 + $1.totalHours } == 12 * 310.2)
    }

    /// `LifeArea.category` exists only to look up a colour and symbol, and
    /// `CategoryPalette` is keyed by `ActivityCatalog`'s shorter category
    /// vocabulary ("Sleep", "Fitness"), not by these longer display names
    /// ("Sleep & Rest", "Health & Fitness"). Every named area but "Other" must
    /// resolve to its own colour rather than silently falling through to the
    /// grey fallback every other area also shares.
    @Test("Every named annual life area resolves its own colour, not the grey fallback")
    func namedAreasDoNotFallBackToGrey() {
        let fallback = insightColor(for: "unmatched-category-xyz")
        for area in AnnualInsights.areas where area.name != "Other" {
            #expect(insightColor(for: area.category) != fallback,
                    "\(area.name) (category \"\(area.category)\") resolved to the grey fallback")
        }
    }

    private func segment(_ category: String, start: Date, hours: Double,
                         source: String = "automatic", place: String? = "Test place") -> InsightSegment {
        let visit = Visit(arrival: start, departure: start.addingTimeInterval(hours * 3_600),
                          latitude: place == nil ? 0 : -27.47, longitude: place == nil ? 0 : 153.03,
                          placeName: place ?? "", inferredActivity: category, source: source)
        return InsightSegment(id: .visit(ObjectIdentifier(visit)), visit: visit,
                              category: category, activity: category, placeName: place,
                              start: start, end: start.addingTimeInterval(hours * 3_600), hours: hours,
                              color: insightColor(for: category), symbol: insightSymbol(for: category),
                              isUnlogged: false, isLive: false)
    }
}
