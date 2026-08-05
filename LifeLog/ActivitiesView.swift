import SwiftUI
import SwiftData

struct ActivitiesView: View {
    @Environment(\.modelContext) private var context
    @State private var activities = ActivityCatalog.load()
    @State private var adding = false
    @State private var importingFromHistory = false
    /// How many visits carry each activity. Deleting or renaming an entry that is
    /// in use silently changes how its history is grouped, so the count has to be
    /// visible before either action rather than discovered afterwards in Insights.
    @State private var usage: [String: Int] = [:]
    @State private var pendingDeletion: IndexSet?
    @State private var renameRequest: RenameRequest?
    @State private var renameFailed = false

    struct RenameRequest: Identifiable {
        let previousName: String
        let updated: ActivityDefinition
        let count: Int
        /// Set when the new name already belongs to another activity. Renaming into
        /// an existing name is a merge, not a rename: without this the list would
        /// hold two entries with the same name, and grouping would then depend on
        /// which happened to come first in the array.
        let mergesInto: ActivityDefinition?
        var id: String { previousName }
    }

    /// Extracted whole rather than inlined in the `ForEach`: with the editor's extra
    /// callback the row body grew past what the type-checker would solve.
    @ViewBuilder
    private func row(for activity: ActivityDefinition) -> some View {
        let colourValue = categoryColorHex(forCategory: activity.category)
        NavigationLink {
            ActivityEditor(activity: activity,
                           usageCount: usageCount(activity.name),
                           onSave: { updated in replace(updated) },
                           onDelete: { requestDeletion(of: $0) })
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.name).font(.headline)
                    Text(subtitle(for: activity))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: activity.symbol).foregroundStyle(activityColor(activity.name))
            }
        }
        // Belongs on the row, not the pushed destination, so the colour is announced
        // while moving through the list.
        .accessibilityValue("Category colour \(colourValue)")
    }

    /// Extracted from the row: inline, the interpolation plus its two ternaries was
    /// enough for the type-checker to give up on the whole label expression.
    private func subtitle(for activity: ActivityDefinition) -> String {
        let count = usageCount(activity.name)
        guard count > 0 else { return activity.category }
        return "\(activity.category) · \(count) \(count == 1 ? "visit" : "visits")"
    }

    private func usageCount(_ name: String) -> Int {
        usage[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] ?? 0
    }

    var body: some View {
        List {
            Section {
                Button {
                    importingFromHistory = true
                } label: {
                    Label("Add from your history", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
                .accessibilityIdentifier("add-from-history")
            } footer: {
                Text("Activities you have recorded but never added here are counted as “Other” in Insights.")
            }
            Section {
                ForEach(activities) { activity in
                    row(for: activity)
                }
                .onDelete { offsets in
                    // Deleting an activity never edits a visit, but it does remove the
                    // only thing telling Insights how to group that label, so history
                    // quietly falls into "Other". Confirm when anything is using it.
                    let inUse = offsets.contains { usageCount(activities[$0].name) > 0 }
                    if inUse { pendingDeletion = offsets } else { delete(offsets) }
                }
            } footer: {
                Text("The group decides where Insights counts the time, and changing it re-counts existing visits straight away. Deleting an activity leaves its visits labelled but ungrouped; renaming one offers to bring its visits with it.")
            }
        }
        .navigationTitle("Activities")
        .accessibilityIdentifier("activities-screen")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Label("Add activity", systemImage: "plus") }
            }
        }
        .task {
            ActivityCatalog.seed()
            activities = ActivityCatalog.load()
            refreshUsage()
        }
        .alert("The visits kept the old name", isPresented: $renameFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The activity was renamed, but its visits could not be written just now. Rename it again to bring them across.")
        }
        .confirmationDialog("Delete activity?", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } })
        ) {
            Button("Delete anyway", role: .destructive) {
                if let offsets = pendingDeletion { delete(offsets) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(deletionWarning)
        }
        .confirmationDialog(renameTitle, isPresented: Binding(
            get: { renameRequest != nil },
            set: { if !$0 { renameRequest = nil } })
        ) {
            if let request = renameRequest {
                if request.mergesInto != nil {
                    Button("Merge into “\(request.updated.name)”") {
                        applyRename(request, updatingVisits: true)
                    }
                } else {
                    Button("Rename \(request.count) \(request.count == 1 ? "visit" : "visits")") {
                        applyRename(request, updatingVisits: true)
                    }
                    Button("Leave visits as they are") {
                        applyRename(request, updatingVisits: false)
                    }
                }
                Button("Cancel", role: .cancel) { renameRequest = nil }
            }
        } message: {
            if let request = renameRequest {
                if request.mergesInto != nil {
                    Text("“\(request.updated.name)” already exists. Merging moves \(request.count) \(request.count == 1 ? "visit" : "visits") onto it and removes the duplicate, so the list keeps one entry per activity.")
                } else {
                    Text("\(request.count) \(request.count == 1 ? "visit is" : "visits are") labelled “\(request.previousName)”. Left alone they keep the old label and Insights counts them as Other.")
                }
            }
        }
        .sheet(isPresented: $importingFromHistory) {
            ActivityImportView { added in
                let known = Set(activities.map { $0.name.lowercased() })
                activities.append(contentsOf: added.filter { !known.contains($0.name.lowercased()) })
                ActivityCatalog.save(activities)
                refreshUsage()
            }
        }
        .sheet(isPresented: $adding) {
            // Modal presentation supplies the navigation container, matching how
            // VisitEditor and SavedPlaceEditor are presented elsewhere.
            NavigationStack {
                ActivityEditor { newActivity in
                    activities.append(newActivity)
                    ActivityCatalog.save(activities)
                    refreshUsage()
                }
            }
        }
    }

    private func replace(_ updated: ActivityDefinition) {
        guard let index = activities.firstIndex(where: { $0.id == updated.id }) else { return }
        let previousName = activities[index].name
        let renamed = previousName.caseInsensitiveCompare(updated.name) != .orderedSame
        let affected = usageCount(previousName)
        // A rename leaves every existing visit holding the old wording, orphaned from
        // the catalogue. Offer to carry them across rather than silently stranding them.
        let collision = activities.first {
            $0.id != updated.id && $0.name.caseInsensitiveCompare(updated.name) == .orderedSame
        }
        if renamed, affected > 0 || collision != nil {
            renameRequest = RenameRequest(previousName: previousName, updated: updated,
                                          count: affected, mergesInto: collision)
            return
        }
        activities[index] = updated
        // Re-sorted here, not only in storage: the rows are driven by this array, and
        // a renamed activity has to move to its new place immediately. Swipe-to-delete
        // offsets index the same array, so display and storage order must not diverge.
        activities = ActivityCatalog.sorted(activities)
        ActivityCatalog.save(activities)
        InsightsInvalidation.invalidate(reason: "Activity definition changed", context: context)
    }

    private func applyRename(_ request: RenameRequest, updatingVisits: Bool) {
        defer { renameRequest = nil }
        guard let index = activities.firstIndex(where: { $0.id == request.updated.id }) else { return }
        if let target = request.mergesInto {
            // Keep the entry that was already there, with its group and colour, and
            // drop the one being renamed onto it.
            activities.remove(at: index)
            _ = target
        } else {
            activities[index] = request.updated
        }
        activities = ActivityCatalog.sorted(activities)
        ActivityCatalog.save(activities)
        if updatingVisits {
            do {
                _ = try ActivityCatalog.renameActivity(from: request.previousName,
                                                       to: request.updated.name, context: context)
            } catch {
                // The catalogue entry is renamed either way, so staying silent would
                // leave every visit behind under the old label while the screen said
                // they had come across — the exact stranding this option prevents.
                renameFailed = true
            }
        }
        refreshUsage()
        InsightsInvalidation.invalidate(reason: "Activity renamed", context: context)
    }

    private func requestDeletion(of definition: ActivityDefinition) {
        guard let index = activities.firstIndex(where: { $0.id == definition.id }) else { return }
        let offsets = IndexSet(integer: index)
        if usageCount(definition.name) > 0 { pendingDeletion = offsets } else { delete(offsets) }
    }

    private func delete(_ offsets: IndexSet) {
        activities.remove(atOffsets: offsets)
        ActivityCatalog.save(activities)
        InsightsInvalidation.invalidate(reason: "Activity deleted", context: context)
    }

    private var renameTitle: String {
        renameRequest?.mergesInto == nil ? "Rename its visits too?" : "Merge these activities?"
    }

    private var deletionWarning: String {
        guard let offsets = pendingDeletion else { return "" }
        let names = offsets.map { activities[$0].name }
        let total = names.reduce(0) { $0 + usageCount($1) }
        let subject = names.count == 1 ? "“\(names[0])” is" : "These activities are"
        return "\(subject) used by \(total) \(total == 1 ? "visit" : "visits"). Deleting does not change those visits, but Insights will count them as Other until the activity exists again. Changing its group instead keeps the history counted."
    }

    private func refreshUsage() {
        let visits = (try? context.fetch(FetchDescriptor<Visit>())) ?? []
        var counts: [String: Int] = [:]
        for visit in visits {
            let key = visit.activity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            counts[key, default: 0] += 1
        }
        usage = counts
    }
}

