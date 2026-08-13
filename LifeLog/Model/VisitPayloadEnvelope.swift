import Foundation
import CoreLocation

/// The stored JSON fields predate SwiftData relationships. Keeping their status
/// explicit lets callers present no data differently from data this build cannot
/// understand, without rewriting the original bytes behind the person's back.
enum VisitPayloadDecodeStatus: String, Codable, Sendable, Equatable {
    case absent
    case valid
    case legacy
    case unsupported
    case corrupt
}

struct VisitPayloadDecodingResult<Value: Sendable>: Sendable {
    let status: VisitPayloadDecodeStatus
    let value: Value?
    let reason: String?

    var isReadable: Bool { status == .valid || status == .legacy }

    static var absent: Self { .init(status: .absent, value: nil, reason: nil) }
    static func valid(_ value: Value) -> Self { .init(status: .valid, value: value, reason: nil) }
    static func legacy(_ value: Value) -> Self { .init(status: .legacy, value: value, reason: nil) }
    static func unsupported(_ reason: String) -> Self { .init(status: .unsupported, value: nil, reason: reason) }
    static func corrupt(_ reason: String) -> Self { .init(status: .corrupt, value: nil, reason: reason) }
}

extension VisitPayloadDecodingResult: Equatable where Value: Equatable {}

/// Versioned on-disk representation for information the place resolver used.
/// `payloadType` is deliberately a string so a future build can add a new type
/// without an older build accidentally decoding it as candidates.
struct VisitCandidatePayloadEnvelope: Codable, Sendable, Equatable {
    static let currentFormatVersion = 1
    static let payloadType = "visit-candidates"

    let formatVersion: Int
    let payloadType: String
    let payload: VisitCandidatePayload

    init(payload: VisitCandidatePayload) {
        self.formatVersion = Self.currentFormatVersion
        self.payloadType = Self.payloadType
        self.payload = payload
    }
}

/// Versioned on-disk representation for a movement route. Routes remain an
/// embedded blob because they can be large and should not create a relationship
/// graph for every workout or journey.
struct VisitRoutePayloadEnvelope: Codable, Sendable, Equatable {
    static let currentFormatVersion = 1
    static let payloadType = "visit-route"

    let formatVersion: Int
    let payloadType: String
    let payload: [RoutePoint]

    init(payload: [RoutePoint]) {
        self.formatVersion = Self.currentFormatVersion
        self.payloadType = Self.payloadType
        self.payload = payload
    }
}

/// The current pre-versioning candidate envelope. It is intentionally internal
/// rather than private so the migration decoder and focused payload tests can
/// preserve it as a recognised legacy format.
struct VisitCandidatePayload: Codable, Sendable, Equatable {
    let suggestions: [PlaceSuggestion]
    let score: PlaceScoreBreakdown?
    let resolution: LocationResolutionCandidates?
}

enum VisitPayloadDecoder {
    /// Bounds apply before JSON decoding, so a corrupt archive cannot turn an
    /// ordinary Timeline read into an allocation spike. The limits leave ample
    /// headroom above production Maps results and simplified workout routes.
    static let maximumCandidateBytes = 256 * 1_024
    static let maximumRouteBytes = 2 * 1_024 * 1_024
    static let maximumSuggestions = 16
    static let maximumResolutionCandidates = 32
    static let maximumRoutePoints = 10_000

    static func candidates(from data: Data?) -> VisitPayloadDecodingResult<VisitCandidatePayload> {
        guard let data else { return .absent }
        guard data.count <= maximumCandidateBytes else {
            return .corrupt("candidate payload is \(data.count) bytes; limit is \(maximumCandidateBytes)")
        }

        if let probe = probe(data), probe.isVersioned {
            guard probe.formatVersion == VisitCandidatePayloadEnvelope.currentFormatVersion else {
                return .unsupported("candidate format version \(probe.formatVersion.map(String.init) ?? "missing")")
            }
            guard probe.payloadType == VisitCandidatePayloadEnvelope.payloadType else {
                return .corrupt("candidate payload type \(probe.payloadType ?? "missing")")
            }
            do {
                let envelope = try JSONDecoder().decode(VisitCandidatePayloadEnvelope.self, from: data)
                try validate(envelope.payload)
                return .valid(envelope.payload)
            } catch {
                return .corrupt("candidate envelope: \(error.localizedDescription)")
            }
        }

        do {
            let legacy = try JSONDecoder().decode(VisitCandidatePayload.self, from: data)
            try validate(legacy)
            return .legacy(legacy)
        } catch {
            do {
                let suggestions = try JSONDecoder().decode([PlaceSuggestion].self, from: data)
                let legacy = VisitCandidatePayload(suggestions: suggestions, score: nil, resolution: nil)
                try validate(legacy)
                return .legacy(legacy)
            } catch {
                return .corrupt("candidate payload: \(error.localizedDescription)")
            }
        }
    }

