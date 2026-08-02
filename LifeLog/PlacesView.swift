import SwiftUI
import SwiftData

struct PlacesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedPlace.name) private var places: [SavedPlace]

    var body: some View {
        List {
            if places.isEmpty {
                ContentUnavailableView {
                    Label("No saved places", systemImage: "house.and.flag")
                } description: {
                    Text("Open your current location from Timeline or Settings, label it, then tap Save & Learn Place.")
                }
            } else {
                Section {
                    ForEach(places) { place in
                        NavigationLink { SavedPlaceEditor(place: place) } label: {
                            HStack(spacing: 12) {
                                ActivityIcon(
                                    activity: place.defaultActivity,
                                    category: place.category,
                                    color: activityColor(place.defaultActivity)
                                )
                                .scaleEffect(0.72)
                                .frame(width: 42, height: 42)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(place.name).font(.headline)
                                    Text("\(place.category) · \(place.defaultActivity)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete(perform: delete)
                } footer: {
                    Text("Saved places recognise future visits automatically. Editing one also updates matching timeline history inside its geofence.")
                }
            }
        }
        .navigationTitle("Saved Places")
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets { context.delete(places[index]) }
        try? context.save()
    }
}

private struct SavedPlaceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Bindable var place: SavedPlace
    @State private var saveFailed = false

    private let categories = [
        "Home", "Work", "Food & Drink", "Shopping", "Fitness", "Healthcare",
        "Education", "Travel", "Social", "Other"
    ]
    private let activities = [
        "At home", "Working", "Eating", "Shopping", "Exercising", "Healthcare",
        "Studying", "Travelling", "Socialising", "Visiting"
    ]

    var body: some View {
        Form {
            Section("Place") {
                TextField("Name", text: $place.name)
                Picker("Type", selection: $place.category) {
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }
            }
            Section("Default activity") {
                Picker("Activity", selection: $place.defaultActivity) {
                    Text("Choose an activity").tag("")
                    ForEach(activities, id: \.self) { Text($0).tag($0) }
                }
                TextField("Or enter your own", text: $place.defaultActivity)
            }
            Section {
                Slider(value: $place.radius, in: 25...500, step: 25)
                LabeledContent("Recognition radius", value: "\(Int(place.radius)) m")
            } header: {
                Text("Geofence")
            } footer: {
                Text("Use a larger radius for large properties and a smaller radius where nearby places overlap.")
            }
        }
        .navigationTitle(place.name.isEmpty ? "Edit Place" : place.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { save() }
                    .disabled(TextSafety.clean(place.name, maximumLength: 100).isEmpty)
            }
        }
        .alert("Couldn’t save place", isPresented: $saveFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("LifeLog left the existing place and timeline unchanged.")
        }
    }

    private func save() {
        do {
            try SavedPlaceLearning.apply(place, context: context)
            try context.save()
            dismiss()
        } catch {
            saveFailed = true
        }
    }
}
