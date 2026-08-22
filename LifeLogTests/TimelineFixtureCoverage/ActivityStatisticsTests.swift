import Foundation
import Testing
@testable import LifeLog

/// The Activities tab's figures: totals, spread and top locations for one
/// activity, the bulk pass that computes every activity at once, and the
/// cheaper list-summary path — including the edge cases of a label the
/// catalogue has never heard of and an activity nothing uses.
@MainActor
struct ActivityStatisticsTests {
    /// The figures the activity page reports, in the shape the sketch asked for:
    /// occasions, total, average, shortest, longest, and where it happened.
    @Test("An activity's totals, spread and top locations")
    func summarisesOneActivity() {
        let calendar = TimelineFixtureBuilders.gregorianCalendar()
        let now = TimelineFixtureBuilders.referenceDate()
        func beers(daysAgo: Int, hours: Double, place: String) -> Visit {
            let start = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            return Visit(arrival: start, departure: start.addingTimeInterval(hours * 3_600),
                         latitude: -23.37, longitude: 150.51, placeName: place,
                         inferredActivity: "Beers", userActivity: "Beers", source: "manual")
        }
        let visits = [
            beers(daysAgo: 1, hours: 2, place: "O'Dowds"),
            beers(daysAgo: 2, hours: 6, place: "O'Dowds"),
            beers(daysAgo: 3, hours: 1, place: "Paddy's"),
            beers(daysAgo: 20, hours: 3, place: "O'Leary's"),
            // A different activity at the same place must not be counted.
            Visit(arrival: now, departure: now.addingTimeInterval(3_600),
                  latitude: -23.37, longitude: 150.51, placeName: "O'Dowds",
                  inferredActivity: "Coffee", userActivity: "Coffee", source: "manual")
        ]

        let stats = ActivityStatistics.make(activity: "Beers", visits: visits,
                                            days: 7, now: now, calendar: calendar)

        #expect(stats.occasions == 4)
        #expect(stats.totalTime == 12 * 3_600)
        #expect(stats.averageTime == 3 * 3_600)
        #expect(stats.shortestTime == 3_600)
        #expect(stats.longestTime == 6 * 3_600)
        // Ordered by how often, so the usual haunt leads.
        #expect(stats.places.map(\.name) == ["O'Dowds", "O'Leary's", "Paddy's"])
        #expect(stats.places.first?.occasions == 2)
        // Seven columns ending today, whether or not anything happened in them.
        #expect(stats.recentDays.count == 7)
        #expect(stats.recentDays.map(\.occasions).reduce(0, +) == 3, "The 20-day-old night is outside the week")
        // This week against the one before it: nothing in the previous week, so there
        // is no change to report rather than a fabricated one.
        #expect(stats.currentPeriodTime == 9 * 3_600)
        #expect(stats.previousPeriodTime == 0)
        #expect(stats.changeFraction == nil)
        #expect(stats.firstUsed == visits[3].arrival)
        #expect(stats.lastUsed == visits[0].arrival)
    }

    /// The Activities tab was slow to open because it walked the whole timeline once
    /// per activity. At archive size that is the difference between one pass and
    /// twenty, so this fixture is deliberately the size of a real import.
    @Test("Every activity's figures come from one pass over a full archive")
    func summarisesEveryActivityInOnePass() {
        let calendar = TimelineFixtureBuilders.gregorianCalendar()
        let now = TimelineFixtureBuilders.referenceDate()
        let labels = ["Beers", "Coffee", "Working", "At home", "Shopping"]
        let visits = (0..<32_000).map { index -> Visit in
            let start = now.addingTimeInterval(-Double(index) * 900)
            return Visit(arrival: start, departure: start.addingTimeInterval(600),
                         latitude: -23.37, longitude: 150.51,
                         placeName: "Place \(index % 40)",
                         inferredActivity: labels[index % labels.count],
                         source: "imported-journal")
        }

        let names = labels + ["Bowling"]
        let all = ActivityStatistics.makeAll(named: names, visits: visits, now: now, calendar: calendar)

        #expect(all.count == names.count)
        // Identical to computing one at a time, which is what this replaced.
        for name in labels {
            let bulk = all.first { $0.activity == name }
            let single = ActivityStatistics.make(activity: name, visits: visits,
                                                 now: now, calendar: calendar)
            #expect(bulk?.occasions == single.occasions)
            #expect(bulk?.totalTime == single.totalTime)
            #expect(bulk?.places.first?.occasions == single.places.first?.occasions)
        }
        // An activity in the catalogue that the archive never uses is still listed,
        // and still carries its own name rather than an empty one.
        let unused = all.first { $0.activity == "Bowling" }
        #expect(unused?.isEmpty == true)
        #expect(unused?.activity == "Bowling")
    }

