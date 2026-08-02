import SwiftUI
import SwiftData

struct ActivitiesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ActivityDefinition.name) private var activities: [ActivityDefinition]
    @State private var adding = false

    var body: some View {
        List {
            Section {
                ForEach(activities) { activity in
                    NavigationLink { ActivityEditor(activity: activity) } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(activity.name).font(.headline)
                                Text(activity.category).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: activity.symbol).foregroundStyle(activityColor(activity.name))
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { context.delete(activities[index]) }
                    try? context.save()
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
        .task { ActivityCatalog.seed(context) }
        .sheet(isPresented: $adding) { ActivityEditor() }
    }
}

private struct ActivityEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let existing: ActivityDefinition?
    @State private var name: String
    @State private var category: String
    @State private var symbol: String

    init(activity: ActivityDefinition? = nil) {
        existing = activity
        _name = State(initialValue: activity?.name ?? "")
        _category = State(initialValue: activity?.category ?? "Other")
        _symbol = State(initialValue: activity?.symbol ?? "circle.fill")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Activity name", text: $name)
                TextField("Category", text: $category)
                TextField("SF Symbol", text: $symbol)
                Text("Use any SF Symbol name, such as figure.walk or cup.and.saucer.fill.")
                    .font(.footnote).foregroundStyle(.secondary)
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
        if let existing {
            existing.name = cleanName
            existing.category = cleanCategory.isEmpty ? "Other" : cleanCategory
            existing.symbol = cleanSymbol.isEmpty ? "circle.fill" : cleanSymbol
        } else {
            context.insert(ActivityDefinition(name: cleanName,
                                              category: cleanCategory.isEmpty ? "Other" : cleanCategory,
                                              symbol: cleanSymbol.isEmpty ? "circle.fill" : cleanSymbol))
        }
        try? context.save()
        dismiss()
    }
}
