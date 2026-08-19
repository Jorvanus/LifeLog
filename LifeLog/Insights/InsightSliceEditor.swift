import SwiftUI
import SwiftData

/// Correcting a slice of the ring without leaving Insights, and the placeholder
/// shown where a window has nothing in it.
struct InsightSliceEditor: View {
    @Environment(\.dismiss) private var dismiss
    let slice: TimeSlice
    /// Each row's own post-resolution contribution to `slice`, never a raw
    /// `Visit.duration` — see `InsightsSnapshot.sliceRows`. Two overlapping
    /// records (an overnight Home stay under a Sleep record, a duplicate
    /// automatic callback) each get only the hours they actually won, so the
    /// rows sum to exactly `slice.hours`, matching the donut and its header.
    let rows: [SliceRow]
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
                } else if rows.isEmpty {
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
                                    Text("across \(rows.count) \(rows.count == 1 ? "entry" : "entries")")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(formatHours(slice.hours)) across \(rows.count) \(rows.count == 1 ? "entry" : "entries")")
                        }
                        Section("Edit activity or place type") {
                            Text("Choose an entry to correct its activity or place type. Recognised locations reuse the saved choice for future visits, and remain editable.")
                                .font(.footnote).foregroundStyle(.secondary)
                            ForEach(rows) { row in
                                if let visit = row.visit {
                                    NavigationLink { VisitEditor(visit: visit) } label: {
                                        rowContent(row)
                                    }
                                } else if let commute = row.commute {
                                    NavigationLink { CommuteDetailView(commute: commute) } label: {
                                        rowContent(row)
                                    }
                                } else {
                                    rowContent(row)
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

    @ViewBuilder
    private func rowContent(_ row: SliceRow) -> some View {
        let title = row.visit?.placeName ?? row.activity
        let iconContext = row.visit?.displayPlaceName ?? row.activity
        HStack(spacing: 12) {
            ActivityIcon(activity: row.activity, context: iconContext,
                         color: activityColor(row.activity), size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).lineLimit(1)
                Text(entryTime(for: row)).font(.caption).foregroundStyle(.secondary)
                // Made explicit rather than left for the reader to notice the
                // number looks smaller than the entry's own arrival/departure
                // would suggest — the rest of its time went to another entry.
                if row.isPartial {
                    Text("Shares this time with another entry")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            Text(formatHours(row.hours))
                .font(.caption.bold().monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(title), \(entryTime(for: row)), \(formatHours(row.hours))"
            + (row.isPartial ? ", shares this time with another entry" : "")
        )
    }

    private func entryTime(for row: SliceRow) -> String {
        let date = row.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return "\(date) · \(row.start.formatted(date: .omitted, time: .shortened))–\(row.end.formatted(date: .omitted, time: .shortened))"
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
