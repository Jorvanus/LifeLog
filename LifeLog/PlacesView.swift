import SwiftUI
import SwiftData

struct PlacesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedPlace.name) private var places: [SavedPlace]
    // Only automatic/manual location visits can be uncategorised or ignored here;
    // journal and HealthKit rows do not belong in the Settings list.
    @Query(filter: #Predicate<Visit> { $0.source == "automatic" || $0.source == "manual" },
           sort: \Visit.arrival, order: .reverse) private var visits: [Visit]

    private var uncategorised: [Visit] {
        visits.filter { $0.needsCategorisation && !$0.isIgnored }
    }
    private var ignored: [Visit] {
        visits.filter { $0.isIgnored && ActivityLocationPolicy.isLocationVisit($0) }
    }

    var body: some View {
        List {
            Section {
                if places.isEmpty {
                    Text("No saved places yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(places) { place in
                        NavigationLink { SavedPlaceEditor(place: place) } label: {
                            HStack(spacing: 12) {
                                ActivityIcon(activity: place.defaultActivity, category: place.category,
                                             color: activityColor(place.defaultActivity))
                                    .scaleEffect(0.72).frame(width: 42, height: 42)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(place.name).font(.headline)
                                    Text("\(place.category) · \(place.defaultActivity)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete(perform: delete)
                }
            } header: {
                Text("Saved Places")
            } footer: {
                Text("Saved places recognise future visits automatically. Editing one also updates matching timeline history inside its geofence.")
            }
            Section {
                if uncategorised.isEmpty {
                    Text("No uncategorised locations.").foregroundStyle(.secondary)
                } else {
                    ForEach(uncategorised) { visit in
                        locationRow(visit)
                    }
                }
            } header: {
                Text("Uncategorised Locations")
            }
            if !ignored.isEmpty {
                Section {
                    ForEach(ignored) { visit in locationRow(visit) }
                } header: {
                    Text("Ignored Locations")
                } footer: {
                    Text("Ignored visits stay in your local data but are hidden from Timeline, Insights, and Map. Restore one to include it again.")
                }
            }
        }
        .navigationTitle("Locations")
        .accessibilityIdentifier("saved-places-screen")
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets { context.delete(places[index]) }
        try? context.save()
    }

    @ViewBuilder
    private func locationRow(_ visit: Visit) -> some View {
        HStack {
            NavigationLink { VisitEditor(visit: visit) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(visit.displayPlaceName).font(.headline)
                    Text(visit.arrival.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(visit.isIgnored ? "Restore" : "Ignore") {
                visit.isIgnored.toggle()
                try? context.save()
            }
            .font(.caption.bold())
            .buttonStyle(.bordered)
            .tint(visit.isIgnored ? .green : .orange)
            .accessibilityLabel(visit.isIgnored ? "Restore location" : "Ignore location")
        }
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

    private var availableActivities: [String] {
        let names = ActivityCatalog.load().map(\.name)
        return names.isEmpty ? activities : names
    }

    var body: some View {
        Form {
            Section("Place") {
                TextField("Name", text: $place.name)
                Picker("Place type", selection: $place.category) {
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }
            }
            Section("Default activity") {
                Picker("Activity", selection: $place.defaultActivity) {
                    Text("Choose an activity").tag("")
                    ForEach(availableActivities, id: \.self) { Text($0).tag($0) }
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
