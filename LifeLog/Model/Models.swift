import Foundation
import SwiftData
import CoreLocation

enum VisitResolutionState: String, Codable, Sendable {
    case provisional
    case resolved
    case superseded
    case ignored
}

/// Who is asking to change a visit's resolution state, so `setResolutionState`
/// can enforce the one rule that matters: automation moves a visit between
/// provisional, resolved and superseded on its own, but ignoring — and un-
/// ignoring — is exclusively a person's call, and a resolver pass must never
/// quietly undo either a person's ignore or a person's confirmed correction.
enum VisitResolutionActor: Sendable {
    case automation
    case user
}

/// Source values are stored as strings for compatibility with the existing timeline
/// store and backups. The enum is deliberately lossless: a newer build's source is
/// readable by an older build as `.unknown(raw)` rather than being recast as a known
/// source and changing resolver behaviour.
enum VisitSource: Codable, Sendable, Equatable, Hashable {
    case automatic, automaticSuperseded, manual, importedJournal, motion
    case healthSleep, healthWalking, healthWorkout
    case unknown(String)

    static let automaticRaw = "automatic"
    static let automaticSupersededRaw = "automatic-superseded"
    static let manualRaw = "manual"
    static let importedJournalRaw = "imported-journal"
    static let motionRaw = "motion"
    static let healthSleepRaw = "health-sleep"
    static let healthWalkingRaw = "health-walking"
    static let healthWorkoutRaw = "health-workout"

    init(rawValue: String) {
        switch rawValue {
        case Self.automaticRaw: self = .automatic
        case Self.automaticSupersededRaw: self = .automaticSuperseded
        case Self.manualRaw: self = .manual
        case Self.importedJournalRaw: self = .importedJournal
        case Self.motionRaw: self = .motion
        case Self.healthSleepRaw: self = .healthSleep
        case Self.healthWalkingRaw: self = .healthWalking
        case Self.healthWorkoutRaw: self = .healthWorkout
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .automatic: Self.automaticRaw
        case .automaticSuperseded: Self.automaticSupersededRaw
        case .manual: Self.manualRaw
        case .importedJournal: Self.importedJournalRaw
        case .motion: Self.motionRaw
        case .healthSleep: Self.healthSleepRaw
        case .healthWalking: Self.healthWalkingRaw
        case .healthWorkout: Self.healthWorkoutRaw
        case .unknown(let raw): raw
        }
    }

    init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }

    var isLocation: Bool { self == .automatic || self == .manual }
    var isHealth: Bool { self == .healthSleep || self == .healthWalking || self == .healthWorkout }
    var isDeviceActivity: Bool { self == .motion || isHealth }
}

enum VisitRecognitionConfidence: Codable, Sendable, Equatable, Hashable {
    case confirmed, learned, low, medium, high, device, imported
    case unknown(String)

    static let confirmedRaw = "confirmed"
    static let learnedRaw = "learned"
    static let lowRaw = "low"
    static let mediumRaw = "medium"
    static let highRaw = "high"
    static let deviceRaw = "device"
    static let importedRaw = "imported"

    init?(rawValue: String?) {
        guard let rawValue else { return nil }
        switch rawValue {
        case Self.confirmedRaw: self = .confirmed
        case Self.learnedRaw: self = .learned
        case Self.lowRaw: self = .low
        case Self.mediumRaw: self = .medium
        case Self.highRaw: self = .high
        case Self.deviceRaw: self = .device
        case Self.importedRaw: self = .imported
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .confirmed: Self.confirmedRaw
        case .learned: Self.learnedRaw
        case .low: Self.lowRaw
        case .medium: Self.mediumRaw
        case .high: Self.highRaw
        case .device: Self.deviceRaw
        case .imported: Self.importedRaw
        case .unknown(let raw): raw
        }
    }

    init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self))! }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
}

