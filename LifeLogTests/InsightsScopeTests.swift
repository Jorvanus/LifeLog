import Foundation
import Testing
@testable import LifeLog

struct InsightsScopeTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Insights scopes keep only their declared sources")
    func sourceFiltering() {
        let automatic = Visit(arrival: start, departure: start.addingTimeInterval(3_600),
                              latitude: -23.37, longitude: 150.51, placeName: "Home",
                              inferredActivity: "At home", source: "automatic",
                              recognitionConfidence: "confirmed")
        let manual = Visit(arrival: start.addingTimeInterval(3_600),
                           departure: start.addingTimeInterval(7_200), latitude: 0, longitude: 0,
                           placeName: "Manual place", inferredActivity: "Visiting", source: "manual")
        let device = Visit(arrival: start.addingTimeInterval(7_200),
                           departure: start.addingTimeInterval(8_200), latitude: 0, longitude: 0,
                           placeName: "Walking", inferredActivity: "Walking", source: "health-walking")
        let imported = Visit(arrival: start.addingTimeInterval(8_200),
                             departure: start.addingTimeInterval(9_200), latitude: 0, longitude: 0,
                             placeName: "Journal", inferredActivity: "Writing", source: "imported-journal")
        let visits = [automatic, manual, device, imported]

        #expect(InsightsScope.allHistory.filtering(visits).count == 4)
        #expect(InsightsScope.deviceAndManual.filtering(visits).count == 3)
        let importedMatches = InsightsScope.importedJournal.filtering(visits)
        #expect(importedMatches.count == 1)
        #expect(importedMatches.first === imported)
        let confirmedMatches = InsightsScope.confirmedLocations.filtering(visits)
        #expect(confirmedMatches.count == 2)
        #expect(confirmedMatches.first === automatic)
        #expect(confirmedMatches.last === manual)
    }

    @Test("Confirmed locations exclude provisional automatic guesses")
    func confirmedLocationBoundary() {
        let provisional = Visit(arrival: start, departure: start.addingTimeInterval(600),
                                latitude: -23.37, longitude: 150.51, placeName: Visit.unknownPlaceName,
                                inferredActivity: "Visiting", source: "automatic")
        let confirmed = Visit(arrival: start.addingTimeInterval(600),
                              departure: start.addingTimeInterval(1_200), latitude: -23.37, longitude: 150.51,
                              placeName: "Cafe", inferredActivity: "Coffee", source: "automatic",
                              recognitionConfidence: "learned")

        #expect(provisional.resolutionState == .provisional)
        #expect(confirmed.resolutionState == .resolved)
        let matches = InsightsScope.confirmedLocations.filtering([provisional, confirmed])
        #expect(matches.count == 1)
        #expect(matches.first === confirmed)
    }

    @Test("Only device-inclusive scopes show Health-derived summaries")
    func healthScopeBoundary() {
        #expect(InsightsScope.allHistory.includesHealthData)
        #expect(InsightsScope.deviceAndManual.includesHealthData)
        #expect(!InsightsScope.importedJournal.includesHealthData)
        #expect(!InsightsScope.confirmedLocations.includesHealthData)
    }

    @Test("Trend exports keep the selected source scope")
    func exportScopeBoundary() throws {
        let location = Visit(arrival: start, departure: start.addingTimeInterval(600),
                             latitude: -23.37, longitude: 150.51, placeName: "Home",
                             inferredActivity: "At home", source: "automatic",
                             recognitionConfidence: "confirmed")
        let journal = Visit(arrival: start.addingTimeInterval(600),
                            departure: start.addingTimeInterval(1_200), latitude: 0, longitude: 0,
                            placeName: "Journal", inferredActivity: "Writing", source: "imported-journal")
        let interval = DateInterval(start: start, end: start.addingTimeInterval(1_800))
        let file = try #require(TrendExport.makeFile(format: "csv", visits: [location, journal],
                                                     interval: interval, now: interval.end,
                                                     scope: .importedJournal))
        defer { try? FileManager.default.removeItem(at: file.url) }
        let csv = try String(contentsOf: file.url, encoding: .utf8)
        #expect(csv.contains("Journal"))
        #expect(!csv.contains("Home"))
    }
}
