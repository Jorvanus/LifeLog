import SwiftUI
import SwiftData
import Charts

/// One activity in depth: how it moved over time, how it compares with the period
/// before, where it happens, and the totals underneath — plus, for one already in
/// the catalogue, everything about it that can be changed.
///
/// Used to be two screens: this one, read-only, reached from the Activities tab;
/// and a separate editor for name/colour/category/icon, reached only from Settings.
/// The stats told you what an activity was doing and the editor told you what it
/// looked like, and neither could answer the other's question — editing meant
/// leaving the page you were already looking at to find the same activity again
/// in a different tab. One screen now does both.
struct ActivityDetailView: View {
    let activityName: String
    var symbol: String = "circle.fill"
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var candidates: [Visit]
    @State private var window: Window = .week
    @State private var now = Date.now
    /// Held in state rather than read inline, so adopting updates this page in place
    /// instead of leaving the offer sitting there once it has been taken.
    @State private var isAdopted = true

    // Editable only once adopted -- an unadopted label has no catalogue entry yet
    // for any of this to belong to.
    @State private var existingID: UUID?
    @State private var name = ""
    @State private var category = "Other"
    @State private var editSymbol = "circle.fill"
    @State private var categoryColorValue: Color = .gray
    @State private var loadedEditableState = false

    @State private var confirmingDelete = false
    @State private var deleteFailed = false
    /// The name of the existing activity a Save attempt collided with. Renaming
    /// into an occupied name is refused outright rather than silently merging by
    /// spelling — see `mergeTarget` below for the real, explicit replacement.
    @State private var nameCollision: String?

    // Merging into another catalogue activity: pick a target, confirm, then run
    // in the background. `pickingMergeTarget` drives the picker sheet;
    // `mergeTarget` becoming non-nil (once picked) drives the confirmation
    // dialog below — two separate states because they are two steps the person
    // can back out of independently.
    @State private var pickingMergeTarget = false
    @State private var mergeTarget: ActivityDefinition?
    @State private var mergeInFlight = false
    @State private var mergeFailed = false

    enum Window: String, CaseIterable, Identifiable {
        case week = "7 days"
        case month = "30 days"
        case quarter = "90 days"

        var days: Int {
            switch self {
            case .week: 7
            case .month: 30
            case .quarter: 90
            }
        }
        var id: String { rawValue }
    }

    init(activityName: String, symbol: String = "circle.fill") {
        self.activityName = activityName
        self.symbol = symbol
        let name = activityName
        // Keep this identity predicate centralised with the other bounded history
        // fetches instead of letting each detail screen grow its own broad query.
        _candidates = Query(VisitHistoryQuery.activity(named: name))
    }

    private var statistics: ActivityStatistics {
        ActivityStatistics.make(activity: activityName, visits: candidates,
                                days: window.days, now: now)
    }