enum PlaceFieldProvenance: Codable, Sendable, Equatable, Hashable {
    case maps, savedPlace, manual, nameFallback
    /// Coordinates inferred by `ArchiveRepair` from the visit's place name
    /// matching a Saved Place, for imported history that never had any. Kept
    /// distinct from `.savedPlace` — which means the visit was actually recorded
    /// inside that place's geofence — so a reader can tell an inference from a
    /// fix, and so the backfill can be identified and reversed as a set.
    case nameBackfill
    case unknown(String)

    static let mapsRaw = "maps"
    static let savedPlaceRaw = "saved-place"
    static let manualRaw = "manual"
    static let nameFallbackRaw = "name-fallback"
    static let nameBackfillRaw = "name-backfill"

    init?(rawValue: String?) {
        guard let rawValue else { return nil }
        switch rawValue {
        case Self.mapsRaw: self = .maps
        case Self.savedPlaceRaw: self = .savedPlace
        case Self.manualRaw: self = .manual
        case Self.nameFallbackRaw: self = .nameFallback
        case Self.nameBackfillRaw: self = .nameBackfill
        default: self = .unknown(rawValue)
        }
    }
    var rawValue: String {
        switch self {
        case .maps: Self.mapsRaw
        case .savedPlace: Self.savedPlaceRaw
        case .manual: Self.manualRaw
        case .nameFallback: Self.nameFallbackRaw
        case .nameBackfill: Self.nameBackfillRaw
        case .unknown(let raw): raw
        }
    }
    /// True when the coordinates were inferred rather than observed. Anything
    /// deciding how far to trust a position — geofence learning, place scoring —
    /// should treat these as weaker evidence than a recorded fix.
    var isInferredCoordinate: Bool { self == .nameBackfill }
    init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self))! }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
}

/// The durable reason an automatic callback was kept, merged, or withdrawn. This is
/// deliberately separate from its current state: a superseded row still needs to say
/// whether it was a duplicate or movement evidence, and an accepted row needs to say
/// what made its place identity trustworthy.
enum LocationResolutionExplanation: String, Codable, Sendable {
    case mapsIdentifier = "matched-maps-identifier"
    case savedPlace = "matched-saved-place"
    case coordinateTime = "matched-coordinate-time"
    case duplicate = "superseded-duplicate"
    case movement = "ignored-movement"
    case lowConfidence = "ignored-low-confidence"

    var diagnosticLabel: String {
        switch self {
        case .mapsIdentifier: "Matched by Maps identifier"
        case .savedPlace: "Matched by Saved Place"
        case .coordinateTime: "Matched by coordinate and time"
        case .duplicate: "Superseded as duplicate"
        case .movement: "Ignored as movement"
        case .lowConfidence: "Ignored as low-confidence"
        }
    }
}

/// An explicit Home/Work designation on a `SavedPlace`. Commute detection and
/// travel labelling used to guess this from the place's own name — a false
/// positive for anywhere merely containing the word ("Homeward Bound Café"), and a
/// false negative for a workplace the owner didn't name "Work". A role is a fact
/// the owner stated, not a guess.
enum SavedPlaceRole: String, Codable, Sendable {
    case home
    case work

    /// The role of the Saved Place this visit belongs to, if any. Maps identifier
    /// wins whenever both sides have one — two visits can only share one by being
    /// the same physical place — falling back to geofence-radius membership for a
    /// visit with no identifier, the same precedence `SavedPlaceLearning`/
    /// `PlaceScoring` already use to resolve a visit's Saved Place elsewhere.
    static func of(_ visit: Visit, in savedPlaces: [SavedPlace]) -> SavedPlaceRole? {
        if let identifier = visit.mapsIdentifier,
           let match = savedPlaces.first(where: { $0.mapsIdentifier == identifier }) {
            return match.homeWorkRole
        }
        guard visit.latitude != 0 || visit.longitude != 0 else { return nil }
        let location = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
        return savedPlaces.first { place in
            guard place.homeWorkRole != nil else { return false }
            return location.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude)) <= place.radius
        }?.homeWorkRole
    }
}

