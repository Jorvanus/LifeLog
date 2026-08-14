import Foundation
import SwiftData
import CoreLocation
import Testing
@testable import LifeLog

/// Shared fixtures for the ActivityLocationPolicy test suites (split out of what was
/// one 2159-line file). Every suite in `LifeLogTests/ActivityLocationPolicy/` builds
/// its scenarios from these functions instead of redefining its own copies, so the
/// small in-file DSL the original file grew stays in exactly one place.
///
/// `base` is the fixture "now" every test measures its offsets from. It is a future
/// date on purpose (see `defaultBase`) — nothing here should assume it is close to
/// `Date.now`; anything that needs to reason about "today" takes its own `now:`
/// parameter, as the original tests did.
enum ActivityLocationPolicyFixtures {
    /// The fixture epoch every suite defaults to, unchanged from the original file's
    /// `private let base = Date(timeIntervalSince1970: 1_800_000_000)`. Kept as an
    /// explicit default (rather than hardcoded inside each helper) so a suite that
    /// ever needs a different clock can inject one without touching this file.
    static let defaultBase = Date(timeIntervalSince1970: 1_800_000_000)

    /// An in-memory SwiftData store with every model type the resolver reads or
    /// writes, matching the original file's `makeContext()` exactly.
    @MainActor
    static func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Visit.self,
            SavedPlace.self,
            VisitCorrection.self,
            // The resolver records why it merged, closed or superseded a callback, so
            // its diagnostics have to be part of the store these tests write to.
            DiagnosticEvent.self,
            configurations: configuration
        )
        return ModelContext(container)
    }

    /// A workout-backed walk carrying a recorded path.
    @MainActor
    static func walk(from startMinutes: Double, to endMinutes: Double,
                      path: [(Double, Double)], base: Date = ActivityLocationPolicyFixtures.defaultBase) -> Visit {
        let start = base.addingTimeInterval(startMinutes * 60)
        let end = base.addingTimeInterval(endMinutes * 60)
        let visit = Visit(arrival: start, departure: end,
                          latitude: 0, longitude: 0, placeName: "Walking workout",
                          inferredActivity: "Walking", userActivity: "Walking",
                          source: "health-workout", recognitionConfidence: "device")
        let step = end.timeIntervalSince(start) / Double(max(1, path.count - 1))
        visit.route = path.enumerated().map { index, point in
            RoutePoint(latitude: point.0, longitude: point.1,
                       time: start.addingTimeInterval(Double(index) * step))
        }
        return visit
    }

    @MainActor
    static func stay(_ name: String, from startMinutes: Double, to endMinutes: Double,
                      latitude: Double, longitude: Double,
                      base: Date = ActivityLocationPolicyFixtures.defaultBase) -> Visit {
        Visit(arrival: base.addingTimeInterval(startMinutes * 60),
              departure: base.addingTimeInterval(endMinutes * 60),
              latitude: latitude, longitude: longitude,
              placeName: name, inferredActivity: "Visiting",
              source: "automatic", recognitionConfidence: "learned")
    }

    /// A path along a line of longitude at a steady pace. Zero metres per second gives
    /// a path that stays exactly where it started, which is what a real stop looks like.
    static func straightRoute(from start: Date, to end: Date, latitude: Double,
                               longitude: Double, metresPerSecond: Double) -> [RoutePoint] {
        var points: [RoutePoint] = []
        var time = start
        while time <= end {
            let metres = metresPerSecond * time.timeIntervalSince(start)
            points.append(RoutePoint(latitude: latitude + metres / 111_000,
                                     longitude: longitude, time: time))
            time = time.addingTimeInterval(60)
        }
        return points
    }
}

/// Replays persisted Core Location facts in the same order they are delivered. The
/// recorder supplies coordinates and timestamps; the resolver remains the single
/// source of truth for closing, retaining, and superseding their timeline rows.
///
/// `base` is injected explicitly at `init`, defaulting to
/// `ActivityLocationPolicyFixtures.defaultBase` so every existing call site
/// (`LocationCallbackReplay(base: base)`) keeps its exact original behavior.
@MainActor
final class LocationCallbackReplay {
    private let context: ModelContext
    private let base: Date

    init(base: Date = ActivityLocationPolicyFixtures.defaultBase) throws {
        self.base = base
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Visit.self, SavedPlace.self, VisitCorrection.self,
                                           DiagnosticEvent.self, configurations: configuration)
        context = ModelContext(container)
    }

    func time(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    func arrive(_ name: String, at minutes: Double, latitude: Double, longitude: Double,
                mapsIdentifier: String) throws {
        context.insert(Visit(arrival: time(minutes), latitude: latitude, longitude: longitude,
                             placeName: name, inferredActivity: "Visiting", source: "automatic",
                             recognitionConfidence: "learned", mapsIdentifier: mapsIdentifier))
        try resolve()
    }

    func depart(arrival: Double, departure: Double, latitude: Double, longitude: Double) throws {
        let visits = try context.fetch(FetchDescriptor<Visit>())
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let matched = ActivityLocationPolicy.matchDeparture(
            coordinate: coordinate, arrival: time(arrival), departure: time(departure), visits: visits
        )
        #expect(matched != nil, "The replayed departure must resolve to its original arrival")
        matched?.departure = time(departure)
        matched?.locationResolutionExplanation = .coordinateTime
        try resolve()
    }

    func travel(from start: Double, to end: Double) throws {
        context.insert(Visit(arrival: time(start), departure: time(end), latitude: 0, longitude: 0,
                             placeName: "In transit", inferredActivity: "Travelling", source: "motion"))
        try resolve()
    }

    func liveStays() throws -> [Visit] {
        try context.fetch(FetchDescriptor<Visit>(sortBy: [SortDescriptor(\.arrival)]))
            .filter(ActivityLocationPolicy.isLocationVisit)
    }

    func supersededStays() throws -> [Visit] {
        try context.fetch(FetchDescriptor<Visit>()).filter(ActivityLocationPolicy.isSupersededLocation)
    }

    func travelRecords() throws -> [Visit] {
        try context.fetch(FetchDescriptor<Visit>()).filter { $0.source == "motion" }
    }

    private func resolve() throws {
        try ActivityLocationPolicy.resolveLocationCallbacks(context: context)
        try context.save()
    }
}
