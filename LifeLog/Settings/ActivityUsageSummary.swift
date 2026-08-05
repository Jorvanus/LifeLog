import SwiftUI
import SwiftData

/// When an activity was first and last used, in words.
///
/// A count alone does not tell you whether a label is part of your life or something
/// you created once and forgot. "Used once, on Thursday 18 August 2025" answers that
/// immediately, and is usually the sign of an activity worth deleting or merging.
struct ActivityUsageSummary: View {
    let activityName: String
    @Query private var candidates: [Visit]

    init(activityName: String) {
        self.activityName = activityName
        let name = activityName
        // SwiftData cannot filter on `activity` because it is computed, so the fetch
        // is loose and narrowed below by the same rule the rest of the app uses.
        _candidates = Query(
            filter: #Predicate<Visit> { $0.userActivity == name || $0.inferredActivity == name },
            sort: [SortDescriptor(\Visit.arrival, order: .reverse)]
        )
    }

    private var statistics: ActivityStatistics {
        ActivityStatistics.make(activity: activityName, visits: candidates)
    }

    var body: some View {
        let statistics = statistics
        if let first = statistics.firstUsed, let last = statistics.lastUsed {
            Section {
                Text(firstSentence(occasions: statistics.occasions, first: first))
                // Suppressed when both dates are the same day: "used once on Thursday,
                // last used Thursday" says the same thing twice.
                if statistics.occasions > 1 || !Calendar.current.isDate(first, inSameDayAs: last) {
                    Text("Last used on \(last.formatted(date: .long, time: .omitted)).")
                }
                LabeledContent("Total time", value: formattedDuration(statistics.totalTime))
            } header: {
                Text("Usage")
            }
            .font(.subheadline)
        }
    }

    private func firstSentence(occasions: Int, first: Date) -> String {
        let date = first.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        return occasions == 1
            ? "This activity was used once, on \(date)."
            : "First used on \(date), \(occasions) times since."
    }
}
