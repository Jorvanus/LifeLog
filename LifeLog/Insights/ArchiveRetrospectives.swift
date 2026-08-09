import Foundation

/// The three archive-scale retrospectives day-by-day comparisons cannot reach: a
/// place seen for the first time, an unusually long gap since a familiar place was
/// last visited, and one restrained comparison against the same period a year ago.
///
/// Deliberately not "On this day" (Timeline, which reports places visited on this
/// calendar day in past years) and not the per-activity period comparison
/// (Settings → an activity's own detail screen, which already does period-over-
/// period). Each function here asks a small, targeted question of the archive
/// rather than scanning or summarising all of it.
enum ArchiveRetrospectives {
    /// How many prior visits a place needs before a gap in its pattern means
    /// anything. A place seen twice has exactly one gap, and calling it "the
    /// longest yet" would be true of every second visit ever made — an arithmetic
    /// identity, not an observation.
    static let minimumOccasionsForAGap = 4

    /// How long a gap has to be, in days, before it is worth naming regardless of
    /// the place's own pattern. A week between grocery runs is not a story.
    static let minimumNotableGapDays = 30

    /// A place with no earlier record at all, first met inside the period being
    /// looked at. `history` is every visit to matching places, unscoped by date —
    /// the question is whether anything in it predates the window.
    static func firstVisitToPlace(_ place: PlaceTotal, history: [Visit],
                                  windowStart: Date, window: InsightWindow) -> DayHighlight? {
        let matching = history.filter { NameKey.matching($0.placeName) == NameKey.matching(place.name) }
        guard let earliest = matching.map(\.arrival).min(), earliest >= windowStart else { return nil }
        return DayHighlight(
            id: "first-visit-\(place.name)", symbol: "sparkles",
            headline: "First time at \(place.name)",
            detail: "Recorded for the first time this \(window.title.lowercased()).",
            isCelebration: true
        )
    }

    /// The longest a familiar place has ever gone unvisited, when the gap that set
    /// the record ends inside the period being looked at. A record, not merely a
    /// pause: a place seen every week for a year and then not for six is a real
    /// change in a routine, which is what this is for. Mutually exclusive with
    /// `firstVisitToPlace` by construction — a place needing `minimumOccasionsForAGap`
    /// prior visits cannot also have none.
    static func longestAbsenceFromPlace(_ place: PlaceTotal, history: [Visit],
                                        windowStart: Date) -> DayHighlight? {
        let matching = history
            .filter { NameKey.matching($0.placeName) == NameKey.matching(place.name) }
            .sorted { $0.arrival < $1.arrival }
        guard matching.count >= minimumOccasionsForAGap else { return nil }
        let gaps = zip(matching, matching.dropFirst()).map { previous, current in
            (days: current.arrival.timeIntervalSince(previous.departure ?? previous.arrival) / 86_400,
             endsAt: current.arrival)
        }
        guard let longest = gaps.max(by: { $0.days < $1.days }),
              longest.days >= Double(minimumNotableGapDays),
              longest.endsAt >= windowStart else { return nil }
        return DayHighlight(
            id: "absence-\(place.name)", symbol: "calendar.badge.clock",
            headline: "Longest gap yet at \(place.name)",
            detail: "\(Int(longest.days)) days since the visit before this one.",
            isCelebration: false
        )
    }

    /// One restrained sentence comparing this period's logged time with the same
    /// period a year ago — not a trend line, not a breakdown by category, just
    /// whether there was noticeably more or less of the archive itself that year.
    static func yearOverYear(loggedHours: Double, yearAgoHours: Double,
                             window: InsightWindow) -> DayHighlight? {
        guard yearAgoHours > 0 else { return nil }
        let change = (loggedHours - yearAgoHours) / yearAgoHours
        guard abs(change) >= DayHighlights.noticeableChange else { return nil }
        let percent = DayHighlights.percentage(loggedHours, against: yearAgoHours)
        let more = change > 0
        return DayHighlight(
            id: "year-over-year", symbol: "arrow.triangle.2.circlepath",
            headline: "\(percent)% \(more ? "more" : "less") logged than a year ago",
            detail: "Same \(window.title.lowercased()), a year apart.",
            isCelebration: false
        )
    }
}
