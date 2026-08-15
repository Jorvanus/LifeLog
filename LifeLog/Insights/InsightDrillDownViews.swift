import SwiftUI
import SwiftData

/// Every "browse deeper" destination Insights can push, on one `NavigationStack`
/// (the one `InsightsView` itself owns) via one `.navigationDestination(for:)`.
///
/// Before this, the same four destinations were reached two different ways: Week
/// and Month already pushed `InsightGroupDetailView`/`InsightPlaceHistoryView`
/// directly via `NavigationLink { DestinationView(...) }`, while the donut, the
/// Year chart and the Month comparison list opened the same (or an equivalent)
/// destination as a `.sheet` with its own throwaway `NavigationStack` inside. A
/// visit opened three sheets deep that way -- life area sheet, activity `NavigationLink`
/// inside it, `VisitEditor` `NavigationLink` inside that -- rendered inside a
/// `.medium`/`.large` detent card, and Back had to be swiped/dismissed through
/// each layer to return to Insights rather than popped.
///
/// Cases carry only identifying values, never `rows`/`segments` themselves:
/// `SliceRow` and `InsightSegment` both hold a `Visit?`, a SwiftData `@Model`
/// reference, which does not belong in a `Hashable`/`Codable` navigation path.
/// `InsightsView.routeDestination(_:)` recomputes the bounded rows from its own
/// `snapshot` when a route is revealed -- a side effect of this is that a
/// destination already on screen updates itself when the snapshot reloads (an
/// added visit, say) instead of showing what Insights knew at the moment it was
/// opened, which is what `InsightActivityDetailView`'s add-visit sheet used to
/// paper over by dismissing itself back to Insights (see the sheet's own comment,
/// removed below, for the old reasoning).
///
/// `.visit` does the same thing `ArchiveSearchView`'s `.navigationDestination(for:
/// UUID.self)` already does for the same reason: a `Visit` is a `@Model` reference,
/// so the route carries its durable `stableID` and `InsightVisitDestination`
/// resolves the current object from the store when the route is revealed, rather
/// than carrying a reference that could go stale or cross an actor boundary.
enum InsightsRoute: Hashable {
    case activity(name: String, isUnlogged: Bool)
    case sleep
    case group(title: String, groups: [String])
    case place(name: String)
    case comparison(name: String, hours: Double, previousHours: Double, delta: Double)
    case visit(stableID: UUID)
}

/// Resolves a route's `stableID` to the live `Visit` `VisitEditor` needs. Mirrors
/// `ArchiveSearchView`'s private `ArchiveSearchResultDestination` -- same reasoning,
/// kept as a separate small view here rather than widening that one's visibility,
/// since the two navigation stacks (Search, Insights) have no other reason to share
/// a type.
struct InsightVisitDestination: View {
    let stableID: UUID
    @Environment(\.modelContext) private var context
    @State private var visit: Visit?
    @State private var notFound = false

    var body: some View {
        Group {
            if let visit {
                VisitEditor(visit: visit)
            } else if notFound {
                ContentUnavailableView("Visit not found", systemImage: "questionmark.circle",
                                       description: Text("This entry may have been removed or merged."))
            } else {
                ProgressView()
            }
        }
        .task { load() }
    }

    private func load() {
        var descriptor = FetchDescriptor<Visit>(predicate: #Predicate { $0.stableID == stableID })
        descriptor.fetchLimit = 1
        visit = try? context.fetch(descriptor).first
        notFound = visit == nil
    }
}

/// Detail destinations opened from Insights. They deliberately receive the
/// already bounded segments from the parent instead of querying the archive.
struct InsightActivityDetailView: View {
    let activity: String
    let periodTitle: String
    let interval: DateInterval
    let rows: [SliceRow]
    var isUnlogged: Bool = false
    @State private var addingVisit = false

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
                            NavigationLink(value: InsightsRoute.visit(stableID: visit.stableID)) {
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
        // `rows` is no longer a stale snapshot to escape: this view is reached
        // through `InsightsView.routeDestination(_:)`, which recomputes it from
        // `snapshot.segments` on every render, so it already reflects a visit added
        // here as soon as the invalidation notification `ManualVisitView`'s save
        // posts reaches `InsightsView` -- no dismissal needed.
        .sheet(isPresented: $addingVisit) { ManualVisitView(range: interval) }
        .accessibilityIdentifier("insight-activity-detail")
    }
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
                    NavigationLink(value: InsightsRoute.activity(name: activity.name, isUnlogged: false)) {
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
                            NavigationLink(value: InsightsRoute.visit(stableID: visit.stableID)) {
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
                Text("Compared with \(baselineTitle)")
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
