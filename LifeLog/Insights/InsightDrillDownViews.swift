import SwiftUI
import SwiftData

/// Detail destinations opened from Insights. They deliberately receive the
/// already bounded segments from the parent instead of querying the archive.
struct InsightActivityDetailView: View {
    let activity: String
    let periodTitle: String
    let interval: DateInterval
    let rows: [SliceRow]
    var isUnlogged: Bool = false
    @State private var addingVisit = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                LabeledContent("Period", value: periodTitle)
                LabeledContent("Total", value: formatHours(rows.reduce(0) { $0 + $1.hours }))
            }
            .accessibilityIdentifier("insight-activity-period")
            Section("Visits in this period") {
                if rows.isEmpty {
                    if isUnlogged {
                        ContentUnavailableView {
                            Label("Unlogged time", systemImage: "clock.badge.questionmark")
                        } description: {
                            Text("There isn’t a visit to edit for this time yet. Add one to fill the gap in your insights.")
                        } actions: {
                            Button("Add Visit") { addingVisit = true }
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        ContentUnavailableView("No recorded visits", systemImage: "clock.badge.questionmark",
                                               description: Text("This activity has no usable records in the selected period."))
                    }
                } else {
                    ForEach(rows) { row in
                        if let visit = row.visit {
                            NavigationLink { VisitEditor(visit: visit) } label: {
                                InsightRowLabel(title: visit.displayPlaceName,
                                                detail: "\(visit.arrival.formatted(date: .abbreviated, time: .shortened)) · \(formatHours(row.hours))")
                            }
                        } else {
                            InsightRowLabel(title: row.activity, detail: formatHours(row.hours))
                        }
                    }
                }
            }
        }
        .navigationTitle(activity)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) { PeriodBanner(title: periodTitle, interval: interval) }
        // This screen's own `rows` was computed once, from what Insights knew before
        // the visit existed, so it stays stale even after the visit is saved. Rather
        // than re-querying just to re-show the same now-wrong "Unlogged" placeholder,
        // close back to Insights -- the outer sheet's `onDismiss: reloadInsights`
        // (in InsightsView) picks up the new visit from there.
        .sheet(isPresented: $addingVisit, onDismiss: { dismiss() }) { ManualVisitView(range: interval) }
        .accessibilityIdentifier("insight-activity-detail")
    }
}

/// Sheet-presentation payload for `InsightGroupDetailView`: which real groups to
/// show (see that view's `groups` doc) and the title to show them under, since a
/// folded "Other" selection still reads as "Other" to the person even though it
/// spans several underlying groups.
struct GroupSelection: Identifiable {
    let title: String
    let groups: [String]
    var id: String { title }
}

struct InsightGroupDetailView: View {
    let title: String
    /// Every real group this drill-down represents. Usually one, but the Year
    /// chart's synthetic "Other" bucket folds several low-ranking groups together
    /// for legibility (see `AnnualGroupChartDataBuilder`), so opening it has to
    /// match all of them rather than the single label "Other".
    let groups: [String]
    let periodTitle: String
    let interval: DateInterval
    let segments: [InsightSegment]

    private var activities: [(name: String, hours: Double, rows: [SliceRow])] {
        let matching = segments.filter {
            !$0.isUnlogged && groups.contains(AnnualInsights.group(for: $0))
        }
        let grouped = Dictionary(grouping: matching, by: \.activity)
        return grouped.map { name, segments in
            (name, segments.reduce(0) { $0 + $1.hours }, segments.map {
                SliceRow(id: $0.id, visit: $0.visit, activity: $0.activity, placeName: $0.placeName,
                         start: $0.start, end: $0.end, hours: $0.hours, isPartial: false)
            })
        }.sorted { $0.hours > $1.hours }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Period", value: periodTitle)
                LabeledContent("Total", value: formatHours(activities.reduce(0) { $0 + $1.hours }))
            }
            Section("Activities in this group") {
                ForEach(activities, id: \.name) { activity in
                    NavigationLink {
                        InsightActivityDetailView(activity: activity.name, periodTitle: periodTitle,
                                                  interval: interval, rows: activity.rows)
                    } label: {
                        InsightRowLabel(title: activity.name, detail: formatHours(activity.hours))
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) { PeriodBanner(title: periodTitle, interval: interval) }
        .accessibilityIdentifier("insight-group-detail")
    }
}

struct InsightPlaceHistoryView: View {
    let placeName: String
    let periodTitle: String
    let interval: DateInterval
    let rows: [SliceRow]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SavedPlace.name) private var savedPlaces: [SavedPlace]