@Model
final class SavedPlace {
    var name: String
    var latitude: Double
    var longitude: Double
    var radius: Double
    var defaultActivity: String
    /// Stable activity identity for new and migrated places. `defaultActivity` stays
    /// as the historical/display snapshot so old backups and imported labels never
    /// need an eager archive rewrite just to open the app.
    var activityDefinitionID: UUID?
    /// Apple Maps' own identifier for this place, when it came from a Maps result.
    ///
    /// Names are a poor identity: two businesses share one, and a place renamed by
    /// Apple — or by the person — stops matching its own history. The identifier
    /// survives both. Nil for places pinned by hand or learned from a coordinate.
    var mapsIdentifier: String?
    /// Raw storage for `homeWorkRole`. V8 migration backfills this for whatever the
    /// owner already had named "Home"/"Work"; new nil is the default for everything
    /// else, including a place that merely mentions the word in its name.
    var role: String?

    init(name: String, latitude: Double, longitude: Double, radius: Double = 100,
         defaultActivity: String = "", mapsIdentifier: String? = nil,
         activityDefinitionID: UUID? = nil) {
        self.name = TextSafety.clean(name, maximumLength: 100)
        self.latitude = latitude; self.longitude = longitude
        self.radius = min(max(radius, 25), 500)
        self.defaultActivity = TextSafety.clean(defaultActivity, maximumLength: 80)
        self.activityDefinitionID = activityDefinitionID
        self.mapsIdentifier = mapsIdentifier.map { TextSafety.clean($0, maximumLength: 120) }
    }

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    var homeWorkRole: SavedPlaceRole? {
        get { role.flatMap(SavedPlaceRole.init(rawValue:)) }
        set { role = newValue?.rawValue }
    }
}

/// The durable source of truth for an activity's presentation and Insights grouping.
///
/// The UserDefaults `ActivityDefinition` value is only decoded when adopting an
/// older backup or an existing pre-V12 installation. `ActivityDefinitionRecord`
/// owns the editable name, aliases and active state thereafter, so every current
/// surface agrees about what an activity means. Deleted definitions are retained so
/// historical activity IDs do not get silently reassigned to another, similarly
/// named activity.
@Model
final class ActivityDefinitionRecord {
    @Attribute(.unique) var stableID: UUID
    var name: String
    var category: String
    var symbol: String
    var colorHex: String?
    /// Prior names remain matchable for existing visit and saved-place snapshots.
    /// Keeping them with the record, rather than in a separate settings snapshot,
    /// makes rename behaviour survive backup, restore and a fresh app launch.
    var legacyNames: [String] = []
    /// Legacy column. It held a second, fixed grouping ("life area") that Insights
    /// counted some screens by while counting the rest by `category`; groups are now
    /// the only vocabulary, so nothing reads this. Kept, mirroring `category`, purely
    /// so the persisted schema is unchanged — dropping a column costs a migration and
    /// buys nothing here.
    var lifeArea: String
    var isActive: Bool
    var createdAt: Date
    var modifiedAt: Date

    init(stableID: UUID = UUID(), name: String, category: String = "Other",
         symbol: String = "circle.fill", colorHex: String? = nil,
         legacyNames: [String] = [],
         lifeArea: String? = nil, isActive: Bool = true,
         createdAt: Date = .now, modifiedAt: Date = .now) {
        let cleanCategory = TextSafety.clean(category, maximumLength: 40)
        let cleanName = TextSafety.clean(name, maximumLength: 80)
        self.stableID = stableID
        self.name = cleanName
        self.category = cleanCategory
        self.symbol = TextSafety.clean(symbol, maximumLength: 60)
        self.colorHex = colorHex
        self.lifeArea = lifeArea ?? cleanCategory
        self.isActive = isActive
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        var cleanedAliases: [String] = []
        for alias in legacyNames.map({ TextSafety.clean($0, maximumLength: 80) }) where
            !alias.isEmpty && alias.caseInsensitiveCompare(cleanName) != .orderedSame &&
            !cleanedAliases.contains(where: { $0.caseInsensitiveCompare(alias) == .orderedSame }) {
            cleanedAliases.append(alias)
        }
        self.legacyNames = cleanedAliases
    }
}