    var body: some View {
        List {
            // First, because it is the only thing on this screen that needs doing. The
            // row that led here says the label is not an activity yet; until this
            // existed, tapping that message arrived somewhere that could not act on it,
            // and the only remedy was a swipe mentioned once in a footer.
            if !isAdopted {
                adoption
            } else {
                editable
            }
            if statistics.isEmpty {
                ContentUnavailableView("Nothing recorded yet", systemImage: "chart.line.uptrend.xyaxis",
                                       description: Text("When your timeline uses “\(activityName)”, its history appears here."))
            } else {
                overTime
                comparison
                places
                totals
                history
                usage
            }
            if isAdopted {
                mergeSection
                deletion
            }
        }
        .navigationTitle(activityName)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("activity-detail-screen")
        .toolbar {
            if isAdopted {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { attemptSave() }
                        .disabled(TextSafety.clean(name, maximumLength: 80).isEmpty)
                }
            }
        }
        .onAppear {
            now = .now
            isAdopted = ActivityCatalog.isAdopted(activityName)
            if isAdopted, !loadedEditableState {
                loadEditableState()
                loadedEditableState = true
            }
        }
        .alert("“\(nameCollision ?? "")” already exists", isPresented: Binding(
            get: { nameCollision != nil }, set: { if !$0 { nameCollision = nil } })
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Two activities can’t share a name. To combine them, use “Merge into another activity” below instead of renaming.")
        }
        .alert("Merge didn’t finish", isPresented: $mergeFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("“\(activityName)” could not be merged just now. Nothing changed; try again.")
        }
        .alert("Activity couldn’t be deleted", isPresented: $deleteFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Nothing changed. Check that the local store is available and try again.")
        }
        .confirmationDialog("Delete activity?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete anyway", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(deletionWarning)
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
            Text("Moves \(statistics.occasions) \(statistics.occasions == 1 ? "visit" : "visits") from “\(activityName)” onto “\(mergeTarget?.name ?? "")” and removes “\(activityName)” from your activities. This can’t be undone from here — export a backup first if you’re unsure.")
        }
        .sheet(isPresented: $pickingMergeTarget) {
            NavigationStack {
                MergeTargetPicker(excluding: existingID, excludingName: activityName) { target in
                    pickingMergeTarget = false
                    mergeTarget = target
                }
            }
        }
    }

    private var adoption: some View {
        Section {
            Button {
                guard (try? ActivityCatalog.adoptFromHistory(activityName, context: context)) == true else { return }
                // Grouping is computed rather than stored, so adopting re-buckets every
                // visit already carrying this label. Insights has to be told.
                InsightsInvalidation.invalidate(reason: "Activity adopted from history", context: context)
                isAdopted = true
                loadEditableState()
                loadedEditableState = true
            } label: {
                Label("Add to Activities", systemImage: "plus.circle.fill")
                    .font(.body.weight(.semibold))
            }
            .accessibilityIdentifier("adopt-activity-button")
        } header: {
            Text("From your history")
        } footer: {
            Text("“\(activityName)” comes from your recorded visits and is not in your activity list yet, so it has no group, icon or colour of its own. Adding it gives it all three — and Insights will stop counting it as Other.")
        }
    }

    private var editable: some View {
        Section {
            TextField("Activity name", text: $name)
            ColorPicker("Activity colour", selection: $categoryColorValue, supportsOpacity: false)
            Picker("Group under", selection: $category) {
                ForEach(ActivityCatalog.categories, id: \.self) { Text($0).tag($0) }
            }
            NavigationLink {
                ActivityIconPicker(symbol: $editSymbol, tint: categoryColorValue)
            } label: {
                LabeledContent("Icon") {
                    Image(systemName: editSymbol).foregroundStyle(categoryColorValue)
                }
            }
            .accessibilityIdentifier("activity-icon-link")
        } footer: {
            Text("The group is how Insights adds this activity up. Changing it re-counts existing visits straight away.")
        }
    }

    private var overTime: some View {
        Section {
            Picker("Period", selection: $window) {
                ForEach(Window.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Chart(statistics.recentDays) { day in
                BarMark(x: .value("Day", day.day, unit: .day),
                        y: .value("Hours", day.hours))
                    .foregroundStyle(activityColor(activityName))
            }
            .frame(height: 160)
            .chartYAxis { AxisMarks(position: .leading) }
            .accessibilityLabel("\(activityName) over the last \(window.rawValue)")
        } header: {
            Text("Over time")
        }
    }

    private var comparison: some View {
        Section {
            LabeledContent("This \(window.rawValue)", value: formattedDuration(statistics.currentPeriodTime))
            LabeledContent("Previous \(window.rawValue)", value: formattedDuration(statistics.previousPeriodTime))
            if let change = statistics.changeFraction {
                LabeledContent("Change") {
                    Label(percentage(change), systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .foregroundStyle(change >= 0 ? .green : .orange)
                }
            }
            LabeledContent("Average per day", value: formattedDuration(statistics.averagePerDay))
            LabeledContent("Average per week", value: formattedDuration(statistics.averagePerWeek))
        } header: {
            Text("Compared with before")
        } footer: {
            if statistics.changeFraction == nil {
                Text("There is nothing recorded in the previous period to compare with.")
            }
        }
    }

    private var places: some View {
        Section("Top locations") {
            ForEach(statistics.places.prefix(8)) { place in
                LabeledContent(place.name, value: "\(place.occasions)")
            }
        }
    }

    private var totals: some View {
        Section("Totals") {
            LabeledContent("Total occasions", value: "\(statistics.occasions)")
            LabeledContent("Total time", value: formattedDuration(statistics.totalTime))
            LabeledContent("Average", value: formattedDuration(statistics.averageTime))
            LabeledContent("Shortest", value: formattedDuration(statistics.shortestTime))
            LabeledContent("Longest", value: formattedDuration(statistics.longestTime))
        }
    }

    /// Exact match on top of the loose fetch: `candidates` is narrowed in the
    /// store first, since SwiftData cannot filter on the computed `activity`
    /// property, then matched precisely here — the same two-step `visits` used
    /// to do on its own before moving in from the old activity editor.
    private var matchingVisits: [Visit] {
        let key = activityName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return candidates.filter {
            $0.activity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
        }
    }

    @ViewBuilder private var history: some View {
        if !matchingVisits.isEmpty {
            Section {
                NavigationLink {
                    ActivityVisitsView(activityName: activityName, visits: matchingVisits)
                } label: {
                    LabeledContent("History", value: "\(matchingVisits.count) \(matchingVisits.count == 1 ? "visit" : "visits")")
                }
                .accessibilityIdentifier("activity-visits-link")
            } footer: {
                Text("Open to review them, or correct one on its own without changing the rest.")
            }
        }
    }

    @ViewBuilder private var usage: some View {
        Section {
            if let first = statistics.firstUsed {
                Text(usageSentence(occasions: statistics.occasions, first: first))
            }
            if let last = statistics.lastUsed {
                Text("Last used on \(last.formatted(date: .long, time: .omitted)).")
            }
        } header: {
            Text("Usage")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var mergeSection: some View {
        Section {
            Button {
                pickingMergeTarget = true
            } label: {
                if mergeInFlight {
                    HStack { ProgressView(); Text("Merging…") }
                } else {
                    Label("Merge into another activity", systemImage: "arrow.triangle.merge")
                }
            }
            .disabled(mergeInFlight)
            .accessibilityIdentifier("merge-activity-button")
        } footer: {
            Text("Combine duplicate activities — like “Doctor” and “Seeing Doctor” — into one. Choose the activity to keep; everything here moves onto it and this entry is removed.")
        }
    }

    private var deletion: some View {
        Section {
            Button("Delete Activity", role: .destructive) { confirmingDelete = true }
                .accessibilityIdentifier("delete-activity")
        } footer: {
            Text(statistics.occasions > 0
                 ? "Its visits keep their label, but Insights counts them as “Other” until an activity with this name exists again."
                 : "Nothing in your timeline uses this activity.")
        }
    }

    /// Reads as a sentence rather than a field, because a single use is worth saying
    /// out loud: it is usually the sign of a label that was created and then forgotten.
    private func usageSentence(occasions: Int, first: Date) -> String {
        let date = first.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        return occasions == 1
            ? "This activity was used once, on \(date)."
            : "First used on \(date), \(occasions) times since."
    }

    private func percentage(_ change: Double) -> String {
        let magnitude = abs(change) * 100
        let rounded = magnitude >= 10 ? String(format: "%.0f", magnitude) : String(format: "%.1f", magnitude)
        return "\(change >= 0 ? "+" : "−")\(rounded)%"
    }

    private func loadEditableState() {
        guard let definition = ActivityCatalog.load().first(where: {
            $0.name.caseInsensitiveCompare(activityName) == .orderedSame
        }) else { return }
        existingID = definition.id
        name = definition.name
        category = definition.category
        editSymbol = definition.symbol
        categoryColorValue = activityColor(definition.name)
    }

    private func attemptSave() {
        let cleanName = TextSafety.clean(name, maximumLength: 80)
        let cleanCategory = TextSafety.clean(category, maximumLength: 40)
        let cleanSymbol = TextSafety.clean(editSymbol, maximumLength: 60)
        guard !cleanName.isEmpty else { return }
        var definition = ActivityDefinition(id: existingID ?? UUID(), name: cleanName,
                                  category: cleanCategory.isEmpty ? "Other" : cleanCategory,
                                  symbol: cleanSymbol.isEmpty ? "circle.fill" : cleanSymbol)
        definition.colorHex = activityColorHex(categoryColorValue)

        let previousName = activityName
        let renamed = previousName.caseInsensitiveCompare(cleanName) != .orderedSame
        let collision = ActivityCatalog.load().first {
            $0.id != definition.id && $0.name.caseInsensitiveCompare(cleanName) == .orderedSame
        }
        // A new name must remain unique. Renaming into an existing name is refused
        // rather than treated as a merge — two IDs sharing a display name would
        // undo the identity separation this migration adds. Use "Merge into
        // another activity" below for that instead.
        if let collision {
            nameCollision = collision.name
            return
        }
        if renamed, let oldIndex = ActivityCatalog.load().firstIndex(where: { $0.id == definition.id }) {
            var aliases = ActivityCatalog.load()[oldIndex].legacyNames
            if !aliases.contains(where: { $0.caseInsensitiveCompare(previousName) == .orderedSame }) {
                aliases.append(previousName)
            }
            definition.legacyNames = aliases
        }
        commit(definition)
    }

    private func commit(_ definition: ActivityDefinition) {
        var activities = ActivityCatalog.load()
        if let index = activities.firstIndex(where: { $0.id == definition.id }) {
            activities[index] = definition
        } else {
            activities.append(definition)
        }
        guard (try? ActivityCatalog.save(activities, context: context)) != nil else { return }
        InsightsInvalidation.invalidate(reason: "Activity definition changed", context: context)
        dismiss()
    }

    /// Runs in the background so a large archive cannot stall the confirmation
    /// dialog's dismissal. The catalogue entry is only removed once the visit/place
    /// rewrite has actually finished — see `ActivityCatalog.mergeActivity` — so a
    /// failure here leaves both activities intact rather than stranding history
    /// under a definition that no longer exists.
    private func performMerge(into target: ActivityDefinition) {
        mergeTarget = nil
        guard let source = ActivityCatalog.load().first(where: { $0.id == existingID }) else { return }
        mergeInFlight = true
        let startedAt = Date.now
        Task {
            do {
                let changed = try await ActivityCatalog.mergeActivity(source, into: target, context: context)
                Diagnostics.budget(context, subsystem: "Activities", operation: "activity merge",
                                   startedAt: startedAt, budget: Diagnostics.PerformanceBudget.activityPlaceMerge,
                                   itemCount: changed)
                InsightsInvalidation.invalidate(reason: "Activities merged", context: context)
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

    private func delete() {
        var activities = ActivityCatalog.load()
        let id = existingID ?? activities.first {
            $0.name.caseInsensitiveCompare(activityName) == .orderedSame
        }?.id
        guard let id else {
            deleteFailed = true
            return
        }
        activities.removeAll { $0.id == id }
        do {
            try ActivityCatalog.save(activities, context: context)
        } catch {
            deleteFailed = true
            return
        }
        InsightsInvalidation.invalidate(reason: "Activity deleted", context: context)
        dismiss()
    }

    private var deletionWarning: String {
        "“\(activityName)” is used by \(statistics.occasions) \(statistics.occasions == 1 ? "visit" : "visits"). Deleting does not change those visits, but Insights will count them as Other until the activity exists again. Changing its group instead keeps the history counted."
    }
}

/// Picks another catalogue activity to merge the current one into. Excludes the
/// activity being merged from, and sorts alphabetically the same way the
/// Activities tab does, so the two lists read the same way.
private struct MergeTargetPicker: View {
    let excluding: UUID?
    let excludingName: String
    let onPick: (ActivityDefinition) -> Void
    @State private var search = ""

    private var candidates: [ActivityDefinition] {
        let all = ActivityCatalog.uniqueForPresentation(
            ActivityCatalog.load(),
            excludingIDs: excluding.map { Set<UUID>([$0]) } ?? Set<UUID>(),
            excludingNames: [excludingName]
        )
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if candidates.isEmpty {
                ContentUnavailableView("No other activities", systemImage: "arrow.triangle.merge",
                                       description: Text("There’s nothing else in your activity list to merge into."))
            } else {
                Section {
                    ForEach(candidates) { definition in
                        Button {
                            onPick(definition)
                        } label: {
                            HStack(spacing: 12) {
                                ActivityIcon(activity: definition.name, color: activityColor(definition.name), size: 36)
                                Text(definition.name).foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Merge into…")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Find an activity")
        .accessibilityIdentifier("merge-target-picker")
    }
}

/// Every visit currently labelled with one activity, newest first, each opening the
/// normal visit editor. Matching mirrors `Visit.activity`: an explicit choice wins,
/// and the inferred value only counts when no explicit one was made — so this list
/// always agrees with the count shown alongside it. The list itself comes from the
/// caller, already fetched and matched, rather than this view repeating the same
/// query `ActivityDetailView` just ran.
private struct ActivityVisitsView: View {
    let activityName: String
    let visits: [Visit]

    var body: some View {
        List {
            if visits.isEmpty {
                ContentUnavailableView("No visits use this", systemImage: "clock.badge.questionmark",
                                       description: Text("Nothing in your timeline is labelled “\(activityName)” right now."))
            } else {
                Section {
                    ForEach(visits) { visit in
                        NavigationLink { VisitEditor(visit: visit) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(visit.displayPlaceName).font(.headline).lineLimit(1)
                                Text(visit.arrival.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Editing one visit changes only that visit. To change them all at once, use Place History for a place, or rename the activity itself.")
                }
            }
        }
        .navigationTitle(activityName)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("activity-visits-screen")
    }
}