    @State private var pickingMergeTarget = false
    @State private var mergeTarget: SavedPlace?
    @State private var mergeInFlight = false
    @State private var mergeFailed = false

    var body: some View {
        List {
            Section {
                LabeledContent("Period", value: periodTitle)
                LabeledContent("Visits", value: "\(rows.compactMap(\.visit).count)")
                LabeledContent("Time", value: formatHours(rows.reduce(0) { $0 + $1.hours }))
            }
            Section("Visits in this period") {
                if rows.isEmpty {
                    ContentUnavailableView("No visits", systemImage: "mappin.slash",
                                           description: Text("This place has no usable records in the selected period."))
                } else {
                    ForEach(rows) { row in
                        if let visit = row.visit {
                            NavigationLink { VisitEditor(visit: visit) } label: {
                                InsightRowLabel(title: visit.suspectedActivity.isEmpty ? "Visit" : visit.suspectedActivity,
                                                detail: "\(visit.arrival.formatted(date: .abbreviated, time: .shortened)) · \(formatHours(row.hours))")
                            }
                        } else {
                            InsightRowLabel(title: row.activity, detail: formatHours(row.hours))
                        }
                    }
                }
            }
            if !mergeCandidates.isEmpty {
                Section {
                    Button {
                        pickingMergeTarget = true
                    } label: {
                        if mergeInFlight {
                            HStack { ProgressView(); Text("Merging…") }
                        } else {
                            Label("Merge into another place", systemImage: "arrow.triangle.merge")
                        }
                    }
                    .disabled(mergeInFlight)
                    .accessibilityIdentifier("merge-place-button")
                } footer: {
                    Text("For when the same place shows up under more than one name -- an imported address and a Saved Place, say. Moves every visit here onto the place you pick and combines them in Insights.")
                }
            }
        }
        .navigationTitle(placeName)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) { PeriodBanner(title: periodTitle, interval: interval) }
        .accessibilityIdentifier("insight-place-history-detail")
        .alert("Merge didn’t finish", isPresented: $mergeFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("“\(placeName)” could not be merged just now. Nothing changed; try again.")
        }
        .confirmationDialog("Merge into “\(mergeTarget?.name ?? "")”?", isPresented: Binding(
            get: { mergeTarget != nil }, set: { if !$0 { mergeTarget = nil } }),
            titleVisibility: .visible
        ) {
            if let mergeTarget {
                Button("Merge into “\(mergeTarget.name)”", role: .destructive) { performMerge(into: mergeTarget) }
            }
            Button("Cancel", role: .cancel) { mergeTarget = nil }
        } message: {
            Text("Moves every visit recorded as “\(placeName)” onto “\(mergeTarget?.name ?? "")”. This can’t be undone from here -- export a backup first if you’re unsure.")
        }
        .sheet(isPresented: $pickingMergeTarget) {
            NavigationStack {
                PlaceMergeTargetPicker(candidates: mergeCandidates) { target in
                    pickingMergeTarget = false
                    mergeTarget = target
                }
            }
        }
    }

    /// Saved Places this history could merge into -- every Saved Place except one
    /// already carrying this exact name, since that would be a no-op merge.
    private var mergeCandidates: [SavedPlace] {
        savedPlaces.filter { $0.name.caseInsensitiveCompare(placeName) != .orderedSame }
    }

    /// Runs in the background so a large archive cannot stall the confirmation
    /// dialog's dismissal.
    private func performMerge(into target: SavedPlace) {
        mergeTarget = nil
        mergeInFlight = true
        let source = placeName
        let targetName = target.name
        Task {
            do {
                _ = try await PlaceRenameActor(modelContainer: context.container)
                    .mergePlace(sourceNames: [source], targetName: targetName)
                InsightsInvalidation.invalidate(reason: "Places merged", context: context)
                mergeInFlight = false
                dismiss()
            } catch is CancellationError {
                mergeInFlight = false
            } catch {
                mergeInFlight = false
                mergeFailed = true
            }
        }
    }
}

private struct PlaceMergeTargetPicker: View {
    let candidates: [SavedPlace]
    let onPick: (SavedPlace) -> Void
    @State private var search = ""