/// One fix along a movement record's path. A journey is a sequence of these rather
/// than a single coordinate: a walk passes through many places and belongs to none
/// of them, which is why a movement `Visit` has always stored latitude 0, longitude 0.
struct RoutePoint: Codable, Sendable, Equatable {
    let latitude: Double
    let longitude: Double
    let time: Date

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }

    init(latitude: Double, longitude: Double, time: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.time = time
    }

    init(_ location: CLLocation) {
        self.init(latitude: location.coordinate.latitude,
                  longitude: location.coordinate.longitude,
                  time: location.timestamp)
    }
}

@Model
final class Visit {
    var arrival: Date
    var departure: Date?
    var latitude: Double
    var longitude: Double
    var placeName: String
    var inferredActivity: String
    var userActivity: String?
    /// Stable identity of the chosen activity. The labels above deliberately remain
    /// snapshots: imports and old backups can continue to show exactly what they
    /// recorded until the staged resolver can safely match them.
    var activityDefinitionID: UUID?
    var note: String
    var source: String
    var recognitionConfidence: String?
    /// Apple Maps' durable place identifier when Maps named this visit. This is the
    /// primary identity for future matching; names remain only for old/manual data.
    var mapsIdentifier: String?
    /// Where the current place fields came from: `maps`, `saved-place`, `manual`,
    /// or `name-fallback`. It makes identifier-less history explainable.
    var placeFieldProvenance: String?
    /// Why the callback resolver accepted, combined, or withdrew this automatic
    /// stay. It stays with the visit so the explanation survives diagnostics trimming.
    var resolutionExplanation: String?
    var candidateData: Data?
    /// The originating HealthKit sample UUID(s) for a health-imported visit (a merged
    /// sleep session can span several samples). Lets a later anchored-query deletion
    /// be matched back to the local visit it produced. Nil for non-HealthKit sources.
    var healthKitSampleIDs: [UUID]?
    /// The path a movement record followed, as JSON — the same storage approach as
    /// place candidates, so a journey needs no relationship and no cascade rules.
    /// Nil for stays, and for movement whose source recorded no coordinates.
    var routeData: Data?
    /// A durable identity independent of `persistentModelID`, which SwiftData
    /// assigns from the store's own row identity and which a backup/restore
    /// round trip does not preserve — a restored store gets entirely new ones.
    /// This is what the resolution-state migration gave every visit so ignoring
    /// (and, eventually, export) survives a restore.
    ///
    /// The inline default is required, not decorative: both this and
    /// `resolutionStateRaw` below are non-optional, and a structural migration
    /// populates an existing row's new column from the property's own declared
    /// default, not by re-running `init`. Without one, migrating an existing
    /// store fails outright ("missing attribute values on mandatory destination
    /// attribute") before `didMigrate` ever gets a chance to backfill anything.
    /// The V8→V9 migration stage overwrites every row with its own unique value
    /// immediately afterward — see `LifeLogMigrationPlan` — so every visit in an
    /// existing store ends up with a real one, not this shared placeholder.
    var stableID: UUID = UUID()
    /// Raw storage for `resolutionState`. Written only through `setResolutionState`
    /// — see that method for the invariants automation must not violate. Same
    /// inline-default requirement as `stableID`.
    var resolutionStateRaw: String = VisitResolutionState.provisional.rawValue

