import Foundation
import SwiftData
import CoreLocation

/// Naming a journey after where it was going, once the next destination is known.
///
/// One of six files `ActivityLocationPolicy` was split into. It had reached 985 lines
/// across six concerns, interleaved rather than merely adjacent. Same type, same call
/// sites — only the text moved.
extension ActivityLocationPolicy {

    /// Gives movement records a useful destination label once the next place is known.
    /// Work and home are stable labels; other places need to recur across multiple days
    /// before they are used as a learned destination name.
    static func updateTravelDescriptions(context: ModelContext) throws {
        let visits = try fetchPolicyVisits(context: context)
        let locations = visits.filter { isLocationVisit($0) && !$0.isIgnored }
        for activity in visits where isTravelActivity(activity) && !activity.isIgnored {
            let end = activity.departure ?? .now
            guard let destination = locations
                .filter({ $0.arrival >= end })
                .min(by: { $0.arrival < $1.arrival }),
                  let label = destinationLabel(for: destination, locations: locations) else {
                continue
            }

            let description = "Travelling to \(label)"
            // Generated labels may evolve as the destination becomes known, but a custom
            // activity entered by the user remains authoritative.
            let isGeneratedActivity = activity.userActivity == nil ||
                activity.userActivity == activity.inferredActivity ||
                activity.userActivity == "Travelling" ||
                activity.userActivity == "In transit"
            activity.inferredActivity = description
            activity.recognitionConfidence = destinationConfidence(for: destination, locations: locations)
            if isGeneratedActivity {
                activity.userActivity = description
            }
        }
    }

    private static func destinationLabel(for destination: Visit, locations: [Visit]) -> String? {
        let destinationText = destination.placeName.lowercased()
        if InferenceEngine.canonicalActivity(placeName: destination.placeName) == "Working" {
            return "Work"
        }
        if destinationText.contains("home") {
            return "Home"
        }

        let key = NameKey.matching(destination.placeName)
        guard !key.isEmpty, !Visit.isPlaceholderName(destination.placeName) else { return nil }
        let matches = locations.filter { NameKey.matching($0.placeName) == key }
        let distinctDays = Set(matches.map { Calendar.current.startOfDay(for: $0.arrival) }).count
        // Avoid learning a destination name from a one-off or same-day GPS duplicate.
        guard matches.count >= 3, distinctDays >= 2 else { return nil }
        return TextSafety.clean(destination.placeName, maximumLength: 80)
    }

    private static func destinationConfidence(for destination: Visit, locations: [Visit]) -> String {
        let text = destination.placeName.lowercased()
        if InferenceEngine.canonicalActivity(placeName: destination.placeName) == "Working" || text.contains("home") {
            return "learned"
        }
        let key = NameKey.matching(destination.placeName)
        let matches = locations.filter { NameKey.matching($0.placeName) == key }
        let days = Set(matches.map { Calendar.current.startOfDay(for: $0.arrival) }).count
        return matches.count >= 3 && days >= 2 ? "learned" : "medium"
    }
}
