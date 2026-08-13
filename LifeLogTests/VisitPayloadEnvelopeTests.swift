import Foundation
import Testing
@testable import LifeLog

struct VisitPayloadEnvelopeTests {
    private let date = Date(timeIntervalSinceReferenceDate: 42_000)

    @Test("Versioned candidate payload is readable")
    func versionedCandidatePayloadIsReadable() throws {
        let payload = VisitCandidatePayload(suggestions: [suggestion()], score: nil, resolution: nil)
        let data = try VisitPayloadDecoder.encodeCandidates(payload)

        let decoded = VisitPayloadDecoder.candidates(from: data)
        #expect(decoded.status == .valid)
        #expect(decoded.value == payload)
    }

    @Test("Bare candidate arrays and the former envelope remain readable")
    func candidateLegacyFormatsRemainReadable() throws {
        let bare = try JSONEncoder().encode([suggestion()])
        let formerEnvelope = try JSONEncoder().encode(
            VisitCandidatePayload(suggestions: [suggestion()], score: nil, resolution: nil)
        )

        #expect(VisitPayloadDecoder.candidates(from: bare).status == .legacy)
        #expect(VisitPayloadDecoder.candidates(from: formerEnvelope).status == .legacy)
    }

    @Test("Unknown candidate formats remain unsupported rather than empty")
    func unknownCandidateFormatIsUnsupported() {
        let data = Data("""
        {"formatVersion":99,"payloadType":"visit-candidates","payload":{}}
        """.utf8)

        let decoded = VisitPayloadDecoder.candidates(from: data)
        #expect(decoded.status == .unsupported)
        #expect(decoded.value == nil)
    }

    @Test("Corrupt, truncated, oversized, and invalid candidate payloads are explicit")
    func malformedCandidatePayloadsAreExplicit() {
        let truncated = VisitPayloadDecoder.candidates(from: Data("{\"formatVersion\":1".utf8))
        let oversized = VisitPayloadDecoder.candidates(
            from: Data(repeating: 0x20, count: VisitPayloadDecoder.maximumCandidateBytes + 1)
        )
        let invalidCoordinate = VisitPayloadDecoder.candidates(from: Data("""
        {"formatVersion":1,"payloadType":"visit-candidates","payload":{"suggestions":[{"name":"Bad","latitude":91,"longitude":0,"suggestedActivity":"Visiting","distance":1}]}}
        """.utf8))
        let unusualFloat = VisitPayloadDecoder.candidates(from: Data("""
        {"formatVersion":1,"payloadType":"visit-candidates","payload":{"suggestions":[{"name":"Bad","latitude":1e309,"longitude":0,"suggestedActivity":"Visiting","distance":1}]}}
        """.utf8))

        #expect(truncated.status == .corrupt)
        #expect(oversized.status == .corrupt)
        #expect(invalidCoordinate.status == .corrupt)
        #expect(unusualFloat.status == .corrupt)
    }

    @Test("Versioned and legacy route payloads are readable")
    func routeFormatsRemainReadable() throws {
        let route = [RoutePoint(latitude: -27.47, longitude: 153.03, time: date)]
        let versioned = try VisitPayloadDecoder.encodeRoute(route)
        let legacy = try JSONEncoder().encode(route)

        #expect(VisitPayloadDecoder.route(from: versioned).status == .valid)
        #expect(VisitPayloadDecoder.route(from: versioned).value == route)
        #expect(VisitPayloadDecoder.route(from: legacy).status == .legacy)
        #expect(VisitPayloadDecoder.route(from: legacy).value == route)
    }

    @Test("Future and malformed route payloads do not masquerade as no route")
    func invalidRoutePayloadsAreExplicit() {
        let future = VisitPayloadDecoder.route(from: Data("""
        {"formatVersion":2,"payloadType":"visit-route","payload":[]}
        """.utf8))
        let invalidCoordinate = VisitPayloadDecoder.route(from: Data("""
        {"formatVersion":1,"payloadType":"visit-route","payload":[{"latitude":-91,"longitude":0,"time":0}]}
        """.utf8))
        let oversized = VisitPayloadDecoder.route(
            from: Data(repeating: 0, count: VisitPayloadDecoder.maximumRouteBytes + 1)
        )

        #expect(future.status == .unsupported)
        #expect(invalidCoordinate.status == .corrupt)
        #expect(oversized.status == .corrupt)
    }