    init(arrival: Date, departure: Date? = nil, latitude: Double, longitude: Double,
         placeName: String = Visit.identifyingPlaceName,
         inferredActivity: String = "Visiting", userActivity: String? = nil,
         activityDefinitionID: UUID? = nil,
         note: String = "", source: String = VisitSource.automaticRaw,
         recognitionConfidence: String? = nil, candidateData: Data? = nil,
         mapsIdentifier: String? = nil, placeFieldProvenance: String? = nil,
         resolutionExplanation: String? = nil,
         healthKitSampleIDs: [UUID]? = nil, routeData: Data? = nil,
         stableID: UUID = UUID(), resolutionState: VisitResolutionState? = nil) {
        self.arrival = arrival; self.departure = departure
        self.latitude = latitude; self.longitude = longitude
        self.placeName = TextSafety.clean(placeName, maximumLength: 120)
        self.inferredActivity = TextSafety.clean(inferredActivity, maximumLength: 80)
        self.userActivity = userActivity.map { TextSafety.clean($0, maximumLength: 80) }
        self.activityDefinitionID = activityDefinitionID
        self.note = TextSafety.clean(note, maximumLength: 2_000)
        self.source = TextSafety.clean(source, maximumLength: 40)
        self.recognitionConfidence = recognitionConfidence.map { TextSafety.clean($0, maximumLength: 20) }
        self.mapsIdentifier = mapsIdentifier.map { TextSafety.clean($0, maximumLength: 120) }
        self.placeFieldProvenance = placeFieldProvenance.map { TextSafety.clean($0, maximumLength: 30) }
        self.resolutionExplanation = resolutionExplanation.map { TextSafety.clean($0, maximumLength: 40) }
        self.candidateData = candidateData
        self.healthKitSampleIDs = healthKitSampleIDs
        self.routeData = routeData
        self.stableID = stableID
        // A fresh visit has no history to derive from, so its own fields decide:
        // the same rule `ActivityLocationPolicy.derivedAutomaticResolutionState`
        // applies to an existing one. An explicit override — restoring a backup
        // that already recorded a state, or a test fixture — is taken as given.
        self.resolutionStateRaw = (resolutionState ?? ActivityLocationPolicy.derivedAutomaticResolutionState(
            source: source, placeName: placeName, recognitionConfidence: recognitionConfidence
        )).rawValue
    }

    var activity: String {
        guard let userActivity, !userActivity.isEmpty else { return inferredActivity }
        return userActivity
    }
    var visitSource: VisitSource { VisitSource(rawValue: source) }
    var recognition: VisitRecognitionConfidence? { VisitRecognitionConfidence(rawValue: recognitionConfidence) }
    var placeProvenance: PlaceFieldProvenance? { PlaceFieldProvenance(rawValue: placeFieldProvenance) }
    var duration: TimeInterval { max(0, (departure ?? Date()).timeIntervalSince(arrival)) }

