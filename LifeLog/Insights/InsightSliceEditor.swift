import SwiftUI
import SwiftData

/// Correcting a slice of the ring without leaving Insights, and the placeholder
/// shown where a window has nothing in it.
struct InsightSliceEditor: View {
    @Environment(\.dismiss) private var dismiss
    let slice: TimeSlice
    let visits: [Visit]
    let interval: DateInterval
    @State private var addingVisit = false

    var body: some View {
        NavigationStack {
            Group {
                if slice.isUnlogged {
                    ContentUnavailableView {
                        Label("Unlogged time", systemImage: "clock.badge.questionmark")
                    } description: {
                        Text("There isn’t a visit to edit for this time yet. Add one to fill the gap in your insights.")
                    } actions: {
                        Button("Add Visit") { addingVisit = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else if visits.isEmpty {
                    ContentUnavailableView("No matching visits", systemImage: "mappin.slash",
                                           description: Text("This insight changed while it was open."))
                } else {
                    List {
                        Section {
                            HStack(spacing: 14) {
                                Image(systemName: slice.symbol)
                                    .font(.title2.bold()).foregroundStyle(.white)
                                    .frame(width: 48, height: 48).background(slice.color.gradient, in: Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(formatHours(slice.hours)).font(.title3.bold()).monospacedDigit()
                                    Text("across \(visits.count) \(visits.count == 1 ? "entry" : "entries")")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Section("Edit activity or place type") {
                            Text("Choose an entry to correct its activity or place type. Recognised locations reuse the saved choice for future visits, and remain editable.")
                                .font(.footnote).foregroundStyle(.secondary)
                            ForEach(visits) { visit in
                                NavigationLink { VisitEditor(visit: visit) } label: {
                                    HStack(spacing: 12) {
                                        ActivityIcon(activity: visit.activity, context: visit.displayPlaceName,
                                                     color: activityColor(visit.activity), size: 42)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(visit.placeName).font(.headline).lineLimit(1)
                                            Text(entryTime(for: visit)).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(formatHours(visit.duration(in: interval) / 3600))
                                            .font(.caption.bold().monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(slice.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .sheet(isPresented: $addingVisit) { ManualVisitView(range: interval) }
    }

    private func entryTime(for visit: Visit) -> String {
        let start = max(visit.arrival, interval.start)
        let end = min(visit.departure ?? .now, interval.end)
        let date = start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return "\(date) · \(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }
}


struct InsightEmptyRow: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon).font(.title2).foregroundStyle(.secondary).frame(width: 42, height: 42)
                .background(Color.secondary.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