    /// The list's summaries must agree with the full figures, and cost less: on a real
    /// archive the full version measured 380 ms on device, over the project's 250 ms
    /// main-thread budget.
    @Test("List summaries match the full figures and cost less to produce")
    func summariesAgreeWithFullStatistics() {
        let calendar = TimelineFixtureBuilders.gregorianCalendar()
        let now = TimelineFixtureBuilders.referenceDate()
        let labels = ["Beers", "Coffee", "Working", "At home", "Shopping"]
        let visits = (0..<25_000).map { index -> Visit in
            let start = now.addingTimeInterval(-Double(index) * 900)
            return Visit(arrival: start, departure: start.addingTimeInterval(600),
                         latitude: -23.37, longitude: 150.51,
                         placeName: "Place \(index % 40)",
                         inferredActivity: labels[index % labels.count],
                         source: "imported-journal")
        }

        let summaryStarted = Date.now
        let summaries = ActivityStatistics.summaries(named: labels, visits: visits,
                                                     now: now, calendar: calendar)
        let summaryElapsed = Date.now.timeIntervalSince(summaryStarted)

        let fullStarted = Date.now
        let full = ActivityStatistics.makeAll(named: labels, visits: visits,
                                              now: now, calendar: calendar)
        let fullElapsed = Date.now.timeIntervalSince(fullStarted)

        for label in labels {
            let summary = summaries.first { $0.activity == label }
            let complete = full.first { $0.activity == label }
            #expect(summary?.occasions == complete?.occasions)
            #expect(summary?.totalTime == complete?.totalTime)
            #expect(summary?.recentDays.map(\.occasions) == complete?.recentDays.map(\.occasions))
            #expect(summary?.recentDays.map(\.hours) == complete?.recentDays.map(\.hours))
        }
        #expect(summaryElapsed < fullElapsed,
                "summaries \(Int(summaryElapsed * 1000))ms vs full \(Int(fullElapsed * 1000))ms")
    }

    @Test("A label the catalogue has never heard of is still counted")
    func includesLabelsMissingFromTheCatalogue() {
        let now = TimelineFixtureBuilders.referenceDate()
        let visit = Visit(arrival: now, departure: now.addingTimeInterval(3_600),
                          latitude: -23.37, longitude: 150.51, placeName: "O'Dowds",
                          inferredActivity: "Trivia night", source: "manual")

        let all = ActivityStatistics.makeAll(named: ["Beers"], visits: [visit], now: now)

        #expect(all.count == 2)
        #expect(all.contains { $0.activity == "Trivia night" && $0.occasions == 1 })
    }

    @Test("An activity nothing uses reports nothing rather than zeroes")
    func summarisesAnUnusedActivity() {
        let stats = ActivityStatistics.make(activity: "Bowling", visits: [])
        #expect(stats.isEmpty)
        #expect(stats.occasions == 0)
        #expect(stats.firstUsed == nil)
        #expect(stats.changeFraction == nil)
    }

    /// `ActivityDetailView` used to read this uncached, and reads it from its chart,
    /// comparison, places, totals, usage, merge-dialog, and delete-footer sections --
    /// as many as eight full recomputations of the same value on one render. This
    /// fixture is the size of a real candidate fetch: `VisitHistoryQuery.activity`'s
    /// own 5,000-row limit.
    @Test("The activity-detail cache computes once per render regardless of read count")
    func cacheComputesOncePerRenderRegardlessOfReadCount() {
        let calendar = TimelineFixtureBuilders.gregorianCalendar()
        let now = TimelineFixtureBuilders.referenceDate()
        let visits = (0..<5_000).map { index -> Visit in
            let start = now.addingTimeInterval(-Double(index) * 900)
            return Visit(arrival: start, departure: start.addingTimeInterval(600),
                         latitude: -23.37, longitude: 150.51,
                         placeName: "Place \(index % 40)",
                         inferredActivity: index.isMultiple(of: 2) ? "Beers" : "Coffee",
                         source: "imported-journal")
        }
        let cache = ActivityStatisticsCache()
        let key = "beers|\(visits.count)|0|7|\(now.timeIntervalSinceReferenceDate)"

        var results: [ActivityStatistics] = []
        for _ in 0..<8 {
            results.append(cache.statistics(key: key) {
                ActivityStatistics.make(activity: "Beers", visits: visits, days: 7, now: now, calendar: calendar)
            })
        }

        #expect(cache.calculationCount == 1)
        #expect(results.allSatisfy { $0.occasions == results[0].occasions })
    }

    @Test("The activity-detail cache recomputes only when the key actually changes")
    func cacheRecomputesOnlyWhenKeyChanges() {
        let now = TimelineFixtureBuilders.referenceDate()
        let visits = [Visit(arrival: now, departure: now.addingTimeInterval(3_600),
                            latitude: -23.37, longitude: 150.51, placeName: "O'Dowds",
                            inferredActivity: "Beers", source: "manual")]
        let cache = ActivityStatisticsCache()
        let build = { ActivityStatistics.make(activity: "Beers", visits: visits, now: now) }

        _ = cache.statistics(key: "beers|1|0|7|1", build: build)
        #expect(cache.calculationCount == 1)

        _ = cache.statistics(key: "beers|1|0|7|1", build: build)
        #expect(cache.calculationCount == 1, "An unchanged key must not recompute")

        // Candidate generation is the one dimension that can change with the visits
        // array itself unchanged -- a mutation elsewhere in the archive bumping
        // `InsightsAggregationActor`'s shared counter.
        _ = cache.statistics(key: "beers|1|1|7|1", build: build)
        #expect(cache.calculationCount == 2, "A changed candidate generation must recompute")

        _ = cache.statistics(key: "beers|1|1|30|1", build: build)
        #expect(cache.calculationCount == 3, "A changed window must recompute")

        _ = cache.statistics(key: "beers|1|1|30|2", build: build)
        #expect(cache.calculationCount == 4, "A changed now must recompute")
    }
}