    /// Names LifeLog assigns before a place is known. They are not real labels, so
    /// a visit still carrying one has nothing recorded about where it happened.
    static let identifyingPlaceName = "Identifying…"
    static let unknownPlaceName = "Unknown place"
    static func isPlaceholderName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == identifyingPlaceName || trimmed == unknownPlaceName
    }
    var hasPlaceholderName: Bool { Visit.isPlaceholderName(placeName) }

    /// The Life Cycle CSV import's stand-in for "no place was recorded" — kept
    /// separate from `isPlaceholderName` rather than folded into it, because
    /// that name governs live location-resolution behaviour
    /// (`needsCategorisation`, geofence learning, journey stitching) that is
    /// scoped to `.automatic`/`.manual` visits throughout the app; widening it
    /// would touch two dozen call sites that were never meant to reason about
    /// the imported journal. `isUninformativePlaceName` is the broader "does
    /// this name mean anything" question a *display* feature should ask
    /// instead — used by the archive repair pass and by Insights' place-of-year
    /// grouping to decide whether a name is worth showing as a place at all.
    static let importedJournalPlaceName = "Imported journal"
    static func isUninformativePlaceName(_ name: String) -> Bool {
        isPlaceholderName(name)
            || name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(importedJournalPlaceName) == .orderedSame
    }

    /// A visit needs review when it was recorded automatically, LifeLog never
    /// resolved a place name for it, and the person has not said what they were
    /// doing. Place name is the signal here — LifeLog no longer models a place type.
    var needsCategorisation: Bool {
        visitSource == .automatic && hasPlaceholderName && userActivity?.isEmpty != false
    }

    /// A named guess LifeLog is not sure about. Apple Maps can return a nearby
    /// business with weak confidence — a workplace matched to a home address, say
    /// — and simply writing that name in would look like a settled fact. The place
    /// has a name, so it is not "uncategorised"; it still needs a person to agree.
    var needsConfirmation: Bool {
        guard visitSource == .automatic, !hasPlaceholderName,
              userActivity?.isEmpty != false else { return false }
        switch recognition {
        case .low, .medium: return true
        default: return false
        }
    }

    /// Everything worth putting in front of a person: a place LifeLog could not
    /// identify, or one it guessed at without much certainty.
    var needsReview: Bool { needsCategorisation || needsConfirmation }

    /// Presentation values keep a recorded-but-unknown place visibly logged without
    /// exposing placeholder names such as “Identifying…” in Timeline and Insights.
    var displayPlaceName: String {
        needsCategorisation ? "Uncategorised location" : placeName
    }
    var suspectedActivity: String {
        needsCategorisation ? inferredActivity : activity
    }
    /// Groups time by what the person did, so repeated visits bundle by activity
    /// while "Top places" bundles by place name.
    var activityCategory: String {
        ActivityCatalog.category(for: suspectedActivity)
    }
    var insightCategory: String {
        if needsCategorisation { return "Uncategorised" }
        return activityCategory
    }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var locationResolutionExplanation: LocationResolutionExplanation? {
        get { resolutionExplanation.flatMap(LocationResolutionExplanation.init(rawValue:)) }
        set { resolutionExplanation = newValue?.rawValue }
    }

    /// Falls back to `.provisional` only for a row `resolutionStateRaw` could not
    /// decode — never expected once every visit has been through the V9 migration
    /// (or `Visit.init`, for one created since), but a decode failure should read
    /// as "needs a look" rather than crash or silently claim `.resolved`.
    var resolutionState: VisitResolutionState {
        VisitResolutionState(rawValue: resolutionStateRaw) ?? .provisional
    }

    /// The one place `resolutionStateRaw` is ever written. Two invariants hold
    /// regardless of what's asked for:
    ///
    /// - Automation (the location resolver) can move a visit between provisional,
    ///   resolved and superseded, but can neither set nor clear `.ignored` — that
    ///   is exclusively a person's decision, made through `isIgnored`.
    /// - Automation cannot change the state of a visit the person has confirmed
    ///   (`recognitionConfidence == "confirmed"`). A later resolver pass finding
    ///   new evidence must not quietly re-open a correction someone already made.
    ///
    /// A person's own action (`actor: .user`) is exempt from both: unignoring a
    /// visit, or a confirmed correction settling what state it should be in, are
    /// exactly the cases these guards exist to still allow.
    @discardableResult
    func setResolutionState(_ newState: VisitResolutionState, actor: VisitResolutionActor) -> Bool {
        if actor == .automation {
            guard resolutionState != .ignored else { return false }
            guard newState != .ignored else { return false }
            guard recognitionConfidence?.lowercased() != "confirmed" else { return false }
        }
        guard resolutionStateRaw != newState.rawValue else { return false }
        resolutionStateRaw = newState.rawValue
        return true
    }

    /// A person's ignore/unignore, the only door `setResolutionState` leaves open
    /// to automation everywhere else. Unignoring does not simply clear back to
    /// `.provisional` — it hands the visit back to whatever the resolver would
    /// currently derive for it, so a place that was already resolved before it
    /// was ignored does not reappear looking unresolved.
    var isIgnored: Bool {
        get { resolutionState == .ignored }
        set {
            // A visit not yet in a store is not yet in the timeline either, so
            // ignoring it is premature — nothing to hide from anywhere yet, and
            // the object may still be discarded rather than inserted.
            guard modelContext != nil else { return }
            let target: VisitResolutionState = newValue
                ? .ignored
                : ActivityLocationPolicy.derivedAutomaticResolutionState(for: self)
            setResolutionState(target, actor: .user)
            if newValue, ["low", "medium"].contains(recognitionConfidence?.lowercased()) {
                locationResolutionExplanation = .lowConfidence
            }
        }
    }

    /// The raw blob is never rewritten merely because this build cannot read it.
    /// A caller can distinguish a genuinely empty route from legacy, corrupt, or
    /// future data through `routeDecoding`, while ordinary Timeline presentation
    /// still receives the safe empty fallback it expects.
    var routeDecoding: VisitPayloadDecodingResult<[RoutePoint]> {
        VisitPayloadDecoder.cachedRoute(from: routeData)
    }

    var route: [RoutePoint] {
        get { routeDecoding.value ?? [] }
        set {
            guard !newValue.isEmpty else { routeData = nil; return }
            do {
                routeData = try VisitPayloadDecoder.encodeRoute(newValue)
            } catch {
                recordPayloadWriteFailure("route", error: error)
            }
        }
    }
    var hasRoute: Bool { !(routeDecoding.value ?? []).isEmpty }

    /// Ground covered along the path, which is what a person means by how far they
    /// walked — not the distance between where they started and where they stopped.
    var routeDistance: CLLocationDistance {
        let points = route
        guard points.count > 1 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + pair.1.location.distance(from: pair.0.location)
        }
    }

    /// How far the journey got from a place. This is the question a stay cannot
    /// answer on its own: a loop around the block and pacing at home are both
    /// "walking with no departure recorded", and only the path separates them.
    func routeDistance(from coordinate: CLLocationCoordinate2D) -> CLLocationDistance? {
        let points = route
        guard !points.isEmpty else { return nil }
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return points.map { $0.location.distance(from: origin) }.max()
    }

    var candidateDecoding: VisitPayloadDecodingResult<VisitCandidatePayload> {
        VisitPayloadDecoder.cachedCandidates(from: candidateData)
    }

    var placeSuggestions: [PlaceSuggestion] {
        get { candidateDecoding.value?.suggestions ?? [] }
        set { writeCandidatePayload(suggestions: newValue) }
    }

    var placeScoreBreakdown: PlaceScoreBreakdown? {
        get { candidateDecoding.value?.score }
        set { writeCandidatePayload(score: newValue) }
    }

    /// The resolver's decision is separate from editor suggestions: Saved Place
    /// learning intentionally clears the latter, but Diagnostics must still be able
    /// to explain what Maps offered and why one result won.
    var locationResolutionCandidates: LocationResolutionCandidates? {
        get { candidateDecoding.value?.resolution }
        set { writeCandidatePayload(resolution: newValue) }
    }

    private func writeCandidatePayload(suggestions: [PlaceSuggestion]? = nil,
                                       score: PlaceScoreBreakdown?? = nil,
                                       resolution: LocationResolutionCandidates?? = nil) {
        let decoded = candidateDecoding
        guard decoded.status != .unsupported && decoded.status != .corrupt else {
            // Resolver follow-up must not make a future or damaged payload vanish.
            // A repair tool can explicitly replace it after exporting the raw bytes.
            queuePayloadDiagnostic("Preserved unreadable candidate payload for \(stableID); automatic update was skipped.")
            return
        }
        let payload = decoded.value
        let updated = VisitCandidatePayload(
            suggestions: suggestions ?? payload?.suggestions ?? [],
            score: score ?? payload?.score,
            resolution: resolution ?? payload?.resolution
        )
        do {
            candidateData = try VisitPayloadDecoder.encodeCandidates(updated)
        } catch {
            recordPayloadWriteFailure("candidate", error: error)
        }
    }

    /// A failed encoder must not replace a readable prior blob with `nil` or an
    /// empty payload. The durable diagnostic makes that otherwise invisible data
    /// loss risk inspectable without turning a property setter into a second save.
    private func recordPayloadWriteFailure(_ kind: String, error: Error) {
        queuePayloadDiagnostic("Could not encode \(kind) payload for \(stableID): \(error.localizedDescription)")
    }

    /// `Visit` accessors are not main-actor isolated. Queue the evidence here;
    /// the next successful main-actor store operation flushes it into Diagnostics.
    private func queuePayloadDiagnostic(_ message: String) {
        PendingDiagnostics.queue(.init(createdAt: .now, subsystem: "Visit payload",
                                       severity: DiagnosticSeverity.warningRaw, message: message))
    }

    /// Called by repair and restore flows, where there is a transaction available
    /// to record an actionable warning once. Read-only UI access intentionally
    /// does not save diagnostics or mutate a malformed historical visit.
    @MainActor
    func stageUnreadablePayloadDiagnostics(in context: ModelContext) {
        for (kind, status, reason) in [
            ("candidate", candidateDecoding.status, candidateDecoding.reason),
            ("route", routeDecoding.status, routeDecoding.reason)
        ] where status == .unsupported || status == .corrupt {
            Diagnostics.stage(context, subsystem: "Visit payload",
                              message: "Preserved \(kind) payload for \(stableID) is \(status.rawValue): \(reason ?? "no detail")")
        }
    }

    var confidenceLabel: String {
        switch recognitionConfidence?.lowercased() {
        case "confirmed": "Confirmed"
        case "learned": "Learned"
        case "high": "High"
        case "medium": "Medium"
        case "low": "Low"
        case "device": "Device"
        default: "Pending"
        }
    }

    /// Privacy-safe provenance for the displayed activity inference. This is
    /// derived from existing local fields so no new persisted schema is needed.
    var inferenceEvidence: [String] {
        var evidence: [String] = []
        if recognition == .learned { evidence.append("Saved place") }
        if !hasPlaceholderName { evidence.append("Place name: \(placeName)") }
        let hour = Calendar.current.component(.hour, from: arrival)
        if hour < 11 { evidence.append("Morning time") }
        else if hour < 17 { evidence.append("Afternoon time") }
        else { evidence.append("Evening time") }
        if visitSource == .motion || visitSource == .healthWalking || visitSource == .healthWorkout {
            evidence.append("Device movement")
        }
        if visitSource == .automatic && recognition != .learned {
            evidence.append("On-device inference")
        }
        return evidence
    }
}