    @Test("An unreadable candidate payload is not overwritten by a routine update")
    func unreadableCandidatePayloadIsPreserved() {
        let raw = Data("{\"formatVersion\": 99, \"payloadType\": \"visit-candidates\"}".utf8)
        let visit = Visit(arrival: date, latitude: 0, longitude: 0, candidateData: raw)

        visit.placeSuggestions = [suggestion()]

        #expect(visit.candidateData == raw)
        #expect(visit.candidateDecoding.status == .unsupported)
    }

    @Test("Backup validation preserves readable limits while retaining corrupt raw evidence")
    func backupValidationPreservesCorruptRawPayloads() throws {
        let corruptRoute = Data("{\"not\": \"a route\"}".utf8)
        let backup = LifeLogBackup(version: LifeLogBackup.currentVersion, createdAt: date,
            visits: [.init(arrival: date, departure: nil, latitude: 0, longitude: 0,
                           placeName: "Unknown", inferredActivity: "Visiting", userActivity: nil,
                           note: "", source: "automatic", activityDefinitionID: nil,
                           recognitionConfidence: nil, candidateData: nil, mapsIdentifier: nil,
                           placeFieldProvenance: nil, resolutionExplanation: nil, stableID: UUID(),
                           resolutionState: nil, healthKitSampleIDs: nil, routeData: corruptRoute)],
            savedPlaces: [], corrections: [], diagnostics: [], locationEvents: [],
            ignoredVisitKeys: [], activityDefinitions: [], preferences: [:])

        try backup.validate()
        #expect(VisitPayloadDecoder.route(from: corruptRoute).status == .corrupt)
    }

    @Test("Excess item counts are rejected even while comfortably under the byte-size limit")
    func excessiveItemCountsAreExplicitRegardlessOfByteSize() throws {
        let manySuggestions = (0..<(VisitPayloadDecoder.maximumSuggestions + 1)).map {
            PlaceSuggestion(name: "Place \($0)", latitude: -27.47, longitude: 153.03,
                            suggestedActivity: "Visiting", distance: 5)
        }
        let candidateData = try JSONEncoder().encode(
            VisitCandidatePayloadEnvelope(payload: .init(suggestions: manySuggestions, score: nil, resolution: nil))
        )
        #expect(candidateData.count < VisitPayloadDecoder.maximumCandidateBytes)
        #expect(VisitPayloadDecoder.candidates(from: candidateData).status == .corrupt)

        let manyRejected = (0..<(VisitPayloadDecoder.maximumResolutionCandidates + 1)).map {
            PlaceSuggestion(name: "Rejected \($0)", latitude: -27.47, longitude: 153.03,
                            suggestedActivity: "Visiting", distance: 5)
        }
        let resolutionData = try JSONEncoder().encode(
            VisitCandidatePayloadEnvelope(payload: .init(
                suggestions: [suggestion()], score: nil,
                resolution: .init(chosen: nil, rejected: manyRejected)))
        )
        #expect(resolutionData.count < VisitPayloadDecoder.maximumCandidateBytes)
        #expect(VisitPayloadDecoder.candidates(from: resolutionData).status == .corrupt)

        let manyPoints = (0..<(VisitPayloadDecoder.maximumRoutePoints + 1)).map {
            RoutePoint(latitude: -27.47, longitude: 153.03, time: date.addingTimeInterval(TimeInterval($0)))
        }
        let routeData = try JSONEncoder().encode(VisitRoutePayloadEnvelope(payload: manyPoints))
        #expect(routeData.count < VisitPayloadDecoder.maximumRouteBytes)
        #expect(VisitPayloadDecoder.route(from: routeData).status == .corrupt)
    }

    private func suggestion() -> PlaceSuggestion {
        PlaceSuggestion(name: "Corner Cafe", latitude: -27.47, longitude: 153.03,
                        suggestedActivity: "Coffee", distance: 12, mapsIdentifier: "cafe")
    }
}
