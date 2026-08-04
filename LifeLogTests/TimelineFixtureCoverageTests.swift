import Foundation
import CoreLocation
import SwiftData
import Testing
@testable import LifeLog

@MainActor
struct TimelineFixtureCoverageTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Overlapping destinations never expose movement inside an occupied interval")
    func overlappingVisitsAreLocationFirst() {
        let destinations = (0..<80).map { index in
            Visit(
                arrival: base.addingTimeInterval(Double(index) * 3_600),
                departure: base.addingTimeInterval(Double(index) * 3_600 + 2_400),
                latitude: -27.47 + Double(index) * 0.0001,
                longitude: 153.03,
                placeName: "Destination \(index)",
                placeCategory: "Other",
                inferredActivity: "Visiting",
                source: "automatic"
            )
        }
        let movement = Visit(
            arrival: base.addingTimeInterval(10 * 3_600 + 1_200),
            departure: base.addingTimeInterval(10 * 3_600 + 3_000),
            latitude: 0, longitude: 0, placeName: "Walking",
            placeCategory: "Walking", inferredActivity: "Walking",
            userActivity: "Walking", source: "health-walking"
        )

        #expect(ActivityLocationPolicy.shouldShow(movement, locationVisits: destinations) == false)
    }

    @Test("Malformed visit fixtures are sanitized and invalid coordinates are not learned")
    func malformedSamplesRemainSafe() throws {
        let malformed = Visit(
            arrival: base, departure: base.addingTimeInterval(-60),
            latitude: .nan, longitude: .infinity,
            placeName: "  \u{0000}\nUnknown place  ",
            placeCategory: "\u{0007}Other", inferredActivity: "\u{000B}Visiting",
            userActivity: "\u{000D}Visiting", note: "\u{0000}note",
            source: "automatic"
        )

        #expect(malformed.placeName == "Unknown place")
        #expect(malformed.placeCategory == "Other")
        #expect(malformed.note == "note")
        #expect(malformed.duration == 0)

        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Visit.self, SavedPlace.self,
                                            VisitCorrection.self, configurations: configuration)
        let context = ModelContext(container)
        context.insert(malformed)
        #expect(try SavedPlaceLearning.upsert(from: malformed, previousPlaceName: nil, context: context) == nil)
    }

    @Test("A long-running history remains stable across a deterministic fixture")
    func longHistoryFixture() {
        let visits = (0..<365).flatMap { day in
            (0..<4).map { slot in
                let start = base.addingTimeInterval(Double(day * 86_400 + slot * 3_600))
                return Visit(arrival: start, departure: start.addingTimeInterval(45 * 60),
                             latitude: -27.47, longitude: 153.03,
                             placeName: slot.isMultiple(of: 2) ? "Home" : "Work",
                             placeCategory: slot.isMultiple(of: 2) ? "Home" : "Work",
                             inferredActivity: slot.isMultiple(of: 2) ? "At home" : "Working",
                             source: "automatic")
            }
        }
        let movement = DateInterval(start: base.addingTimeInterval(12 * 86_400),
                                    end: base.addingTimeInterval(12 * 86_400 + 4 * 3_600))
        let remaining = ActivityLocationPolicy.remainingSegments(for: movement,
                                                                  locationVisits: visits)
        #expect(visits.count == 1_460)
        #expect(remaining.count == 4)
        #expect(remaining.allSatisfy { $0.duration >= 0 })
    }

    @Test("Date fixtures remain valid in extreme time zones")
    func unusualTimeZones() {
        let zones = ["Pacific/Kiritimati", "Pacific/Pago_Pago", "America/New_York", "UTC"]
        for identifier in zones {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: identifier)!
            let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1))!
            let end = calendar.date(byAdding: .hour, value: 6, to: start)!
            let interval = DateInterval(start: start, end: end)
            #expect(interval.duration == 6 * 3_600)
            #expect(calendar.startOfDay(for: start) <= start)
        }
    }

    @Test("Trend exports include safe visit fields in both formats")
    func trendExportFormats() throws {
        let visit = Visit(arrival: base, departure: base.addingTimeInterval(90 * 60),
                          latitude: -27.47, longitude: 153.03, placeName: "Corner, Cafe",
                          placeCategory: "Food & Drink", inferredActivity: "Eating",
                          source: "automatic", recognitionConfidence: "confirmed")
        let interval = DateInterval(start: base.addingTimeInterval(-60), end: base.addingTimeInterval(2 * 3_600))
        let csv = try #require(TrendExport.makeFile(format: "csv", visits: [visit], interval: interval, now: base.addingTimeInterval(2 * 3_600)))
        let json = try #require(TrendExport.makeFile(format: "json", visits: [visit], interval: interval, now: base.addingTimeInterval(2 * 3_600)))
        defer {
            try? FileManager.default.removeItem(at: csv.url)
            try? FileManager.default.removeItem(at: json.url)
        }

        let csvText = try String(contentsOf: csv.url, encoding: .utf8)
        let jsonText = try String(contentsOf: json.url, encoding: .utf8)
        #expect(csvText.contains("place,category,category_color,activity"))
        #expect(csvText.contains("Corner, Cafe"))
        #expect(jsonText.contains("Corner, Cafe"))
        #expect(jsonText.contains("Confirmed"))
    }

    @Test("Life Cycle journal CSV maps activities and tolerates malformed rows")
    func journalImportParsing() {
        let csv = """
        START DATE(UTC), END DATE(UTC), START TIME(LOCAL), END TIME(LOCAL), DURATION, NAME, LOCATION, NOTE
        2026-08-01 00:00:00, 2026-08-01 01:00:00, 2026-08-01 10:00:00 AEST, 2026-08-01 11:00:00 AEST, 3600, Sleep, Home, Rested
        malformed,row
        2026-08-01 02:00:00, 2026-08-01 02:30:00, 2026-08-01 12:00:00 AEST, 2026-08-01 12:30:00 AEST, 1800, Transport, ,
        """.data(using: .utf8)!

        let parsed = JournalCSVImporter.parse(csv)
        #expect(parsed.rows.count == 2)
        #expect(parsed.malformed == 1)
        #expect(parsed.rows[0].name == "Sleep")
        #expect(parsed.rows[1].name == "Transport")
    }
}