    private var filtered: [SavedPlace] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return candidates }
        return candidates.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if filtered.isEmpty {
                ContentUnavailableView("No other places", systemImage: "arrow.triangle.merge",
                                       description: Text("There’s nothing else in your Saved Places to merge into."))
            } else {
                Section {
                    ForEach(filtered) { place in
                        Button {
                            onPick(place)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: place.role == "home" ? "house.fill" : "mappin.circle.fill")
                                    .foregroundStyle(.secondary)
                                Text(place.name).foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Merge into…")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Find a place")
        .accessibilityIdentifier("place-merge-target-picker")
    }
}

struct InsightComparisonDetailView: View {
    let comparison: TrendComparison
    let periodTitle: String
    let baselineTitle: String

    var body: some View {
        List {
            Section("Selected period") {
                LabeledContent(periodTitle, value: formatHours(comparison.hours))
                LabeledContent("Baseline", value: formatHours(comparison.previousHours))
                LabeledContent("Difference", value: formatHours(abs(comparison.delta)) + (comparison.delta >= 0 ? " more" : " less"))
            }
            Section {
                Text("This comparison describes a difference in recorded time. It does not explain why the change happened.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("Compared with (baselineTitle)")
            }
        }
        .navigationTitle(comparison.name)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("insight-comparison-detail")
    }
}

struct InsightSleepDetailView: View {
    let periodTitle: String
    let interval: DateInterval
    let segments: [InsightSegment]
    let activityData: ActivityDataService
    @State private var summary: SleepSummary?

    private var recordedHours: Double { segments.filter(\.isSleep).reduce(0) { $0 + $1.hours } }

    var body: some View {
        List {
            Section("Recorded sleep") {
                LabeledContent("Period", value: periodTitle)
                LabeledContent("Duration", value: summary.map { formatHours($0.totalSleep / 3600) } ?? formatHours(recordedHours))
                if let summary {
                    LabeledContent("LifeLog estimated score", value: "\(summary.estimatedScore)/100")
                    LabeledContent("Interruptions", value: "\(summary.interruptions)")
                    if summary.rem + summary.core + summary.deep > 0 {
                        LabeledContent("Stages", value: "REM \(formatHours(summary.rem / 3600)) · Core \(formatHours(summary.core / 3600)) · Deep \(formatHours(summary.deep / 3600))")
                    }
                } else {
                    Text("Sleep stages and interruptions are unavailable for this period.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("About this data") {
                Text(summary == nil ? "No Apple Health sleep samples were available. Recorded sleep-looking visits are shown as LifeLog activity only." : "Source: Apple Health. Sleep stages come from Health data when available. The score is a LifeLog estimate, not an Apple Watch or Apple Health score.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let imported = activityData.ui.lastImport {
                    Text("Last successful Health import: \(imported.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Sleep")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) { PeriodBanner(title: periodTitle, interval: interval) }
        .task { summary = await activityData.sleepSummary(for: interval) }
        .accessibilityIdentifier("insight-sleep-detail")
    }
}

struct InsightGapDetailView: View {
    let gap: InsightSegment
    let periodTitle: String
    @State private var adding = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Unlogged time") {
                LabeledContent("Period", value: periodTitle)
                LabeledContent("Gap", value: "\(gap.start.formatted(date: .omitted, time: .shortened))–\(gap.end.formatted(date: .omitted, time: .shortened))")
                LabeledContent("Duration", value: formatHours(gap.hours))
            }
            Section {
                Button { adding = true } label: {
                    Label("Add or categorise a visit", systemImage: "plus.circle.fill")
                }
            } footer: {
                Text("This exact gap is selected so the visit you add will not broaden into another part of the day.")
            }
        }
        .navigationTitle("Timeline gap")
        .navigationBarTitleDisplayMode(.inline)
        // Same reasoning as `InsightActivityDetailView`: this screen describes one
        // specific gap that no longer exists once a visit fills it, so close back to
        // Insights rather than linger showing a gap that was just resolved.
        .sheet(isPresented: $adding, onDismiss: { dismiss() }) {
            ManualVisitView(range: DateInterval(start: gap.start, end: gap.end))
        }
        .accessibilityIdentifier("insight-gap-detail")
    }
}

// Shared by all Insights drill-down destinations, including the Month place list.
struct PeriodBanner: View {
    let title: String
    let interval: DateInterval
    var body: some View {
        Text("Selected period: \(title)")
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal).padding(.vertical, 8)
            .background(.thinMaterial)
            .accessibilityElement(children: .combine)
    }
}

private struct InsightRowLabel: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}
