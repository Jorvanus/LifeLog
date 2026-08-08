import Foundation
import SwiftData
import CoreLocation

/// Writes the raw location callbacks behind the timeline.
///
/// `LocationDiagnostics` records the *decision* — which rule fired, on what. This
/// records the *input*: the callback as Core Location delivered it, including where and
/// how accurately, and which branch the resolver then took. Between them a wrong stay
/// can be reconstructed instead of guessed at, which is how every location bug so far
/// has had to be approached.
///
/// Off unless `LocationDiagnostics.isDetailed` is on, and it shares that switch rather
/// than adding a second one: turning on detailed location diagnostics is already the
/// decision to keep a fine-grained record of your own movements on the device, and
/// splitting it in two would make that decision twice in two places.
@MainActor
enum LocationJournal {
    /// The journal is the chattiest thing in the store when it is on — several rows per
    /// arrival — so it is trimmed hard and on its own, where it cannot evict the
    /// diagnostics that outlive a single investigation.
    static let retentionLimit = 500

    enum Transition: String {
        case created, closed, merged, superseded, ignored, none
    }

    /// - Parameters:
    ///   - openVisit: the visit in progress when the callback landed, for the distance
    ///     between them. Nil when nothing was open, which is recorded as nil rather
    ///     than zero — "no stay was running" and "the callback was here" are different
    ///     facts and only one of them is a distance.
    static func record(_ callbackType: String, at coordinate: CLLocationCoordinate2D,
                       callbackAt: Date, arrival: Date? = nil, departure: Date? = nil,
                       accuracy: CLLocationAccuracy = -1,
                       transition: Transition = .none,
                       openVisit: Visit? = nil,
                       context: ModelContext?) {
        guard LocationDiagnostics.isDetailed, let context else { return }
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        let distance = openVisit.flatMap { visit -> Double? in
            guard visit.latitude != 0 || visit.longitude != 0 else { return nil }
            return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: CLLocation(latitude: visit.latitude, longitude: visit.longitude))
        }
        context.insert(LocationEvent(
            callbackType: callbackType, callbackAt: callbackAt,
            arrival: arrival, departure: departure,
            latitude: coordinate.latitude, longitude: coordinate.longitude,
            accuracy: accuracy, distanceFromCurrentVisit: distance,
            transition: transition.rawValue, visitArrival: openVisit?.arrival
        ))
        trim(context)
        try? context.save()
    }

    /// Counts first and deletes only the overflow, like the diagnostic log it sits
    /// beside — this runs on the location callback path, where loading the whole table
    /// to measure it would be the most expensive thing in the callback.
    private static func trim(_ context: ModelContext) {
        guard let count = try? context.fetchCount(FetchDescriptor<LocationEvent>()),
              count > retentionLimit else { return }
        var descriptor = FetchDescriptor<LocationEvent>(
            sortBy: [SortDescriptor(\LocationEvent.recordedAt, order: .forward)])
        descriptor.fetchLimit = count - retentionLimit
        if let stale = try? context.fetch(descriptor) {
            for event in stale { context.delete(event) }
        }
    }

    /// Empties the journal. Offered next to the switch that fills it, because turning
    /// the recording off and leaving what it already gathered on the device is not what
    /// anyone means by turning it off.
    @discardableResult
    static func clear(_ context: ModelContext) -> Int {
        guard let all = try? context.fetch(FetchDescriptor<LocationEvent>()) else { return 0 }
        for event in all { context.delete(event) }
        try? context.save()
        return all.count
    }
}
