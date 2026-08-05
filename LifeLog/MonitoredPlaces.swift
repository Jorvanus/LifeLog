import Foundation
import CoreLocation

/// Chooses which Saved Places the system watches for.
///
/// iOS monitors a limited number of regions per app, so once someone has more places
/// than that, some are simply not watched. Which ones are dropped should not be
/// whichever happened to be created last: a place visited twice a day is worth a slot
/// far more than one visited once a year, however recently it was added.
///
/// Ranked by how often a place is used, then by how recently. Frequency first because
/// it predicts the next arrival better than recency does — a holiday cottage visited
/// yesterday is still less likely than the office visited every weekday.
enum MonitoredPlaces {
    /// iOS allows twenty monitored regions per app. Left as a constant rather than a
    /// literal so the reason for the number stays attached to it.
    static let limit = 20

    struct Ranked: Sendable {
        let name: String
        let latitude: Double
        let longitude: Double
        let radius: Double
        let visits: Int
        let lastVisit: Date?

        var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
        /// Stable across launches and independent of the store's identifiers, so a
        /// monitored region can be matched back to its place after a cold start.
        var identifier: String { "place|\(name.lowercased())|\(rounded(latitude)),\(rounded(longitude))" }

        private func rounded(_ value: Double) -> String { String(format: "%.5f", value) }
    }

    static func prioritised(_ places: [SavedPlace], visits: [Visit],
                            limit: Int = limit) -> [Ranked] {
        let stays = visits.filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
        var ranked: [Ranked] = []
        for place in places {
            let matches = stays.filter { matches($0, place) }
            ranked.append(Ranked(
                name: place.name,
                latitude: place.latitude,
                longitude: place.longitude,
                radius: place.radius,
                visits: matches.count,
                lastVisit: matches.map(\.arrival).max()
            ))
        }
        ranked.sort { left, right in
            if left.visits != right.visits { return left.visits > right.visits }
            switch (left.lastVisit, right.lastVisit) {
            case let (l?, r?) where l != r: return l > r
            case (nil, _?): return false
            case (_?, nil): return true
            default: return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
        }
        return Array(ranked.prefix(max(0, limit)))
    }

    /// A visit belongs to a place if it carries the name, or sits inside the geofence
    /// without a name of its own. Name first, because a place renamed after its visits
    /// were recorded would otherwise appear unused and lose its slot.
    ///
    /// The second half is deliberately restricted to unidentified visits: geofences
    /// overlap, and counting every named visit inside one would let a place stationed
    /// near a busier neighbour inherit its history and take its slot.
    private static func matches(_ visit: Visit, _ place: SavedPlace) -> Bool {
        if visit.placeName.caseInsensitiveCompare(place.name) == .orderedSame { return true }
        guard visit.hasPlaceholderName else { return false }
        guard visit.latitude != 0 || visit.longitude != 0 else { return false }
        let distance = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
            .distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))
        return distance <= place.radius
    }
}