/// The named options examined for an automatic stay. It deliberately records only
/// Maps/Saved Place labels and distances; raw callback coordinates remain confined
/// to the opt-in Location Journal.
struct LocationResolutionCandidates: Codable, Equatable, Sendable {
    let chosen: PlaceSuggestion?
    let rejected: [PlaceSuggestion]
}

/// Immutable audit entry for a user correction or a learned Saved Place update.
/// It stores labels and confidence only; precise coordinates remain in the visit.
@Model
final class VisitCorrection {
    var changedAt: Date
    var visitArrival: Date
    var latitude: Double
    var longitude: Double
    var previousPlaceName: String
    var newPlaceName: String
    var previousActivity: String
    var newActivity: String
    var previousConfidence: String
    var newConfidence: String
    var reason: String

    init(changedAt: Date = .now, visitArrival: Date, latitude: Double, longitude: Double,
         previousPlaceName: String, newPlaceName: String, previousActivity: String,
         newActivity: String, previousConfidence: String = "pending",
         newConfidence: String = "confirmed", reason: String = "Manual correction") {
        self.changedAt = changedAt
        self.visitArrival = visitArrival
        self.latitude = latitude
        self.longitude = longitude
        self.previousPlaceName = TextSafety.clean(previousPlaceName, maximumLength: 120)
        self.newPlaceName = TextSafety.clean(newPlaceName, maximumLength: 120)
        self.previousActivity = TextSafety.clean(previousActivity, maximumLength: 80)
        self.newActivity = TextSafety.clean(newActivity, maximumLength: 80)
        self.previousConfidence = TextSafety.clean(previousConfidence, maximumLength: 20)
        self.newConfidence = TextSafety.clean(newConfidence, maximumLength: 20)
        self.reason = TextSafety.clean(reason, maximumLength: 80)
    }
}
