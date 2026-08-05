import CoreLocation

/// A cheap bounding-box pre-filter for coordinate-based SwiftData fetches. Not a
/// true spatial index — for the place/visit counts LifeLog handles, a coarse
/// degree-based box pushed into the fetch predicate is enough to avoid loading
/// every row before an exact `CLLocation` distance check narrows candidates
/// further. The box is deliberately generous so no genuine candidate within
/// `radius` is ever excluded.
enum SpatialBounds {
    struct Box {
        let minLatitude: Double
        let maxLatitude: Double
        let minLongitude: Double
        let maxLongitude: Double
    }

    static func box(around coordinate: CLLocationCoordinate2D, radius: CLLocationDistance) -> Box {
        let metersPerDegreeLatitude = 111_320.0
        let metersPerDegreeLongitude = max(metersPerDegreeLatitude * cos(coordinate.latitude * .pi / 180), 1)
        let latDelta = radius / metersPerDegreeLatitude
        let lonDelta = radius / metersPerDegreeLongitude
        return Box(minLatitude: coordinate.latitude - latDelta, maxLatitude: coordinate.latitude + latDelta,
                   minLongitude: coordinate.longitude - lonDelta, maxLongitude: coordinate.longitude + lonDelta)
    }
}
