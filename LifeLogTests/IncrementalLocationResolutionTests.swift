import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import LifeLog

@MainActor
struct IncrementalLocationResolutionTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Incremental resolution matches a full audit for callback ordering and place edge cases")
    func incrementalResolutionMatchesFullAudit() throws {
        for scenario in ResolutionScenario.allCases {
            let auditContext = try makeContext()
            _ = try install(scenario, in: auditContext)
            try ActivityLocationPolicy.runFullStoreAudit(context: auditContext, reason: "equivalence \(scenario.rawValue)")
            try auditContext.save()

            let incrementalContext = try makeContext()
            let incrementalMutation = try install(scenario, in: incrementalContext)
            try ActivityLocationPolicy.resolveAfterLocationMutation(context: incrementalContext,
                mutation: incrementalMutation)
            try incrementalContext.save()

            #expect(signature(in: incrementalContext) == signature(in: auditContext),
                    "Incremental result must match the full audit for \(scenario.rawValue)")
        }
    }

    @Test("Incremental mutation stays within the 32,000-row callback budget")
    func incrementalMutationBudgetOnLargeArchive() throws {
        let context = try makeContext()
        var affected: Visit?
        for index in 0..<32_000 {
            let arrival = base.addingTimeInterval(Double(index) * 1_800)
            let visit = Visit(arrival: arrival, departure: arrival.addingTimeInterval(1_200),
                              latitude: -27.47, longitude: 153.03,
                              placeName: index.isMultiple(of: 2) ? "Home" : "Work",
                              inferredActivity: index.isMultiple(of: 2) ? "At home" : "Working",
                              source: "automatic")
            context.insert(visit)
            if index == 31_999 { affected = visit }
        }
        try context.save()
        let visit = try #require(affected)
        let startedAt = Date.now
        try ActivityLocationPolicy.resolveAfterLocationMutation(context: context,
            mutation: .init(affectedVisit: visit, coordinate: visit.coordinate, reason: "32k performance fixture"))
        let elapsed = Date.now.timeIntervalSince(startedAt)

        #expect(elapsed < Diagnostics.PerformanceBudget.locationMutation,
                "Incremental resolver took \(elapsed)s for the 32,000-row fixture")
        let metrics = try context.fetch(FetchDescriptor<DiagnosticEvent>())
        #expect(metrics.contains { $0.subsystem == "Location resolver" && $0.message.contains("incremental mutation") })
    }

    private func install(_ scenario: ResolutionScenario, in context: ModelContext) throws
    -> ActivityLocationPolicy.IncrementalMutation {
        @discardableResult
        func stay(_ name: String, _ start: Double, _ end: Double? = nil,
                  latitude: Double, longitude: Double, mapsID: String? = nil,
                  confidence: String = "learned", state: VisitResolutionState? = nil) -> Visit {
            let visit = Visit(arrival: base.addingTimeInterval(start * 60),
                              departure: end.map { base.addingTimeInterval($0 * 60) },
                              latitude: latitude, longitude: longitude, placeName: name,
                              inferredActivity: name == "Home" ? "At home" : "Visiting",
                              source: "automatic", recognitionConfidence: confidence,
                              mapsIdentifier: mapsID, resolutionState: state)
            context.insert(visit)
            return visit
        }

        let mutation: ActivityLocationPolicy.IncrementalMutation
        switch scenario {
        case .homeDestinationHome:
            let home = stay("Home", 0, 60, latitude: -27.47, longitude: 153.03, mapsID: "home")
            _ = stay("Office", 75, 480, latitude: -27.46, longitude: 153.04, mapsID: "office")
            _ = stay("Home", 500, nil, latitude: -27.47, longitude: 153.03, mapsID: "home")
            mutation = .init(affectedVisit: home,
                             callbackInterval: DateInterval(start: base, end: base.addingTimeInterval(9 * 3_600)),
                             coordinate: home.coordinate, reason: scenario.rawValue)
        case .delayedDeparture:
            let home = stay("Home", 0, 240, latitude: -27.47, longitude: 153.03, mapsID: "home")
            _ = stay("Office", 180, nil, latitude: -27.46, longitude: 153.04, mapsID: "office")
            mutation = .init(affectedVisit: home, coordinate: home.coordinate, reason: scenario.rawValue)
        case .outOfOrderArrival:
            _ = stay("Office", 180, nil, latitude: -27.46, longitude: 153.04, mapsID: "office")
            let home = stay("Home", 0, 240, latitude: -27.47, longitude: 153.03, mapsID: "home")
            mutation = .init(affectedVisit: home,
                             callbackInterval: DateInterval(start: base, end: base.addingTimeInterval(4 * 3_600)),
                             coordinate: home.coordinate, reason: scenario.rawValue)
        case .duplicateCallback:
            let first = stay("Home", 0, nil, latitude: -27.47, longitude: 153.03, mapsID: "home")
            _ = stay("Home", 0.25, nil, latitude: -27.47001, longitude: 153.03001, mapsID: "home")
            mutation = .init(affectedVisit: first, coordinate: first.coordinate, reason: scenario.rawValue)
        case .repeatedPlace:
            for day in 0..<4 { _ = stay("Coffee", Double(day * 1_440), Double(day * 1_440 + 45), latitude: -27.46, longitude: 153.04, mapsID: "coffee") }
            let latest = stay("Coffee", 5_760, nil, latitude: -27.46, longitude: 153.04, mapsID: "coffee")
            mutation = .init(affectedVisit: latest, coordinate: latest.coordinate, reason: scenario.rawValue)
        case .neighbouringBusinesses:
            let bakery = stay("Bakery", 0, 60, latitude: -27.4700, longitude: 153.0300, mapsID: "bakery")
            _ = stay("Cafe", 65, nil, latitude: -27.4702, longitude: 153.0302, mapsID: "cafe")
            mutation = .init(affectedVisit: bakery, coordinate: bakery.coordinate, reason: scenario.rawValue)
        case .weekDeliveredLater:
            var newest: Visit?
            for day in 0..<7 {
                _ = stay("Home", Double(day * 1_440), Double(day * 1_440 + 480), latitude: -27.47, longitude: 153.03, mapsID: "home")
                newest = stay("Office", Double(day * 1_440 + 540), Double(day * 1_440 + 1_000), latitude: -27.46, longitude: 153.04, mapsID: "office")
            }
            let visit = try #require(newest)
            mutation = .init(affectedVisit: visit,
                             callbackInterval: DateInterval(start: base, end: base.addingTimeInterval(7 * 86_400)),
                             coordinate: visit.coordinate, reason: scenario.rawValue)
        case .confirmedAndIgnored:
            let confirmed = stay("Home", 0, 180, latitude: -27.47, longitude: 153.03,
                                 mapsID: "home", confidence: "confirmed", state: .resolved)
            _ = stay("Ignored", 120, nil, latitude: -27.46, longitude: 153.04, mapsID: "ignored", state: .ignored)
            mutation = .init(affectedVisit: confirmed, coordinate: confirmed.coordinate, reason: scenario.rawValue)
        }
        try context.save()
        return mutation
    }

    private func signature(in context: ModelContext) -> [String] {
        (try? context.fetch(FetchDescriptor<Visit>(sortBy: [SortDescriptor(\.arrival)])))?.map { visit in
            [visit.source, String(visit.arrival.timeIntervalSince1970),
             visit.departure.map { String($0.timeIntervalSince1970) } ?? "open",
             visit.placeName, visit.activity, visit.mapsIdentifier ?? "", visit.resolutionStateRaw].joined(separator: "|")
        } ?? []
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Visit.self, SavedPlace.self, VisitCorrection.self,
                                           DiagnosticEvent.self, configurations: configuration)
        return ModelContext(container)
    }
}

private enum ResolutionScenario: String, CaseIterable {
    case homeDestinationHome = "Home-destination-Home"
    case delayedDeparture = "delayed departure"
    case outOfOrderArrival = "out-of-order arrival"
    case duplicateCallback = "duplicate callback"
    case repeatedPlace = "repeated place"
    case neighbouringBusinesses = "neighbouring businesses"
    case weekDeliveredLater = "week delivered later"
    case confirmedAndIgnored = "confirmed and ignored"
}
