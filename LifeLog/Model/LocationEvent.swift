import Foundation
import SwiftData
import CoreLocation

/// One raw location callback, as it arrived and as it was acted on.
///
/// Everything else LifeLog records is a conclusion — a visit, a correction, a
/// diagnostic sentence. When a stay lands in the wrong place or at the wrong time, the
/// conclusion is the thing in doubt, and the inputs that produced it are gone. This is
/// the input: what Core Location said, when it said it, and which branch the resolver
/// then took.
///
/// **This holds precise coordinates, and that is the point.** `DiagnosticEvent` was
/// built to be safe to hand to anyone and deliberately has no coordinate field; this is
/// its opposite, and the trade is made knowingly for a single-user app debugging its
/// own movement. It is written only while `LocationDiagnostics.isDetailed` is on, which
/// is off by default, and it is trimmed like every other log rather than kept forever.
///
/// There is no visit identifier to reference because the store has never had one.
/// `VisitCorrection` already solves this by correlating on the visit's arrival time and
/// coordinate, and this follows that idiom rather than adding a UUID to `Visit` — which
/// would mean migrating every one of 25,000 visits instead of adding an empty table.
@Model
final class LocationEvent {
    /// When the callback was handled, which is not always when it was for.
    var recordedAt: Date
    /// Which callback this was: `visit-arrival`, `visit-departure`, `location-update`,
    /// `geofence-entry`, `geofence-exit`, `authorization`, `failure`.
    var callbackType: String
    /// The moment the callback itself carries. For a `CLVisit` delivered late this is
    /// well before `recordedAt`, and the gap between them is the whole diagnosis.
    var callbackAt: Date
    /// The arrival and departure the callback reported, where it reported any.
    var arrival: Date?
    var departure: Date?
    var latitude: Double
    var longitude: Double
    /// Horizontal accuracy in metres. Negative where Core Location declined to say.
    var accuracy: Double
    /// How far this callback landed from the visit already in progress, in metres.
    /// Nil when nothing was open — which is itself worth being able to see.
    var distanceFromCurrentVisit: Double?
    /// What the resolver decided: `created`, `closed`, `merged`, `superseded`,
    /// `ignored`, `none`.
    var transition: String
    /// The arrival time of the visit this event acted on. The store's own way of
    /// pointing at a visit, matching `VisitCorrection`.
    var visitArrival: Date?

    init(recordedAt: Date = .now, callbackType: String, callbackAt: Date,
         arrival: Date? = nil, departure: Date? = nil,
         latitude: Double, longitude: Double, accuracy: Double,
         distanceFromCurrentVisit: Double? = nil, transition: String = "none",
         visitArrival: Date? = nil) {
        self.recordedAt = recordedAt
        self.callbackType = TextSafety.clean(callbackType, maximumLength: 30)
        self.callbackAt = callbackAt
        self.arrival = arrival
        self.departure = departure
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.distanceFromCurrentVisit = distanceFromCurrentVisit
        self.transition = TextSafety.clean(transition, maximumLength: 20)
        self.visitArrival = visitArrival
    }

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    /// How long after the moment it describes the callback actually arrived. Core
    /// Location can deliver a `CLVisit` many minutes late, and a stay that looks
    /// mistimed is often a callback that was.
    var deliveryDelay: TimeInterval { recordedAt.timeIntervalSince(callbackAt) }
}