    static func route(from data: Data?) -> VisitPayloadDecodingResult<[RoutePoint]> {
        guard let data else { return .absent }
        guard data.count <= maximumRouteBytes else {
            return .corrupt("route payload is \(data.count) bytes; limit is \(maximumRouteBytes)")
        }

        if let probe = probe(data), probe.isVersioned {
            guard probe.formatVersion == VisitRoutePayloadEnvelope.currentFormatVersion else {
                return .unsupported("route format version \(probe.formatVersion.map(String.init) ?? "missing")")
            }
            guard probe.payloadType == VisitRoutePayloadEnvelope.payloadType else {
                return .corrupt("route payload type \(probe.payloadType ?? "missing")")
            }
            do {
                let envelope = try JSONDecoder().decode(VisitRoutePayloadEnvelope.self, from: data)
                try validate(envelope.payload)
                return .valid(envelope.payload)
            } catch {
                return .corrupt("route envelope: \(error.localizedDescription)")
            }
        }

        do {
            let legacy = try JSONDecoder().decode([RoutePoint].self, from: data)
            try validate(legacy)
            return .legacy(legacy)
        } catch {
            return .corrupt("route payload: \(error.localizedDescription)")
        }
    }

    static func encodeCandidates(_ payload: VisitCandidatePayload) throws -> Data {
        try validate(payload)
        let data = try JSONEncoder().encode(VisitCandidatePayloadEnvelope(payload: payload))
        guard data.count <= maximumCandidateBytes else { throw VisitPayloadError.tooLarge }
        return data
    }

    static func encodeRoute(_ route: [RoutePoint]) throws -> Data {
        try validate(route)
        let data = try JSONEncoder().encode(VisitRoutePayloadEnvelope(payload: route))
        guard data.count <= maximumRouteBytes else { throw VisitPayloadError.tooLarge }
        return data
    }

    static func exceedsSafeStorageLimit(candidateData: Data?, routeData: Data?) -> Bool {
        (candidateData?.count ?? 0) > maximumCandidateBytes ||
            (routeData?.count ?? 0) > maximumRouteBytes
    }

    /// The model reaches these cached entry points, rather than the cache type
    /// itself, so the cache remains an implementation detail of payload decoding.
    static func cachedCandidates(from data: Data?) -> VisitPayloadDecodingResult<VisitCandidatePayload> {
        VisitPayloadDecodeCache.candidates(from: data)
    }

    static func cachedRoute(from data: Data?) -> VisitPayloadDecodingResult<[RoutePoint]> {
        VisitPayloadDecodeCache.route(from: data)
    }

    private struct HeaderProbe: Decodable {
        let formatVersion: Int?
        let payloadType: String?
        var isVersioned: Bool { formatVersion != nil || payloadType != nil }
    }

    private static func probe(_ data: Data) -> HeaderProbe? {
        try? JSONDecoder().decode(HeaderProbe.self, from: data)
    }

    private static func validate(_ payload: VisitCandidatePayload) throws {
        guard payload.suggestions.count <= maximumSuggestions else { throw VisitPayloadError.tooManyItems }
        guard let resolution = payload.resolution else {
            try validate(payload.suggestions)
            try validate(payload.score)
            return
        }
        guard resolution.rejected.count <= maximumResolutionCandidates else { throw VisitPayloadError.tooManyItems }
        try validate(payload.suggestions)
        try validate([resolution.chosen].compactMap { $0 } + resolution.rejected)
        try validate(payload.score)
    }

