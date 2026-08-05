import Foundation

/// A stretch of time LifeLog has nothing for, with its best reading of what happened.
///
/// Adding an entry by hand is nearly always filling in something the app missed, and
/// the app already knows where its own holes are: the gaps between what it recorded.
/// What sat either side says what the gap probably was — leaving home and arriving at
/// work with nothing between them is a commute, and the same place on both sides is
/// usually still being there.
struct VisitSuggestion: Identifiable, Sendable {
    let start: Date
    let end: Date
    let place: String
    let activity: String
    var id: Date { start }

    var timeRange: String {
        "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    var summary: String { "\(activity) · \(place)" }

    /// Gaps worth offering: long enough to be real, short enough to be one thing.
    static let shortest: TimeInterval = 5 * 60
    static let longest: TimeInterval = 6 * 60 * 60

    static func make(from visits: [Visit], now: Date = .now, limit: Int = 4) -> [VisitSuggestion] {
        let stays = visits
            .filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
            .filter { $0.resolutionState != .superseded && $0.departure != nil }
            .sorted { $0.arrival < $1.arrival }
        guard stays.count > 1 else { return [] }

        var suggestions: [VisitSuggestion] = []
        for (before, after) in zip(stays, stays.dropFirst()) {
            guard let departure = before.departure else { continue }
            let gap = after.arrival.timeIntervalSince(departure)
            guard gap >= shortest, gap <= longest else { continue }
            suggestions.append(VisitSuggestion(
                start: departure, end: after.arrival,
                place: place(between: before, and: after),
                activity: activity(between: before, and: after)
            ))
        }
        // Newest first: a gap from this morning is likelier to be filled in than one
        // from last week, and the list is short by design.
        return Array(suggestions.sorted { $0.start > $1.start }.prefix(limit))
    }

    private static func place(between before: Visit, and after: Visit) -> String {
        // Returning to the same place means the gap was probably still being there.
        if before.displayPlaceName.caseInsensitiveCompare(after.displayPlaceName) == .orderedSame {
            return before.displayPlaceName
        }
        return "\(before.displayPlaceName) → \(after.displayPlaceName)"
    }

    private static func activity(between before: Visit, and after: Visit) -> String {
        if before.displayPlaceName.caseInsensitiveCompare(after.displayPlaceName) == .orderedSame {
            return before.suspectedActivity
        }
        // Between home and work in either direction, the gap is the commute.
        let names = [before.placeName.lowercased(), after.placeName.lowercased()]
        let isHome = names.contains { $0.contains("home") }
        let isWork = names.contains { InferenceEngine.activity(placeName: $0) == "Working" }
        if isHome && isWork { return CommuteDetection.activityName }
        return "Travelling"
    }
}
