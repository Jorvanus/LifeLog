import CoreLocation
import SwiftData

@MainActor
enum SavedPlaceLearning {
    /// A Maps result is evidence, not a user decision. Three separate automatic
    /// arrivals make a useful Saved Place without letting one mislocated callback
    /// turn into a monitored geofence.
    static let automaticCorroborationRequired = 3
    private static let automaticClusterRadius: CLLocationDistance = 250
    struct BackfillPreview {
        let matchingVisits: Int
        let ignoredVisits: Int
        var description: String { "\(matchingVisits) historical \(matchingVisits == 1 ? "visit" : "visits") will change" }
    }

    static func preview(_ place: SavedPlace, context: ModelContext) throws -> BackfillPreview {
        let placeCoordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
        let box = SpatialBounds.box(around: placeCoordinate, radius: place.radius)
        let minLat = box.minLatitude, maxLat = box.maxLatitude, minLon = box.minLongitude, maxLon = box.maxLongitude
        // Bounds the fetch to a box around this place instead of loading every Visit in the archive.
        let visits = try context.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { visit in
                (visit.latitude != 0 || visit.longitude != 0) &&
                visit.latitude >= minLat && visit.latitude <= maxLat &&
                visit.longitude >= minLon && visit.longitude <= maxLon
            }
        ))
        let location = CLLocation(latitude: place.latitude, longitude: place.longitude)
        let matching = visits.filter { visit in
            guard ActivityLocationPolicy.isLocationVisit(visit), isLocated(visit) else { return false }
            return location.distance(from: CLLocation(latitude: visit.latitude, longitude: visit.longitude)) <= place.radius
        }
        return BackfillPreview(matchingVisits: matching.count, ignoredVisits: matching.filter(\.isIgnored).count)
    }

    static func applyIgnored(_ ignored: Bool, to place: SavedPlace, context: ModelContext) throws -> Int {
        let placeCoordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
        let box = SpatialBounds.box(around: placeCoordinate, radius: place.radius)
        let minLat = box.minLatitude, maxLat = box.maxLatitude, minLon = box.minLongitude, maxLon = box.maxLongitude
        // Bounds the fetch to a box around this place instead of loading every Visit in the archive.
        let visits = try context.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { visit in
                (visit.latitude != 0 || visit.longitude != 0) &&
                visit.latitude >= minLat && visit.latitude <= maxLat &&
                visit.longitude >= minLon && visit.longitude <= maxLon
            }
        ))
        let location = CLLocation(latitude: place.latitude, longitude: place.longitude)
        let result = VisitMutationService.perform(context: context, kind: .savedPlaceChange) {
            var changed = 0
            for visit in visits where ActivityLocationPolicy.isLocationVisit(visit) && isLocated(visit) {
                guard location.distance(from: CLLocation(latitude: visit.latitude, longitude: visit.longitude)) <= place.radius,
                      visit.isIgnored != ignored else { continue }
                visit.isIgnored = ignored
                changed += 1
            }
            return .init(changedCount: changed)
        }
        guard result.committed else {
            throw SavedPlaceLearningError.mutationFailed(result.failureDescription)
        }
        return result.changedCount
    }
    enum Change: Equatable {
        case created
        case updated
    }

    struct Result {
        let place: SavedPlace
        let change: Change
    }

    /// Promotes an automatic Maps result only after independent visits corroborate
    /// it. Manual corrections and the explicit Save action keep using `upsert`,
    /// which deliberately has no such delay.
    ///
    /// A mall/centre candidate visible among the resolver's alternatives becomes
    /// the cluster anchor. Different entrances can therefore accumulate evidence
    /// for one Saved Place, while nearby standalone businesses still require their
    /// own matching Maps identity or name.
    static func learnAutomatically(from selected: PlaceSuggestion, visit: Visit,
                                   context: ModelContext) throws -> SavedPlace? {
        guard isLocated(visit), visit.visitSource == .automatic,
              // A fuzzed or genuinely poor fix is not proof this arrival happened
              // where it says it did; it must not become the anchor of a future
              // geofence.
              !LocationQuality.isApproximate(recordedAccuracyMeters: visit.placeScoreBreakdown?.accuracyMeters)
        else { return nil }
        let anchor = venueAnchor(for: selected, visit: visit) ?? selected
        let anchorLocation = CLLocation(latitude: anchor.latitude, longitude: anchor.longitude)
        let box = SpatialBounds.box(around: anchor.coordinate, radius: automaticClusterRadius)
        let minLat = box.minLatitude, maxLat = box.maxLatitude
        let minLon = box.minLongitude, maxLon = box.maxLongitude
        let nearbyVisits = try context.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { candidate in
                candidate.source == "automatic" &&
                candidate.latitude >= minLat && candidate.latitude <= maxLat &&
                candidate.longitude >= minLon && candidate.longitude <= maxLon
            }
        ))
        let corroborating = nearbyVisits.filter {
            corroborates(anchor, visit: $0, anchorLocation: anchorLocation)
        }
        guard corroborating.count >= automaticCorroborationRequired else { return nil }

        let nearbyPlaces = try context.fetch(FetchDescriptor<SavedPlace>(
            predicate: #Predicate { place in
                place.latitude >= minLat && place.latitude <= maxLat &&
                place.longitude >= minLon && place.longitude <= maxLon
            }
        ))
        if let existing = nearbyPlaces.first(where: { isSameAutomaticPlace($0, anchor: anchor) }) {
            // A venue cluster deliberately has one stable centre even when Maps
            // alternates entrances. Do not overwrite its canonical identity.
            if isLargeVenue(anchor) {
                existing.radius = max(existing.radius, automaticClusterRadius)
            }
            return existing
        }

        let place = SavedPlace(
            name: TextSafety.clean(anchor.name, maximumLength: 100),
            latitude: anchor.latitude,
            longitude: anchor.longitude,
            radius: isLargeVenue(anchor) ? automaticClusterRadius : 100,
            defaultActivity: anchor.suggestedActivity,
            mapsIdentifier: anchor.mapsIdentifier
        )
        context.insert(place)
        try apply(place, context: context)
        try context.save()
        InsightsInvalidation.invalidate(reason: "Saved Place corroborated", context: context)
        return place
    }

    /// Creates or updates the geofence used to recognize future visits.
    /// The prior name lets a renamed visit update its original SavedPlace rather than creating a duplicate.
    static func upsert(from visit: Visit, previousPlaceName: String?, context: ModelContext,
                       defaultRadius: CLLocationDistance = 100) throws -> Result? {
        guard isLocated(visit) else { return nil }

        let name = TextSafety.clean(visit.placeName, maximumLength: 100)
        let activity = TextSafety.clean(visit.activity, maximumLength: 80)
        guard isReusableName(name), !activity.isEmpty else { return nil }

        let radius = min(max(defaultRadius, 25), 500)
        let location = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
        // Bounds the fetch to a box around the visit instead of loading every
        // SavedPlace; 200 m matches the widest distance `nearby` considers below.
        let coordinate = CLLocationCoordinate2D(latitude: visit.latitude, longitude: visit.longitude)
        let box = SpatialBounds.box(around: coordinate, radius: 200)
        let minLat = box.minLatitude, maxLat = box.maxLatitude, minLon = box.minLongitude, maxLon = box.maxLongitude
        let places = try context.fetch(FetchDescriptor<SavedPlace>(
            predicate: #Predicate<SavedPlace> { place in
                place.latitude >= minLat && place.latitude <= maxLat &&
                place.longitude >= minLon && place.longitude <= maxLon
            }
        ))
        let nearby = places.compactMap { place -> (place: SavedPlace, distance: CLLocationDistance)? in
            let savedLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
            let distance = location.distance(from: savedLocation)
            return distance <= 200 ? (place, distance) : nil
        }

        let previousKey = previousPlaceName.map(NameKey.matching)
        let currentKey = NameKey.matching(name)
        let previousMatch = previousKey.flatMap { key in
            nearby.filter { NameKey.matching($0.place.name) == key }
                .min { $0.distance < $1.distance }?.place
        }
        // Maps identity wins whenever both sides have it. NameKey remains below for
        // migrated visits and hand-created places that cannot carry an identifier.
        let identifierMatch = visit.mapsIdentifier.flatMap { identifier in
            nearby.first { $0.place.mapsIdentifier == identifier }?.place
        }
        let existing = identifierMatch
            ?? previousMatch
            ?? nearby.filter { NameKey.matching($0.place.name) == currentKey }
                .min { $0.distance < $1.distance }?.place
            ?? nearby.filter { $0.distance <= 75 }
                .min { $0.distance < $1.distance }?.place

        let place: SavedPlace
        let change: Change
        if let existing {
            existing.name = name
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
                defaultActivity: activity,
                mapsIdentifier: visit.mapsIdentifier
            )
            context.insert(created)
            place = created
            change = .created
        }

        try apply(place, context: context)
        try context.save()
        InsightsInvalidation.invalidate(reason: "Saved Place correction", context: context)
        return Result(place: place, change: change)
    }

    /// Applies a saved geofence to matching location visits so edits are reflected
    /// immediately in both the timeline and historical insights.
    static func apply(_ place: SavedPlace, context: ModelContext) throws {
        place.name = TextSafety.clean(place.name, maximumLength: 100)
        place.defaultActivity = TextSafety.clean(place.defaultActivity, maximumLength: 80)
        place.radius = min(max(place.radius, 25), 500)

        let savedLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
        let activity = place.defaultActivity.isEmpty
            ? InferenceEngine.activity(placeName: place.name)
            : place.defaultActivity
        // Bounds the fetch to a box around this place instead of loading every
        // located Visit in the archive just to find the handful within radius.
        let placeCoordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
        let box = SpatialBounds.box(around: placeCoordinate, radius: place.radius)
        let minLat = box.minLatitude, maxLat = box.maxLatitude, minLon = box.minLongitude, maxLon = box.maxLongitude
        let visits = try context.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { visit in
                (visit.latitude != 0 || visit.longitude != 0) &&
                visit.latitude >= minLat && visit.latitude <= maxLat &&
                visit.longitude >= minLon && visit.longitude <= maxLon
            }
        ))
        for visit in visits where ActivityLocationPolicy.isLocationVisit(visit) && visit.resolutionState != .ignored && visit.resolutionState != .superseded && isLocated(visit) {
            let previous = VisitCorrectionSnapshot(
                placeName: visit.placeName,
                activity: visit.activity,
                confidence: visit.recognitionConfidence ?? "pending"
            )
            let visitLocation = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
            let identifierMatches = place.mapsIdentifier != nil && place.mapsIdentifier == visit.mapsIdentifier
            // Identifier match is authoritative; coordinate/name fallback keeps V5
            // history and manually pinned places working after the V6 migration.
            guard identifierMatches || savedLocation.distance(from: visitLocation) <= place.radius else { continue }
            // A Saved Place is helpful evidence for unresolved history, but it is
            // never allowed to silently revise a label the person explicitly chose.
            guard visit.recognitionConfidence?.lowercased() != "confirmed" else { continue }
            visit.placeName = place.name
            if identifierMatches { visit.placeFieldProvenance = "saved-place" }
            // A saved-place default is a future suggestion, not a permanent label —
            // the same location can be Breakfast one day and Lunch the next — so
            // only the inferred activity is refreshed here. Any manual
            // `userActivity` the person entered is left untouched and keeps taking
            // presentation priority (see Visit.activity).
            visit.inferredActivity = activity
            visit.recognitionConfidence = "learned"
            // Keep all Maps candidates for the resolution audit. These are useful
            // when a later correction shows the learned place was the wrong one;
            // the editor only exposes them while a visit still needs categorising.
            CorrectionHistory.record(visit: visit, from: previous, context: context,
                                     reason: "Saved Place learned")
        }
        _ = try ActivityLocationPolicy.runFullStoreAudit(context: context, reason: "Saved Place edit")
    }

    /// Adds Core Location detail to imported journal rows without changing their
    /// source. Imported entries often have no coordinates; a matching automatic
    /// visit can safely supply them when time and place/activity evidence agree.
    static func enrichImportedVisits(with coreVisit: Visit, context: ModelContext) throws {
        guard isLocated(coreVisit), coreVisit.visitSource == .automatic else { return }
        let imported = try context.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source == "imported-journal" }
        ))
        let coreName = NameKey.tokens(coreVisit.placeName)
        let coreActivity = NameKey.tokens(coreVisit.activity)
        for visit in imported where visit.latitude == 0 && visit.longitude == 0 {
            let timeDistance = abs(visit.arrival.timeIntervalSince(coreVisit.arrival))
            guard timeDistance <= 6 * 60 * 60 else { continue }
            let nameMatch = !coreName.isEmpty && !NameKey.tokens(visit.placeName).isDisjoint(with: coreName)
            let activityMatch = !coreActivity.isEmpty && !NameKey.tokens(visit.activity).isDisjoint(with: coreActivity)
            guard nameMatch || (activityMatch && timeDistance <= 90 * 60) else { continue }
            visit.latitude = coreVisit.latitude
            visit.longitude = coreVisit.longitude
            if !coreVisit.hasPlaceholderName {
                visit.placeName = coreVisit.placeName
            }
            visit.recognitionConfidence = "enriched"
        }
    }

    private static func isLocated(_ visit: Visit) -> Bool {
        let coordinate = CLLocationCoordinate2D(latitude: visit.latitude, longitude: visit.longitude)
        return CLLocationCoordinate2DIsValid(coordinate) && (visit.latitude != 0 || visit.longitude != 0)
    }

    private static func isReusableName(_ name: String) -> Bool {
        let key = NameKey.matching(name)
        return !key.isEmpty && key != "identifying…" && key != "unknown place"
    }

    private static func venueAnchor(for selected: PlaceSuggestion, visit: Visit) -> PlaceSuggestion? {
        let candidates = [selected] + (visit.locationResolutionCandidates?.rejected ?? [])
        return candidates.first(where: isLargeVenue)
    }

    private static func isLargeVenue(_ candidate: PlaceSuggestion) -> Bool {
        let name = NameKey.matching(candidate.name)
        let category = candidate.mapsCategory?.lowercased() ?? ""
        return category.contains("mall") || category.contains("shopping") ||
            name.contains("shopping centre") || name.contains("shopping center") ||
            name.contains(" mall") || name.hasSuffix(" plaza")
    }

    private static func corroborates(_ anchor: PlaceSuggestion, visit: Visit,
                                     anchorLocation: CLLocation) -> Bool {
        guard !visit.isIgnored, visit.resolutionState != .superseded,
              isLocated(visit),
              // An approximate fix can't corroborate anything -- it isn't
              // independent evidence that this arrival happened at this place.
              !LocationQuality.isApproximate(recordedAccuracyMeters: visit.placeScoreBreakdown?.accuracyMeters)
        else { return false }
        if let identifier = anchor.mapsIdentifier, visit.mapsIdentifier == identifier { return true }
        let candidates = [visit.locationResolutionCandidates?.chosen].compactMap { $0 }
            + (visit.locationResolutionCandidates?.rejected ?? [])
        if let identifier = anchor.mapsIdentifier,
           candidates.contains(where: { $0.mapsIdentifier == identifier }) { return true }
        if candidates.contains(where: { NameKey.same($0.name, anchor.name) }) { return true }
        let location = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
        if NameKey.same(visit.placeName, anchor.name),
           location.distance(from: anchorLocation) <= 100 { return true }
        // The wider radius is only for venue anchors, never generic adjacent shops.
        return isLargeVenue(anchor) && location.distance(from: anchorLocation) <= automaticClusterRadius &&
            candidates.contains(where: isLargeVenue)
    }

    private static func isSameAutomaticPlace(_ place: SavedPlace, anchor: PlaceSuggestion) -> Bool {
        if let identifier = anchor.mapsIdentifier, place.mapsIdentifier == identifier { return true }
        if NameKey.same(place.name, anchor.name) { return true }
        guard isLargeVenue(anchor) else { return false }
        let distance = CLLocation(latitude: place.latitude, longitude: place.longitude)
            .distance(from: CLLocation(latitude: anchor.latitude, longitude: anchor.longitude))
        return distance <= automaticClusterRadius && NameKey.matching(place.name).contains("shopping")
    }
}

private enum SavedPlaceLearningError: LocalizedError {
    case mutationFailed(String?)

    var errorDescription: String? {
        switch self {
        case .mutationFailed(let description): return description ?? "LifeLog could not update this Saved Place."
        }
    }
}
