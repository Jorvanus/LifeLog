import SwiftUI
import SwiftData
import MapKit

struct PlacesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedPlace.name) private var places: [SavedPlace]
    // Only automatic/manual location visits can be uncategorised or ignored here;
    // journal and HealthKit rows do not belong in the Settings list.
    @Query(filter: #Predicate<Visit> { $0.source == "automatic" || $0.source == "manual" },
           sort: \Visit.arrival, order: .reverse) private var visits: [Visit]
    let recorder: LocationRecorder

    private var uncategorised: [Visit] {
        visits.filter { $0.needsCategorisation && !$0.isIgnored }
    }
    private var ignored: [Visit] {
        visits.filter { $0.isIgnored && ActivityLocationPolicy.isLocationVisit($0) }
    }

    var body: some View {
        List {
            Section("Review") {
                NavigationLink {
                    LocationVisitList(title: "Uncategorised Locations", visits: uncategorised, mode: .uncategorised)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Uncategorised Locations").font(.headline)
                            Text(uncategorised.isEmpty ? "None to review" : "\(uncategorised.count) to categorise")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
                    }
                }
                .accessibilityIdentifier("uncategorised-locations-link")
                NavigationLink {
                    LocationVisitList(title: "Ignored Locations", visits: ignored, mode: .ignored)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Ignored Locations").font(.headline)
                            Text(ignored.isEmpty ? "None ignored" : "\(ignored.count) hidden locations")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "eye.slash.fill").foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("ignored-locations-link")
            }
            Section {
                if places.isEmpty {
                    Text("No saved places yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(places) { place in
                        NavigationLink { SavedPlaceEditor(place: place, recorder: recorder) } label: {
                            HStack(spacing: 12) {
                                ActivityIcon(activity: place.defaultActivity, context: place.name,
                                             color: activityColor(place.defaultActivity), size: 42)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(place.name).font(.headline)
                                    Text(place.defaultActivity.isEmpty ? "No default activity" : place.defaultActivity)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityValue("Activity colour")
                    }
                    .onDelete(perform: delete)
                }
            } header: {
                Text("All locations")
            } footer: {
                Text("Saved places recognise future visits automatically. Editing one also updates matching timeline history inside its geofence.")
            }
        }
        .navigationTitle("Locations")
        .accessibilityIdentifier("saved-places-screen")
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets { context.delete(places[index]) }
        try? context.save()
        recorder.invalidateSavedPlaceCache()
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

private struct LocationVisitList: View {
    enum Mode { case uncategorised, ignored }
    let title: String
    let visits: [Visit]
    let mode: Mode
    @Environment(\.modelContext) private var context

    var body: some View {
        List {
            if visits.isEmpty {
                ContentUnavailableView(
                    mode == .uncategorised ? "No uncategorised locations" : "No ignored locations",
                    systemImage: mode == .uncategorised ? "checkmark.circle" : "eye",
                    description: Text(mode == .uncategorised ? "New locations needing a label will appear here." : "Ignored locations will appear here when you hide them."))
            } else {
                ForEach(visits) { visit in
                    HStack {
                        NavigationLink { VisitEditor(visit: visit) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(visit.displayPlaceName).font(.headline)
                                Text(visit.arrival.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(mode == .ignored ? "Restore" : "Ignore") {
                            visit.isIgnored = mode != .ignored
                            try? context.save()
                        }
                        .font(.caption.bold()).buttonStyle(.bordered)
                        .tint(mode == .ignored ? .green : .orange)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SavedPlaceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Bindable var place: SavedPlace
    let recorder: LocationRecorder
    @State private var saveFailed = false
    @State private var backfillPreview: SavedPlaceLearning.BackfillPreview?
    @State private var confirmingIgnore = false
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var adjustingLocation = false

    var body: some View {
        Form {
            Section("Place") {
                TextField("Name", text: $place.name)
            }
            Section("Map location") {
                let coordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
                MapReader { proxy in
                    Map(position: $mapPosition) {
                        Marker(place.name, coordinate: coordinate)
                            .tint(adjustingLocation ? .orange : .blue)
                    }
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .mapControls { MapCompass(); MapUserLocationButton() }
                    .onTapGesture(coordinateSpace: .local) { point in
                        guard adjustingLocation,
                              let updated = proxy.convert(point, from: .local),
                              CLLocationCoordinate2DIsValid(updated) else { return }
                        place.latitude = updated.latitude
                        place.longitude = updated.longitude
                        mapPosition = .region(MKCoordinateRegion(center: updated,
                                                                  span: .init(latitudeDelta: 0.004, longitudeDelta: 0.004)))
                    }
                }
                .accessibilityIdentifier("saved-place-map-picker")
                Text(adjustingLocation ? "Tap the map to move the pin, then finish adjusting." : "Tap Adjust pin to choose a new location.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    adjustingLocation.toggle()
                } label: {
                    Label(adjustingLocation ? "Finish adjusting pin" : "Adjust pin location",
                          systemImage: adjustingLocation ? "checkmark.circle" : "mappin.and.ellipse")
                }
            }
            if let backfillPreview, backfillPreview.matchingVisits > 0 {
                Section("Historical backfill") {
                    Label(backfillPreview.description, systemImage: "arrow.triangle.2.circlepath")
                    Text("Saving changes updates matching history. Corrections are recorded for recovery.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Ignore all matching visits", role: .destructive) { confirmingIgnore = true }
                }
            }
            Section("Default activity") {
                NavigationLink {
                    PlaceActivitySelection(selection: $place.defaultActivity)
                } label: {
                    LabeledContent("Activity", value: place.defaultActivity.isEmpty ? "Choose an activity" : place.defaultActivity)
                }
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
        .onAppear {
            let coordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
            mapPosition = .region(MKCoordinateRegion(center: coordinate,
                                                      span: .init(latitudeDelta: 0.004, longitudeDelta: 0.004)))
        }
        .task { backfillPreview = try? SavedPlaceLearning.preview(place, context: context) }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { save() }
                    .disabled(TextSafety.clean(place.name, maximumLength: 100).isEmpty)
            }
        }
        .alert("Couldn't save place", isPresented: $saveFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("LifeLog left the existing place and timeline unchanged.")
        }
        .confirmationDialog("Ignore matching visits?", isPresented: $confirmingIgnore) {
            Button("Ignore \(backfillPreview?.matchingVisits ?? 0) visits", role: .destructive) {
                do {
                    _ = try SavedPlaceLearning.applyIgnored(true, to: place, context: context)
                    recorder.invalidateSavedPlaceCache()
                    backfillPreview = try SavedPlaceLearning.preview(place, context: context)
                } catch {
                    saveFailed = true
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This hides matching visits from Timeline, Insights, and Map. You can restore them from Ignored Locations.")
        }
    }

    private func save() {
        do {
            try SavedPlaceLearning.apply(place, context: context)
            try context.save()
            recorder.invalidateSavedPlaceCache()
            dismiss()
        } catch {
            saveFailed = true
        }
    }
}
