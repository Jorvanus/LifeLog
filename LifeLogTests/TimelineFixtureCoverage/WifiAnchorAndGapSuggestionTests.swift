import Foundation
import Testing
@testable import LifeLog

/// Two independent ways the timeline fills in what Core Location alone
/// wouldn't know: a seen Wi-Fi network sharpening a guessed departure, and
/// Add Visit noticing an unlogged gap between two recorded stays.
@MainActor
struct WifiAnchorAndGapSuggestionTests {
    private let base = TimelineFixtureBuilders.referenceDate()

    /// The anchor exists to sharpen a departure Core Location guessed, and must never
    /// manufacture one. These cover both halves.
    @Test("A network seen leaving sharpens the departure it was guessing at")
    func wifiAnchorCorrectsADeparture() {
        let arrival = TimelineFixtureBuilders.referenceDate()
        let home = WiFiAnchor.hash(ssid: "Baxter", bssid: "aa:bb:cc:dd:ee:ff")

        // Joined at arrival, still joined half an hour later, gone by 8:40.
        var observation = WiFiAnchor.update(nil, sampled: home, at: arrival)
        observation = WiFiAnchor.update(observation, sampled: home, at: arrival.addingTimeInterval(1_800))
        observation = WiFiAnchor.update(observation, sampled: nil, at: arrival.addingTimeInterval(2_400))

        // Core Location would have timed this from the next arrival, 52 minutes later.
        let fallback = arrival.addingTimeInterval(3_120)
        #expect(WiFiAnchor.departure(for: observation, arrival: arrival, fallback: fallback)
                == arrival.addingTimeInterval(2_400))
    }

    @Test("A dropped network is not a departure")
    func wifiAnchorIgnoresADrop() {
        let arrival = TimelineFixtureBuilders.referenceDate()
        let home = WiFiAnchor.hash(ssid: "Baxter", bssid: nil)
        let fallback = arrival.addingTimeInterval(3_600)

        // Off the network briefly — a reboot, a band switch — then back on it.
        var observation = WiFiAnchor.update(nil, sampled: home, at: arrival)
        observation = WiFiAnchor.update(observation, sampled: nil, at: arrival.addingTimeInterval(600))
        observation = WiFiAnchor.update(observation, sampled: home, at: arrival.addingTimeInterval(900))

        #expect(observation?.firstAbsent == nil, "Being back on the network unwrites the absence")
        #expect(WiFiAnchor.departure(for: observation, arrival: arrival, fallback: fallback) == nil)

        // Never on a network at all: nothing to say, so Core Location's timing stands.
        let unanchored = WiFiAnchor.update(nil, sampled: nil, at: arrival)
        #expect(unanchored == nil)
        #expect(WiFiAnchor.departure(for: unanchored, arrival: arrival, fallback: fallback) == nil)
    }

    @Test("A departure is never moved outside the stay it belongs to")
    func wifiAnchorStaysWithinBounds() {
        let arrival = TimelineFixtureBuilders.referenceDate()
        let home = WiFiAnchor.hash(ssid: "Baxter", bssid: nil)
        let fallback = arrival.addingTimeInterval(3_600)

        // An absence recorded before the stay began belongs to the previous one.
        var stale = WiFiAnchor.update(nil, sampled: home, at: arrival.addingTimeInterval(-7_200))
        stale = WiFiAnchor.update(stale, sampled: nil, at: arrival.addingTimeInterval(-3_600))
        #expect(WiFiAnchor.departure(for: stale, arrival: arrival, fallback: fallback) == nil)

        // An absence after the next arrival would lengthen the stay, not shorten it.
        var late = WiFiAnchor.update(nil, sampled: home, at: arrival)
        late = WiFiAnchor.update(late, sampled: nil, at: fallback.addingTimeInterval(600))
        #expect(WiFiAnchor.departure(for: late, arrival: arrival, fallback: fallback) == nil)
    }

    @Test("A network is identified without being recorded")
    func wifiAnchorDoesNotStoreTheNetworkName() {
        let hash = WiFiAnchor.hash(ssid: "Baxter Home 5G", bssid: "aa:bb:cc:dd:ee:ff")
        #expect(!hash.localizedCaseInsensitiveContains("baxter"))
        #expect(hash.count == 16)
        // Same network, same answer; different network, different answer.
        #expect(hash == WiFiAnchor.hash(ssid: "baxter home 5g", bssid: "AA:BB:CC:DD:EE:FF"))
        #expect(hash != WiFiAnchor.hash(ssid: "Baxter Home 5G", bssid: "aa:bb:cc:dd:ee:00"))
    }

    @Test("Add Visit suggests the gaps in the timeline")
    func suggestsUnrecordedGaps() {
        // Cafe, a gap, Gym — nothing recorded, and neither end is Home or Work, so
        // CommuteDetection has no reason to claim this stretch: it should be offered.
        let visits = [
            TimelineFixtureBuilders.stayVisit("Cafe", fromMinutes: 0, toMinutes: 60, base: base),
            TimelineFixtureBuilders.stayVisit("Gym", fromMinutes: 400, toMinutes: 600, base: base)
        ]
        let range = DateInterval(start: base, end: base.addingTimeInterval(600 * 60))

        let suggestions = VisitSuggestion.make(from: visits, range: range)

        #expect(suggestions.count == 1)
        #expect(suggestions.first?.start == base.addingTimeInterval(60 * 60))
        #expect(suggestions.first?.end == base.addingTimeInterval(400 * 60))
        #expect(suggestions.first?.activity == "Travelling")

        // A real commute is already accounted for by CommuteDetection -- the same
        // computation Insights itself uses -- so it is not "missing" and is not
        // offered here either; suggesting it would fight the donut right next to it.
        func roledStay(_ name: String, from: Double, to: Double,
                       latitude: Double, longitude: Double) -> Visit {
            Visit(arrival: base.addingTimeInterval(from * 60), departure: base.addingTimeInterval(to * 60),
                  latitude: latitude, longitude: longitude, placeName: name,
                  inferredActivity: "Visiting", source: "automatic", recognitionConfidence: "learned")
        }
        let home = SavedPlace(name: "Home", latitude: -23.37, longitude: 150.51)
        home.homeWorkRole = .home
        let work = SavedPlace(name: "Work", latitude: -23.42, longitude: 150.55)
        work.homeWorkRole = .work
        let commuteVisits = [
            roledStay("Home", from: 0, to: 60, latitude: -23.37, longitude: 150.51),
            roledStay("Work", from: 85, to: 400, latitude: -23.42, longitude: 150.55)
        ]
        let commuteRange = DateInterval(start: base, end: base.addingTimeInterval(400 * 60))
        #expect(VisitSuggestion.make(from: commuteVisits, range: commuteRange, savedPlaces: [home, work]).isEmpty)

        // A gap of seconds is not a visit, and neither is a day-long one.
        let brief = [
            TimelineFixtureBuilders.stayVisit("Cafe", fromMinutes: 0, toMinutes: 60, base: base),
            TimelineFixtureBuilders.stayVisit("Gym", fromMinutes: 61, toMinutes: 120, base: base)
        ]
        #expect(VisitSuggestion.make(from: brief, range: DateInterval(start: base, end: base.addingTimeInterval(120 * 60))).isEmpty)
        let enormous = [
            TimelineFixtureBuilders.stayVisit("Cafe", fromMinutes: 0, toMinutes: 60, base: base),
            TimelineFixtureBuilders.stayVisit("Gym", fromMinutes: 900, toMinutes: 1_000, base: base)
        ]
        #expect(VisitSuggestion.make(from: enormous, range: DateInterval(start: base, end: base.addingTimeInterval(1_000 * 60))).isEmpty)
    }

    @Test("A gap partly covered by a device visit only offers the remaining unlogged part")
    func suggestionExcludesDeviceCoveredTime() {
        // The exact shape reported 2026-08-10: Work ends, a Walking burst covers the
        // first few minutes, and only what's left after it should be offered —
        // VisitSuggestion used to have no idea the walk existed at all.
        let walking = Visit(arrival: base.addingTimeInterval(60 * 60), departure: base.addingTimeInterval(69 * 60),
                            latitude: -23.37, longitude: 150.51, placeName: "Walking",
                            inferredActivity: "Walking", userActivity: "Walking", source: "health-walking",
                            recognitionConfidence: "device")
        let visits = [
            TimelineFixtureBuilders.stayVisit("Work", fromMinutes: 0, toMinutes: 60, base: base),
            walking,
            TimelineFixtureBuilders.stayVisit("Blood Bank", fromMinutes: 75, toMinutes: 130, base: base)
        ]
        let range = DateInterval(start: base, end: base.addingTimeInterval(130 * 60))

        let suggestions = VisitSuggestion.make(from: visits, range: range)

        #expect(suggestions.count == 1)
        #expect(suggestions.first?.start == base.addingTimeInterval(69 * 60))
        #expect(suggestions.first?.end == base.addingTimeInterval(75 * 60))
    }

    @Test("Returning to the same place suggests still being there")
    func suggestsStayingPut() {
        func home(_ from: Double, _ to: Double) -> Visit {
            Visit(arrival: base.addingTimeInterval(from * 60), departure: base.addingTimeInterval(to * 60),
                  latitude: -23.37, longitude: 150.51, placeName: "Home",
                  inferredActivity: "At home", userActivity: "At home",
                  source: "automatic", recognitionConfidence: "learned")
        }
        let range = DateInterval(start: base, end: base.addingTimeInterval(200 * 60))
        let suggestions = VisitSuggestion.make(from: [home(0, 60), home(90, 200)], range: range)

        #expect(suggestions.count == 1)
        #expect(suggestions.first?.place == "Home")
        #expect(suggestions.first?.activity == "At home")
    }
}
