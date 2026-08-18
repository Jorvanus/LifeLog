import SwiftUI
import SwiftData

struct ActivitiesView: View {
    @Environment(\.modelContext) private var context
    @State private var activities = ActivityCatalog.uniqueForPresentation(ActivityCatalog.load())
    @State private var adding = false
    /// How many visits carry each activity. Deleting an entry that is in use
    /// silently changes how its history is grouped, so the count has to be
    /// visible before it rather than discovered afterwards in Insights.
    @State private var usage: [String: Int] = [:]
    @State private var pendingDeletion: IndexSet?
    @State private var reader: VisitArchiveReader?
    @State private var usageTask: Task<Void, Never>?

    /// Extracted whole rather than inlined in the `ForEach`, matching how the
    /// pushed destination itself does its own editing now — renaming, deleting,
    /// colour and icon all live on `ActivityDetailView`, the same page reached
    /// from the Activities tab, rather than a second editor only this list knew
    /// about.
    @ViewBuilder
    private func row(for activity: ActivityDefinition) -> some View {
        let colourValue = categoryColorHex(forCategory: activity.category)
        NavigationLink {
            ActivityDetailView(activityName: activity.name, symbol: activity.symbol)
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
            // The bulk "Add from your history" section lived here. Adopting a label now
            // happens on the Activities tab, on the row for the label itself — where its
            // occasions and hours are visible and the decision can be made with them in
            // view. A second, blind path to the same thing from Settings was one place
            // too many once the history had been imported.
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
        .navigationTitle("Activity Labels")
        .accessibilityIdentifier("activities-screen")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Label("Add activity", systemImage: "plus") }
            }
        }
        .task {
            // Seeding itself now happens once, unconditionally, at app launch
            // (`RootView`'s `.task`) — this only needs its own local copy.
            activities = ActivityCatalog.uniqueForPresentation(ActivityCatalog.load())
            refreshUsage()
        }
        .onAppear {
            // Editing, renaming and deleting all now happen on the pushed detail
            // screen rather than through a callback back to this list, so this is
            // what picks up whatever changed there when it's popped back to.
            activities = ActivityCatalog.uniqueForPresentation(ActivityCatalog.load())
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
        .sheet(isPresented: $adding) {
            // Modal presentation supplies the navigation container, matching how
            // VisitEditor and SavedPlaceEditor are presented elsewhere.
            NavigationStack {
                ActivityEditor { newActivity in
                    activities.append(newActivity)
                    do {
                        try ActivityCatalog.save(activities, context: context)
                    } catch {
                        activities = ActivityCatalog.uniqueForPresentation(ActivityCatalog.load())
                        return
                    }
                    refreshUsage()
                }
            }
        }
    }

    private func delete(_ offsets: IndexSet) {
        activities.remove(atOffsets: offsets)
        do {
            try ActivityCatalog.save(activities, context: context)
        } catch {
            activities = ActivityCatalog.uniqueForPresentation(ActivityCatalog.load())
            return
        }
        InsightsInvalidation.invalidate(reason: "Activity deleted", context: context)
    }

    private var deletionWarning: String {
        guard let offsets = pendingDeletion else { return "" }
        let names = offsets.map { activities[$0].name }
        let total = names.reduce(0) { $0 + usageCount($1) }
        let subject = names.count == 1 ? "“\(names[0])” is" : "These activities are"
        return "\(subject) used by \(total) \(total == 1 ? "visit" : "visits"). Deleting does not change those visits, but Insights will count them as Other until the activity exists again. Changing its group instead keeps the history counted."
    }

    private func refreshUsage() {
        usageTask?.cancel()
        usageTask = Task {
            let generation = await InsightsAggregationActor.shared.currentGeneration()
            let reader = reader ?? VisitArchiveReader(modelContainer: context.container)
            self.reader = reader
            guard let counts = try? await reader.activityUsage(generation: generation) else { return }
            let currentGeneration = await InsightsAggregationActor.shared.currentGeneration()
            guard !Task.isCancelled, generation == currentGeneration else { return }
            usage = counts
        }
    }
}

/// A brand new activity only — editing an existing one happens on
/// `ActivityDetailView` now, the same page reached from the Activities tab,
/// rather than here. Nothing about creating one needs stats or history that
/// cannot exist yet, so this stays a plain, focused form.
struct ActivityEditor: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (ActivityDefinition) -> Void
    @State private var name = ""
    @State private var category = "Other"
    @State private var symbol = "circle.fill"
    @State private var categoryColorValue: Color = .gray

    init(onSave: @escaping (ActivityDefinition) -> Void) {
        self.onSave = onSave
    }

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
        }
        .navigationTitle("Add Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
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
        var definition = ActivityDefinition(id: UUID(), name: cleanName,
                                  category: cleanCategory.isEmpty ? "Other" : cleanCategory,
                                  symbol: cleanSymbol.isEmpty ? "circle.fill" : cleanSymbol)
        definition.colorHex = activityColorHex(categoryColorValue)
        onSave(definition)
        dismiss()
    }
}