struct ActivityEditor: View {
    @Environment(\.dismiss) private var dismiss
    let existing: ActivityDefinition?
    let usageCount: Int
    let onSave: (ActivityDefinition) -> Void
    /// Set only when editing, so an activity can be removed from the screen that
    /// shows what removing it would cost rather than only by swiping the list.
    let onDelete: ((ActivityDefinition) -> Void)?
    @State private var name: String
    @State private var category: String
    @State private var symbol: String
    @State private var categoryColorValue: Color

    init(activity: ActivityDefinition? = nil, usageCount: Int = 0,
         onSave: @escaping (ActivityDefinition) -> Void,
         onDelete: ((ActivityDefinition) -> Void)? = nil) {
        existing = activity
        self.usageCount = usageCount
        self.onSave = onSave
        self.onDelete = onDelete
        _name = State(initialValue: activity?.name ?? "")
        _category = State(initialValue: activity?.category ?? "Other")
        _symbol = State(initialValue: activity?.symbol ?? "circle.fill")
        _categoryColorValue = State(initialValue: activity.map { activityColor($0.name) } ?? .gray)
    }

    // Adding is always presented modally and editing is always pushed, so this
    // also decides whether an explicit Cancel button is needed alongside the
    // navigation stack's own back button.
    private var isModal: Bool { existing == nil }


