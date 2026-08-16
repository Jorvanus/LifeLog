import SwiftUI
import SwiftData

/// Every unlogged gap in the archive, in one browsable list — the "Needs your
/// attention" card on the Day screen only ever shows the two largest gaps for
/// one day at a time; this is "the whole list" it deliberately doesn't try to
/// be, so a person can review everything the routine gap-fill repair would
/// touch (and everything it wouldn't) before running it.
///
/// Genuinely interactive, not a report: tapping a row opens the same
/// `ManualVisitView` sheet the Day screen's own gap tap already uses, so
/// describing a gap by hand here feels identical to everywhere else in the
/// app. A fillable gap also gets a swipe action that applies the routine
/// template to just that one gap immediately, without a sheet — the fast
/// path for "yes, that guess is right."
struct UnloggedGapsView: View {
    @Environment(\.modelContext) private var context
    @State private var gaps: [ArchiveRepair.GapListing] = []
    @State private var loading = true
    @State private var filter = Filter.all
    @State private var editingRange: DateInterval?
    @State private var filling: Set<Date> = []
    @State private var message: String?

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case fillable = "Will be filled"
        case review = "Needs review"
        var id: Self { self }
    }

    private var filtered: [ArchiveRepair.GapListing] {
        switch filter {
        case .all: gaps
        case .fillable: gaps.filter(\.isFillable)
        case .review: gaps.filter { !$0.isFillable }
        }
    }

    var body: some View {
        Group {
            if loading {
                ProgressView("Scanning your archive…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("unlogged-gaps-loading")
            } else if gaps.isEmpty {
                ContentUnavailableView("Nothing unlogged", systemImage: "checkmark.circle",
                                       description: Text("Every stretch of your archive has something recorded."))
                    .accessibilityIdentifier("unlogged-gaps-empty")
            } else {
                list
            }
        }
        .navigationTitle("Unlogged Time")
        .accessibilityIdentifier("unlogged-gaps-screen")
        .task { await load() }
        .sheet(item: Binding(
            get: { editingRange.map { IdentifiableRange(interval: $0) } },
            set: { editingRange = $0?.interval }
        ), onDismiss: { Task { await load() } }) { wrapped in
            ManualVisitView(range: wrapped.interval)
        }
        .alert("Gap fill", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(message ?? "") }
    }

    private var list: some View {
        List {
            Section {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets())
                .padding(.vertical, 4)
                .accessibilityIdentifier("unlogged-gaps-filter")
            }
            Section {
                ForEach(filtered) { gap in
                    GapListRow(gap: gap, isFilling: filling.contains(gap.id)) {
                        editingRange = DateInterval(start: gap.start, end: gap.end)
                    }
                    .swipeActions(edge: .trailing) {
                        if gap.isFillable {
                            Button("Fill as suggested") { Task { await fill(gap) } }
                                .tint(.green)
                        }
                    }
                }
            } header: {
                Text("\(filtered.count) gap\(filtered.count == 1 ? "" : "s") · "
                     + formattedDuration(filtered.reduce(0) { $0 + $1.hours } * 3600) + " total")
            }
        }
        .accessibilityIdentifier("unlogged-gaps-list")
    }

    private func load() async {
        loading = gaps.isEmpty
        let container = context.container
        let actor = ArchiveRepairActor(modelContainer: container)
        if let result = try? await actor.listGaps() {
            gaps = result
        }
        loading = false
    }

    private func fill(_ gap: ArchiveRepair.GapListing) async {
        filling.insert(gap.id)
        let container = context.container
        let actor = ArchiveRepairActor(modelContainer: container)
        let created = (try? await actor.fillSingleGap(start: gap.start, end: gap.end)) ?? 0
        filling.remove(gap.id)
        if created > 0 {
            gaps.removeAll { $0.id == gap.id }
        } else {
            message = "This gap changed since the list loaded and could no longer be filled automatically. Pull to refresh, or tap it to fill it by hand."
        }
    }
}

/// `DateInterval` alone can't be `Identifiable` for `.sheet(item:)` — its
/// `id` would have to be itself, and two structurally-equal intervals from
/// two different gaps would then collide as "the same sheet."
private struct IdentifiableRange: Identifiable {
    let interval: DateInterval
    var id: Date { interval.start }
}

private struct GapListRow: View {
    let gap: ArchiveRepair.GapListing
    let isFilling: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(gap.start.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(formattedDuration(gap.hours * 3600))
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                Text("until \(gap.end.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Between \(gap.beforePlaceName) (\(gap.beforeActivity)) and \(gap.afterPlaceName) (\(gap.afterActivity))")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                if isFilling {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Filling…").font(.caption2).foregroundStyle(.secondary)
                    }
                } else if gap.isFillable {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption2)
                        Text("Would fill: \(gap.fillPreview.joined(separator: " → "))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).font(.caption2)
                        Text("Left for manual review — longer than a day, or borders live-tracked history")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(isFilling)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("unlogged-gap-row")
    }
}
