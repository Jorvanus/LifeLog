import CoreLocation
import SwiftData

@MainActor
enum SavedPlaceLearning {
    enum Change: Equatable {
        case created
        case updated
    }

    struct Result {
        let place: SavedPlace
        let change: Change
    }

    /// Creates or updates the geofence used to recognize future visits.
    /// The prior name lets a renamed visit update its original SavedPlace rather than creating a duplicate.
    static func upsert(from visit: Visit, previousPlaceName: String?, context: ModelContext,
                       defaultRadius: CLLocationDistance = 100) throws -> Result? {
        guard isLocated(visit) else { return nil }

        let name = TextSafety.clean(visit.placeName, maximumLength: 100)
        let category = TextSafety.clean(visit.placeCategory, maximumLength: 40)
        let activity = TextSafety.clean(visit.activity, maximumLength: 80)
        guard isReusableName(name), !activity.isEmpty else { return nil }

        let radius = min(max(defaultRadius, 25), 500)
        let location = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
        let places = try context.fetch(FetchDescriptor<SavedPlace>())
        let nearby = places.compactMap { place -> (place: SavedPlace, distance: CLLocationDistance)? in
            let savedLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
            let distance = location.distance(from: savedLocation)
            return distance <= 200 ? (place, distance) : nil
        }

        let previousKey = previousPlaceName.map(normalizedKey)
        let currentKey = normalizedKey(name)
        let previousMatch = previousKey.flatMap { key in
            nearby.filter { normalizedKey($0.place.name) == key }
                .min { $0.distance < $1.distance }?.place
        }
        let existing = previousMatch
            ?? nearby.filter { normalizedKey($0.place.name) == currentKey }
                .min { $0.distance < $1.distance }?.place
            ?? nearby.filter { $0.distance <= 75 }
                .min { $0.distance < $1.distance }?.place

        let place: SavedPlace
        let change: Change
        if let existing {
            existing.name = name
            existing.category = category
            existing.defaultActivity = activity
            existing.radius = min(max(max(existing.radius, radius), 25), 500)
            place = existing
            change = .updated
        } else {
            let created = SavedPlace(
                name: name,
                latitude: visit.latitude,
                longitude: visit.longitude,
                radius: radius,
                category: category,
                defaultActivity: activity
            )
            context.insert(created)
            place = created
            change = .created
        }

        try apply(place, context: context)
        try context.save()
        return Result(place: place, change: change)
    }

    /// Applies a saved geofence to matching location visits so edits are reflected
    /// immediately in both the timeline and historical insights.
    static func apply(_ place: SavedPlace, context: ModelContext) throws {
        place.name = TextSafety.clean(place.name, maximumLength: 100)
        place.category = TextSafety.clean(place.category, maximumLength: 40)
        place.defaultActivity = TextSafety.clean(place.defaultActivity, maximumLength: 80)
        place.radius = min(max(place.radius, 25), 500)

        let savedLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
        let activity = place.defaultActivity.isEmpty
            ? InferenceEngine.activity(placeName: place.name, category: place.category)
            : place.defaultActivity
        let visits = try context.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.latitude != 0 || $0.longitude != 0 }
        ))
        for visit in visits where ActivityLocationPolicy.isLocationVisit(visit) && !visit.isIgnored && isLocated(visit) {
            let previous = VisitCorrectionSnapshot(
                placeName: visit.placeName,
                category: visit.placeCategory,
                activity: visit.activity,
                confidence: visit.recognitionConfidence ?? "pending"
            )
            let visitLocation = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
            guard savedLocation.distance(from: visitLocation) <= place.radius else { continue }
            visit.placeName = place.name
            visit.placeCategory = place.category
            visit.inferredActivity = activity
            // A prior manual label takes precedence in presentation. Update it
            // too, otherwise historical check-ins can keep showing the old
            // activity even though the Saved Place has learned the new one.
            visit.userActivity = activity
            visit.recognitionConfidence = "learned"
            visit.placeSuggestions = []
            CorrectionHistory.record(visit: visit, from: previous, context: context,
                                     reason: "Saved Place learned")
        }
        try ActivityLocationPolicy.updateTravelDescriptions(context: context)
    }

    /// Adds Core Location detail to imported journal rows without changing their
    /// source. Imported entries often have no coordinates; a matching automatic
    /// visit can safely supply them when time and place/activity evidence agree.
    static func enrichImportedVisits(with coreVisit: Visit, context: ModelContext) throws {
        guard isLocated(coreVisit), coreVisit.source == "automatic" else { return }
        let imported = try context.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source == "imported-journal" }
        ))
        let coreName = normalizedTokens(coreVisit.placeName)
        let coreActivity = normalizedTokens(coreVisit.activity)
        for visit in imported where visit.latitude == 0 && visit.longitude == 0 {
            let timeDistance = abs(visit.arrival.timeIntervalSince(coreVisit.arrival))
            guard timeDistance <= 6 * 60 * 60 else { continue }
            let nameMatch = !coreName.isEmpty && !normalizedTokens(visit.placeName).isDisjoint(with: coreName)
            let activityMatch = !coreActivity.isEmpty && !normalizedTokens(visit.activity).isDisjoint(with: coreActivity)
            guard nameMatch || (activityMatch && timeDistance <= 90 * 60) else { continue }
            visit.latitude = coreVisit.latitude
            visit.longitude = coreVisit.longitude
            if coreVisit.placeName != "Identifying…" && coreVisit.placeName != "Unknown place" {
                visit.placeName = coreVisit.placeName
            }
            visit.placeCategory = coreVisit.placeCategory
            visit.recognitionConfidence = "enriched"
        }
    }

    private static func isLocated(_ visit: Visit) -> Bool {
        let coordinate = CLLocationCoordinate2D(latitude: visit.latitude, longitude: visit.longitude)
        return CLLocationCoordinate2DIsValid(coordinate) && (visit.latitude != 0 || visit.longitude != 0)
    }

    private static func isReusableName(_ name: String) -> Bool {
        let key = normalizedKey(name)
        return !key.isEmpty && key != "identifying…" && key != "unknown place"
    }

    private static func normalizedKey(_ value: String) -> String {
        TextSafety.clean(value, maximumLength: 100)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func normalizedTokens(_ value: String) -> Set<String> {
        Set(normalizedKey(value)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 })
    }
}