    var body: some View {
        Form {
            TextField("Activity name", text: $name)
            ColorPicker("Activity colour", selection: $categoryColorValue, supportsOpacity: false)
            Picker("Group under", selection: $category) {
                ForEach(ActivityCatalog.categories, id: \.self) { Text($0).tag($0) }
            }
            NavigationLink {
                ActivityIconPicker(symbol: $symbol, tint: categoryColorValue)
            } label: {
                LabeledContent("Icon") {
                    Image(systemName: symbol).foregroundStyle(categoryColorValue)
                }
            }
            .accessibilityIdentifier("activity-icon-link")
            // The count on the list was a dead end: it said how much history an
            // edit would affect without letting any of it be inspected or fixed.
            if let existing, usageCount > 0 {
                Section {
                    NavigationLink {
                        ActivityVisitsView(activityName: existing.name)
                    } label: {
                        LabeledContent("History", value: "\(usageCount) \(usageCount == 1 ? "visit" : "visits")")
                    }
                    .accessibilityIdentifier("activity-visits-link")
                } footer: {
                    Text("Open to review them, or correct one on its own without changing the rest.")
                }
                ActivityUsageSummary(activityName: existing.name)
            }
            if let existing, let onDelete {
                Section {
                    Button("Delete Activity", role: .destructive) {
                        dismiss()
                        onDelete(existing)
                    }
                    .accessibilityIdentifier("delete-activity")
                } footer: {
                    Text(usageCount > 0
                         ? "Its visits keep their label, but Insights counts them as “Other” until an activity with this name exists again."
                         : "Nothing in your timeline uses this activity.")
                }
            }
        }
        .navigationTitle(isModal ? "Add Activity" : "Edit Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isModal {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(TextSafety.clean(name, maximumLength: 80).isEmpty)
            }
        }
    }

    private func save() {
        let cleanName = TextSafety.clean(name, maximumLength: 80)
        let cleanCategory = TextSafety.clean(category, maximumLength: 40)
        let cleanSymbol = TextSafety.clean(symbol, maximumLength: 60)
        saveActivityColor(categoryColorValue, forActivity: cleanName)
        var definition = ActivityDefinition(id: existing?.id ?? UUID(), name: cleanName,
                                  category: cleanCategory.isEmpty ? "Other" : cleanCategory,
                                  symbol: cleanSymbol.isEmpty ? "circle.fill" : cleanSymbol)
        definition.colorHex = activityColorHex(categoryColorValue)
        onSave(definition)
        dismiss()
    }
}


/// Every visit currently labelled with one activity, newest first, each opening the
/// normal visit editor. Matching mirrors `Visit.activity`: an explicit choice wins,
/// and the inferred value only counts when no explicit one was made — so this list
/// always agrees with the count shown alongside it.
private struct ActivityVisitsView: View {
    let activityName: String
    @Query private var candidates: [Visit]

    init(activityName: String) {
        self.activityName = activityName
        let name = activityName
        // SwiftData cannot filter on `activity` because it is computed, so the fetch
        // is deliberately loose and narrowed below rather than duplicating the rule.
        _candidates = Query(
            filter: #Predicate<Visit> { $0.userActivity == name || $0.inferredActivity == name },
            sort: [SortDescriptor(\Visit.arrival, order: .reverse)]
        )
    }

    private var visits: [Visit] {
        let key = activityName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return candidates.filter {
            $0.activity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
        }
    }

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
