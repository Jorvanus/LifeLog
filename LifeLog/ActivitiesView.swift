import SwiftUI

struct ActivitiesView: View {
    @State private var activities = ActivityCatalog.load()
    @State private var adding = false

    var body: some View {
        List {
            Section {
                ForEach(activities) { activity in
                    NavigationLink {
                        ActivityEditor(activity: activity) { updated in
                            replace(updated)
                        }
                        .accessibilityValue("Category colour \(categoryColorHex(forCategory: activity.category))")
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(activity.name).font(.headline)
                            }
                        } icon: {
                            Image(systemName: activity.symbol).foregroundStyle(activityColor(activity.name))
                        }
                    }
                }
                .onDelete { offsets in
                    activities.remove(atOffsets: offsets)
                    ActivityCatalog.save(activities)
                }
            } footer: {
                Text("Activities are suggestions used when labeling visits. Changing a definition does not rewrite past visits; edit those visits when you want a historical correction.")
            }
        }
        .navigationTitle("Activities")
        .accessibilityIdentifier("activities-screen")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Label("Add activity", systemImage: "plus") }
            }
        }
        .task { ActivityCatalog.seed(); activities = ActivityCatalog.load() }
        .sheet(isPresented: $adding) {
            ActivityEditor { newActivity in
                activities.append(newActivity)
                ActivityCatalog.save(activities)
            }
        }
    }

    private func replace(_ updated: ActivityDefinition) {
        guard let index = activities.firstIndex(where: { $0.id == updated.id }) else { return }
        activities[index] = updated
        ActivityCatalog.save(activities)
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
        _categoryColorValue = State(initialValue: categoryColor(forCategory: activity?.category ?? "Other"))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Activity name", text: $name)
                TextField("Category", text: $category)
                ColorPicker("Category colour", selection: $categoryColorValue, supportsOpacity: false)
                Picker("Icon", selection: $symbol) {
                    ForEach(iconOptions, id: \.1) { option in
                        Label(option.0, systemImage: option.1).tag(option.1)
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add Activity" : "Edit Activity")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(TextSafety.clean(name, maximumLength: 80).isEmpty)
                }
            }
        }
    }

    private func save() {
        let cleanName = TextSafety.clean(name, maximumLength: 80)
        let cleanCategory = TextSafety.clean(category, maximumLength: 40)
        let cleanSymbol = TextSafety.clean(symbol, maximumLength: 60)
        saveCategoryColor(categoryColorValue, forCategory: cleanCategory.isEmpty ? "Other" : cleanCategory)
        onSave(ActivityDefinition(id: existing?.id ?? UUID(), name: cleanName,
                                  category: cleanCategory.isEmpty ? "Other" : cleanCategory,
                                  symbol: cleanSymbol.isEmpty ? "circle.fill" : cleanSymbol))
        dismiss()
    }
}
