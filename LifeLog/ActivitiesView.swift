import SwiftUI

struct ActivitiesView: View {
    @State private var activities = ActivityCatalog.load()
    @State private var adding = false
    @State private var importingFromHistory = false

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
                                Text(activity.category).font(.caption).foregroundStyle(.secondary)
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
                    activities.remove(atOffsets: offsets)
                    ActivityCatalog.save(activities)
                }
            } footer: {
                Text("Activities are suggestions used when labeling visits, and their group decides where Insights counts the time. Changing a definition does not rewrite past visits; edit those visits when you want a historical correction.")
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
        .sheet(isPresented: $importingFromHistory) {
            ActivityImportView { added in
                let known = Set(activities.map { $0.name.lowercased() })
                activities.append(contentsOf: added.filter { !known.contains($0.name.lowercased()) })
                ActivityCatalog.save(activities)
            }
        }
        .sheet(isPresented: $adding) {
            // Modal presentation supplies the navigation container, matching how
            // VisitEditor and SavedPlaceEditor are presented elsewhere.
            NavigationStack {
                ActivityEditor { newActivity in
                    activities.append(newActivity)
                    ActivityCatalog.save(activities)
                }
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
