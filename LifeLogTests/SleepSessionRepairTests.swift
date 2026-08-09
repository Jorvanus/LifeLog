import Foundation
import SwiftData
import Testing
@testable import LifeLog

struct SleepSessionRepairTests {
    @Test("Overlapping sleep visits merge into the earliest-starting one")
    func mergesOverlappingSleepVisits() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Visit.self, SavedPlace.self, VisitCorrection.self,
                                           configurations: configuration)
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(8 * 60 * 60)
        let earlierID = UUID()
        let laterID = UUID()
        // The exact shape found on the device 2026-08-10: two health-sleep visits
        // for the same night, sharing an end time, 8.5 minutes apart at the start.
        context.insert(Visit(arrival: start, departure: end,
                             latitude: 0, longitude: 0, placeName: "Sleep",
                             inferredActivity: "Sleeping", userActivity: "Sleeping",
                             source: "health-sleep", recognitionConfidence: "device",
                             healthKitSampleIDs: [earlierID]))
        context.insert(Visit(arrival: start.addingTimeInterval(8.5 * 60), departure: end,
                             latitude: 0, longitude: 0, placeName: "Sleep",
                             inferredActivity: "Sleeping", userActivity: "Sleeping",
                             source: "health-sleep", recognitionConfidence: "device",
                             healthKitSampleIDs: [laterID]))
        try context.save()

        let merged = try SleepSessionRepair.mergeDuplicates(context: context)

        let visits = try ModelContext(container).fetch(FetchDescriptor<Visit>())
            .filter { $0.source == "health-sleep" }
        #expect(merged == 1)
        #expect(visits.count == 1)
        #expect(visits.first?.arrival == start)
        #expect(visits.first?.departure == end)
        #expect(Set(visits.first?.healthKitSampleIDs ?? []) == [earlierID, laterID])
    }

    @Test("A confirmed sleep visit's label survives being merged into")
    func keepsConfirmedLabelWhenMerged() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Visit.self, SavedPlace.self, VisitCorrection.self,
                                           configurations: configuration)
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(8 * 60 * 60)
        context.insert(Visit(arrival: start, departure: end,
                             latitude: 0, longitude: 0, placeName: "Sleep",
                             inferredActivity: "Sleeping", userActivity: "Sleeping",
                             source: "health-sleep", recognitionConfidence: "device"))
        context.insert(Visit(arrival: start.addingTimeInterval(5 * 60), departure: end,
                             latitude: 0, longitude: 0, placeName: "Sleep",
                             inferredActivity: "Sleeping", userActivity: "In bed, awake",
                             source: "health-sleep", recognitionConfidence: "confirmed"))
        try context.save()

        let merged = try SleepSessionRepair.mergeDuplicates(context: context)

        let visits = try ModelContext(container).fetch(FetchDescriptor<Visit>())
            .filter { $0.source == "health-sleep" }
        #expect(merged == 1)
        #expect(visits.count == 1)
        #expect(visits.first?.recognitionConfidence == "confirmed")
        #expect(visits.first?.userActivity == "In bed, awake")
    }

    @Test("Sleep visits more than 15 minutes apart are left as separate nights")
    func leavesDistinctNightsAlone() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Visit.self, SavedPlace.self, VisitCorrection.self,
                                           configurations: configuration)
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        context.insert(Visit(arrival: start, departure: start.addingTimeInterval(8 * 60 * 60),
                             latitude: 0, longitude: 0, placeName: "Sleep",
                             inferredActivity: "Sleeping", source: "health-sleep"))
        let nextNight = start.addingTimeInterval(24 * 60 * 60)
        context.insert(Visit(arrival: nextNight, departure: nextNight.addingTimeInterval(8 * 60 * 60),
                             latitude: 0, longitude: 0, placeName: "Sleep",
                             inferredActivity: "Sleeping", source: "health-sleep"))
        try context.save()

        let merged = try SleepSessionRepair.mergeDuplicates(context: context)

        let visits = try ModelContext(container).fetch(FetchDescriptor<Visit>())
            .filter { $0.source == "health-sleep" }
        #expect(merged == 0)
        #expect(visits.count == 2)
    }
}
