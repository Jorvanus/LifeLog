import Foundation
import SwiftData
import CoreLocation

enum LocationCallbackType: Codable, Sendable, Equatable, Hashable {
    case visitArrival, visitDeparture, locationUpdate, geofenceEntry, geofenceExit
    case authorization, failure, liveLocationSample, liveLocationConfirmed
    case unknown(String)

    static let visitArrivalRaw = "visit-arrival"
    static let visitDepartureRaw = "visit-departure"
    static let locationUpdateRaw = "location-update"
    static let geofenceEntryRaw = "geofence-entry"
    static let geofenceExitRaw = "geofence-exit"
    static let authorizationRaw = "authorization"
    static let failureRaw = "failure"
    static let liveLocationSampleRaw = "live-location-sample"
    static let liveLocationConfirmedRaw = "live-location-confirmed"

    init(rawValue: String) {
        switch rawValue {
        case Self.visitArrivalRaw: self = .visitArrival
        case Self.visitDepartureRaw: self = .visitDeparture
        case Self.locationUpdateRaw: self = .locationUpdate
        case Self.geofenceEntryRaw: self = .geofenceEntry
        case Self.geofenceExitRaw: self = .geofenceExit
        case Self.authorizationRaw: self = .authorization
        case Self.failureRaw: self = .failure
        case Self.liveLocationSampleRaw: self = .liveLocationSample
        case Self.liveLocationConfirmedRaw: self = .liveLocationConfirmed
        default: self = .unknown(rawValue)
        }
    }
    var rawValue: String {
        switch self {
        case .visitArrival: Self.visitArrivalRaw
        case .visitDeparture: Self.visitDepartureRaw
        case .locationUpdate: Self.locationUpdateRaw
        case .geofenceEntry: Self.geofenceEntryRaw
        case .geofenceExit: Self.geofenceExitRaw
        case .authorization: Self.authorizationRaw
        case .failure: Self.failureRaw
        case .liveLocationSample: Self.liveLocationSampleRaw
        case .liveLocationConfirmed: Self.liveLocationConfirmedRaw
        case .unknown(let raw): raw
        }
    }
    init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
}

enum LocationCallbackTransition: Codable, Sendable, Equatable, Hashable {
    case created, closed, merged, superseded, ignored, none
    case unknown(String)

    static let createdRaw = "created"
    static let closedRaw = "closed"
    static let mergedRaw = "merged"
    static let supersededRaw = "superseded"
    static let ignoredRaw = "ignored"
    static let noneRaw = "none"

    init(rawValue: String) {
        switch rawValue {
        case Self.createdRaw: self = .created
        case Self.closedRaw: self = .closed
        case Self.mergedRaw: self = .merged
        case Self.supersededRaw: self = .superseded
        case Self.ignoredRaw: self = .ignored
        case Self.noneRaw: self = .none
        default: self = .unknown(rawValue)
        }
    }
    var rawValue: String {
        switch self {
        case .created: Self.createdRaw
        case .closed: Self.closedRaw
        case .merged: Self.mergedRaw
        case .superseded: Self.supersededRaw
        case .ignored: Self.ignoredRaw
        case .none: Self.noneRaw
        case .unknown(let raw): raw
        }
    }
    init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
}

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
         distanceFromCurrentVisit: Double? = nil, transition: String = LocationCallbackTransition.noneRaw,
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
    var callback: LocationCallbackType { LocationCallbackType(rawValue: callbackType) }
    var resolverTransition: LocationCallbackTransition { LocationCallbackTransition(rawValue: transition) }

    /// How long after the moment it describes the callback actually arrived. Core
    /// Location can deliver a `CLVisit` many minutes late, and a stay that looks
    /// mistimed is often a callback that was.
    var deliveryDelay: TimeInterval { recordedAt.timeIntervalSince(callbackAt) }
}