    private static func validate(_ suggestions: [PlaceSuggestion]) throws {
        for suggestion in suggestions {
            guard !suggestion.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  suggestion.latitude.isFinite, suggestion.longitude.isFinite,
                  CLLocationCoordinate2DIsValid(.init(latitude: suggestion.latitude, longitude: suggestion.longitude)),
                  suggestion.distance.isFinite, suggestion.distance >= 0, suggestion.distance <= 100_000 else {
                throw VisitPayloadError.invalidCandidate
            }
        }
    }

    private static func validate(_ score: PlaceScoreBreakdown?) throws {
        guard let score else { return }
        guard score.recordedAt.timeIntervalSinceReferenceDate.isFinite,
              (0...100).contains(score.total),
              score.candidateCount.map({ (0...maximumResolutionCandidates).contains($0) }) ?? true,
              score.observedDwellSeconds.map({ $0 >= 0 }) ?? true,
              score.accuracyMeters.map({ $0 >= 0 }) ?? true else {
            throw VisitPayloadError.invalidScore
        }
    }

    private static func validate(_ route: [RoutePoint]) throws {
        guard route.count <= maximumRoutePoints else { throw VisitPayloadError.tooManyItems }
        for point in route {
            guard point.latitude.isFinite, point.longitude.isFinite,
                  CLLocationCoordinate2DIsValid(.init(latitude: point.latitude, longitude: point.longitude)),
                  point.time.timeIntervalSinceReferenceDate.isFinite else {
                throw VisitPayloadError.invalidRoutePoint
            }
        }
    }

    private enum VisitPayloadError: LocalizedError {
        case tooLarge
        case tooManyItems
        case invalidCandidate
        case invalidScore
        case invalidRoutePoint

        var errorDescription: String? {
            switch self {
            case .tooLarge: "payload exceeds the safe size limit"
            case .tooManyItems: "payload contains too many items"
            case .invalidCandidate: "payload contains an invalid place candidate"
            case .invalidScore: "payload contains an invalid place score"
            case .invalidRoutePoint: "payload contains an invalid route point"
            }
        }
    }
}

/// Decoding a route inside several SwiftUI body passes is noticeably more costly
/// than decoding it once. The cache is content-keyed and immutable, so a changed
/// blob naturally receives a new result without any invalidation work.
private enum VisitPayloadDecodeCache {
    private final class CandidateBox: NSObject, @unchecked Sendable {
        let result: VisitPayloadDecodingResult<VisitCandidatePayload>
        init(_ result: VisitPayloadDecodingResult<VisitCandidatePayload>) { self.result = result }
    }
    private final class RouteBox: NSObject, @unchecked Sendable {
        let result: VisitPayloadDecodingResult<[RoutePoint]>
        init(_ result: VisitPayloadDecodingResult<[RoutePoint]>) { self.result = result }
    }

    // NSCache is internally synchronised; the immutable boxes never expose
    // SwiftData models, so this nonisolated cache is safe across reader actors.
    nonisolated(unsafe) private static var candidateCache: NSCache<NSData, CandidateBox> = {
        let cache = NSCache<NSData, CandidateBox>()
        cache.countLimit = 256
        return cache
    }()
    nonisolated(unsafe) private static var routeCache: NSCache<NSData, RouteBox> = {
        let cache = NSCache<NSData, RouteBox>()
        cache.countLimit = 96
        return cache
    }()

    static func candidates(from data: Data?) -> VisitPayloadDecodingResult<VisitCandidatePayload> {
        guard let data else { return .absent }
        let key = data as NSData
        if let cached = candidateCache.object(forKey: key) { return cached.result }
        let result = VisitPayloadDecoder.candidates(from: data)
        candidateCache.setObject(CandidateBox(result), forKey: key, cost: data.count)
        return result
    }

    static func route(from data: Data?) -> VisitPayloadDecodingResult<[RoutePoint]> {
        guard let data else { return .absent }
        let key = data as NSData
        if let cached = routeCache.object(forKey: key) { return cached.result }
        let result = VisitPayloadDecoder.route(from: data)
        routeCache.setObject(RouteBox(result), forKey: key, cost: data.count)
        return result
    }
}
