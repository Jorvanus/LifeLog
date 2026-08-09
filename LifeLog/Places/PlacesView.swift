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

    // The same queue Timeline shows, in the same order, so the count here and the
    // one on the Timeline header can never disagree.
    private var reviewEntries: [ReviewQueue.Entry] {
        ReviewQueue.entries(in: visits)
    }
    private var needingReview: [Visit] {
        reviewEntries.map(\.visit)
    }
    private var ignored: [Visit] {
        visits.filter { $0.isIgnored && ActivityLocationPolicy.isLocationVisit($0) }
    }

    var body: some View {
        List {
            Section("Review") {
                NavigationLink {
                    LocationVisitList(title: "Locations to Review", visits: needingReview, mode: .uncategorised)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Locations to Review").font(.headline)
                            Text(needingReview.isEmpty ? "None to review" : "\(needingReview.count) to review")
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
                NavigationLink { PlaceHistoryView() } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Place History").font(.headline)
                            Text("Correct an activity across every entry for a place")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                            .foregroundStyle(.blue)
                    }
                }
                .accessibilityIdentifier("place-history-link")
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
        _ = try? ActivityLocationPolicy.resolveAfterLocationMutation(context: context, reason: "Saved Place deletion")
        try? context.save()
        recorder.invalidateSavedPlaceCache()
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
                    mode == .uncategorised ? "Nothing to review" : "No ignored locations",
                    systemImage: mode == .uncategorised ? "checkmark.circle" : "eye",
                    description: Text(mode == .uncategorised ? "Places needing a label, or an uncertain match needing confirmation, will appear here." : "Ignored locations will appear here when you hide them."))
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
    @State private var confirmingDelete = false
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var adjustingLocation = false

    // Typing goes here, not straight into the saved place model. Writing the model
    // on every keystroke changes the store on every character typed, which triggers
    // every `@Query` watching `SavedPlace` across active views (such as `PlacesView`).
    // The model is written at the single commit point in `save()`.
    @State private var nameDraft = ""
    @State private var loadedDraft = false

    var body: some View {
        Form {
            Section("Place") {
                TextField("Name", text: $nameDraft)
            }
            Section("Map location") {
                let coordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
                MapReader { proxy in
                    Map(position: $mapPosition) {
                        Marker(nameDraft.isEmpty ? "Place" : nameDraft, coordinate: coordinate)
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
            Section {
                Button("Delete Place", role: .destructive) { confirmingDelete = true }
                    .accessibilityIdentifier("delete-place")
            } footer: {
                // At the foot of the screen and behind a question, rather than a swipe
                // on the list that a scroll can trigger by accident.
                Text("Visits already recorded here keep their name. LifeLog stops recognising the place for future visits.")
            }
        }
        .navigationTitle(nameDraft.isEmpty ? "Edit Place" : nameDraft)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let coordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
            mapPosition = .region(MKCoordinateRegion(center: coordinate,
                                                      span: .init(latitudeDelta: 0.004, longitudeDelta: 0.004)))
            if !loadedDraft {
                nameDraft = place.name
                loadedDraft = true
            }
        }
        .task { backfillPreview = try? SavedPlaceLearning.preview(place, context: context) }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { save() }
                    .disabled(TextSafety.clean(nameDraft, maximumLength: 100).isEmpty)
            }
        }
        .alert("Couldn't save place", isPresented: $saveFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("LifeLog left the existing place and timeline unchanged.")
        }
        .confirmationDialog("Delete this place?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Place", role: .destructive) {
                context.delete(place)
                try? context.save()
                recorder.invalidateSavedPlaceCache()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your timeline keeps every visit recorded here.")
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
        place.name = nameDraft
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
