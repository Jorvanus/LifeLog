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
                    NavigationLink {
                        ActivityEditor(activity: activity) { updated in
                            replace(updated)
                        }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(activity.name).font(.headline)
                                Text(usageCount(activity.name) > 0
                                     ? "\(activity.category) · \(usageCount(activity.name)) \(usageCount(activity.name) == 1 ? "visit" : "visits")"
                                     : activity.category)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: activity.symbol).foregroundStyle(activityColor(activity.name))
                        }
                    }
                    // Belongs on the row, not the pushed destination, so the colour
                    // is announced while moving through the list.
                    .accessibilityValue("Category colour \(categoryColorHex(forCategory: activity.category))")
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
        ActivityCatalog.save(activities)
        if updatingVisits {
            try? ActivityCatalog.renameActivity(from: request.previousName,
                                                to: request.updated.name, context: context)
        }
        refreshUsage()
        InsightsInvalidation.invalidate(reason: "Activity renamed", context: context)
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
    let onSave: (ActivityDefinition) -> Void
    @State private var name: String
    @State private var category: String
    @State private var symbol: String
    @State private var categoryColorValue: Color

    private let iconOptions = [
        ("Home", "house.fill"), ("Work", "briefcase.fill"),
        ("Food", "fork.knife"), ("Shopping", "bag.fill"),
        ("Fitness", "figure.run"), ("Health", "cross.case.fill"),
        ("Study", "book.fill"), ("Travel", "car.fill"),
        ("Social", "person.2.fill"), ("Place", "mappin.and.ellipse")
    ]

    init(activity: ActivityDefinition? = nil, onSave: @escaping (ActivityDefinition) -> Void) {
        existing = activity
        self.onSave = onSave
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
            Picker("Icon", selection: $symbol) {
                ForEach(iconOptions, id: \.1) { option in
                    Label(option.0, systemImage: option.1).tag(option.1)
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
