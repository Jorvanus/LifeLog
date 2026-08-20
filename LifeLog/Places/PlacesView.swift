import SwiftUI
import SwiftData
import MapKit

struct PlacesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedPlace.name) private var places: [SavedPlace]
    // Ignored locations are the only Visit models this shell keeps live. The
    // complete review queue is prepared off-main as Sendable rows below.
    @Query(filter: #Predicate<Visit> { $0.resolutionStateRaw == "ignored" },
           sort: \Visit.arrival, order: .reverse) private var visits: [Visit]
    let recorder: LocationRecorder
    @State private var reviewQueue = ReviewQueue.PreparedResult.empty
    @State private var reviewQueueLoading = true
    @State private var reviewReader: VisitArchiveReader?

    var body: some View {
        List {
            Section("Review") {
                NavigationLink {
                    LocationReviewQueueList(initialResult: reviewQueue,
                                            reader: reviewReader)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Locations to Review").font(.headline)
                            if reviewQueueLoading {
                                Text("Preparing complete queue…")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(reviewQueue.count == 0 ? "None to review" : "\(reviewQueue.count) to review")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
                    }
                }
                .accessibilityIdentifier("uncategorised-locations-link")
                NavigationLink {
                    LocationVisitList(visits: visits)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Ignored Locations").font(.headline)
                            Text(visits.isEmpty ? "None ignored" : "\(visits.count) hidden locations")
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
        .task { await loadReviewQueue() }
        .onReceive(NotificationCenter.default.publisher(for: InsightsInvalidation.notification)) { _ in
            Task { await loadReviewQueue() }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets { context.delete(places[index]) }
        let mutation = VisitMutationService.finalize(
            context: context,
            kind: .savedPlaceChange,
            change: .init(changedCount: offsets.count)
        )
        if mutation.committed { recorder.invalidateSavedPlaceCache() }
    }

    private func loadReviewQueue() async {
        let startedAt = Date.now
        let generation = InsightsAggregationActor.shared.currentGeneration()
        let reader = reviewReader ?? VisitArchiveReader(modelContainer: context.container)
        reviewReader = reader
        do {
            let prepared = try await reader.completeReviewQueue(generation: generation, now: .now)
            let currentGeneration = InsightsAggregationActor.shared.currentGeneration()
            guard !Task.isCancelled, generation == currentGeneration else { return }
            reviewQueue = prepared.result
            reviewQueueLoading = false
            Diagnostics.budget(context, subsystem: "Locations", operation: "complete review queue",
                               startedAt: startedAt,
                               budget: Diagnostics.PerformanceBudget.reviewQueuePreparation,
                               itemCount: prepared.itemCount)
        } catch is CancellationError {
            return
        } catch {
            reviewQueueLoading = false
        }
    }

}

private struct LocationReviewQueueList: View {
    @Environment(\.modelContext) private var context
    @State private var reader: VisitArchiveReader?
    @State private var result: ReviewQueue.PreparedResult
    @State private var mutationFailureMessage: String?

    init(initialResult: ReviewQueue.PreparedResult, reader: VisitArchiveReader?) {
        _reader = State(initialValue: reader)
        _result = State(initialValue: initialResult)
    }

    var body: some View {
        List {
            if result.rows.isEmpty {
                ContentUnavailableView(
                    "Nothing to review",
                    systemImage: "checkmark.circle",
                    description: Text("Places needing a label, or an uncertain match needing confirmation, will appear here.")
                )
            } else {
                ForEach(result.rows) { row in
                    HStack {
                        NavigationLink { ReviewVisitDestination(stableID: row.stableID) } label: {
                            VisitRowLabel(title: row.displayPlaceName,
                                         subtitle: row.arrival.formatted(date: .abbreviated, time: .shortened))
                        }
                        Spacer()
                        Button("Ignore") { ignore(row) }
                            .font(.caption.bold()).buttonStyle(.bordered).tint(.orange)
                    }
                }
            }
        }
        .navigationTitle("Locations to Review")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: InsightsInvalidation.notification)) { _ in
            Task { await reload() }
        }
        .alert("Couldn't update location", isPresented: Binding(
            get: { mutationFailureMessage != nil },
            set: { if !$0 { mutationFailureMessage = nil } }
        )) {
            Button("OK", role: .cancel) { mutationFailureMessage = nil }
        } message: {
            Text(mutationFailureMessage ?? "LifeLog left this location unchanged.")
        }
    }

    private func ignore(_ row: ReviewQueue.Row) {
        let stableID = row.stableID
        var descriptor = FetchDescriptor<Visit>(predicate: #Predicate { $0.stableID == stableID })
        descriptor.fetchLimit = 1
        guard let visit = try? context.fetch(descriptor).first else {
            mutationFailureMessage = "LifeLog couldn't find this location. Refresh the queue and try again."
            return
        }
        let mutation = VisitMutationService.perform(context: context, kind: .ignoreChange) {
            visit.isIgnored = true
            return .init(affectedVisit: visit)
        }
        if mutation.committed {
            result = ReviewQueue.PreparedResult(rows: result.rows.filter { $0.id != row.id })
        } else {
            mutationFailureMessage = mutation.failureDescription
                ?? "LifeLog couldn't update this location."
        }
    }

    private func reload() async {
        let generation = InsightsAggregationActor.shared.currentGeneration()
        let reader = reader ?? VisitArchiveReader(modelContainer: context.container)
        self.reader = reader
        guard let prepared = try? await reader.completeReviewQueue(generation: generation, now: .now),
              !Task.isCancelled,
              generation == InsightsAggregationActor.shared.currentGeneration() else { return }
        result = prepared.result
    }
}

struct ReviewVisitDestination: View {
    @Query private var visits: [Visit]

    init(stableID: UUID) {
        _visits = Query(filter: #Predicate { $0.stableID == stableID })
    }

    var body: some View {
        if let visit = visits.first {
            VisitEditor(visit: visit)
        } else {
            ContentUnavailableView("Location unavailable", systemImage: "mappin.slash",
                                   description: Text("This location may have been changed or removed."))
        }
    }
}

private struct LocationVisitList: View {
    let visits: [Visit]
    @Environment(\.modelContext) private var context
    @State private var mutationFailureMessage: String?

    var body: some View {
        List {
            if visits.isEmpty {
                ContentUnavailableView(
                    "No ignored locations",
                    systemImage: "eye",
                    description: Text("Ignored locations will appear here when you hide them."))
            } else {
                ForEach(visits) { visit in
                    HStack {
                        NavigationLink { VisitEditor(visit: visit) } label: {
                            VisitRowLabel(title: visit.displayPlaceName,
                                         subtitle: visit.arrival.formatted(date: .abbreviated, time: .shortened))
                        }
                        Spacer()
                        Button("Restore") {
                            let result = VisitMutationService.perform(context: context, kind: .ignoreChange) {
                                visit.isIgnored = false
                                return .init(affectedVisit: visit)
                            }
                            if !result.committed {
                                mutationFailureMessage = result.failureDescription
                                    ?? "LifeLog couldn't update this location."
                            }
                        }
                        .font(.caption.bold()).buttonStyle(.bordered)
                        .tint(.green)
                    }
                }
            }
        }
        .navigationTitle("Ignored Locations")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn't update location", isPresented: Binding(
            get: { mutationFailureMessage != nil },
            set: { if !$0 { mutationFailureMessage = nil } }
        )) {
            Button("OK", role: .cancel) { mutationFailureMessage = nil }
        } message: {
            Text(mutationFailureMessage ?? "LifeLog left this location unchanged.")
        }
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

    // Same reasoning, extended to the fields that used to write straight into
    // `place`: a map tap set `place.latitude`/`longitude` immediately, the radius
    // slider and the activity picker were bound to `place` directly. None of that
    // waited for Done -- leaving by the back button still kept it, so there was
    // no way to back out of an accidental pin move or slider drag.
    @State private var latitudeDraft: Double = 0
    @State private var longitudeDraft: Double = 0
    @State private var radiusDraft: Double = 100
    @State private var defaultActivityDraft = ""
    @State private var roleDraft: SavedPlaceRole?

    var body: some View {
        Form {
            Section("Place") {
                TextField("Name", text: $nameDraft)
            }
            Section {
                Picker("Role", selection: $roleDraft) {
                    Text("None").tag(SavedPlaceRole?.none)
                    Text("Home").tag(SavedPlaceRole?.some(.home))
                    Text("Work").tag(SavedPlaceRole?.some(.work))
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("saved-place-role-picker")
            } footer: {
                Text("Home and Work are used for commute detection and travel labelling — a fact you set, not a guess from the name. Renaming this place afterwards keeps the role.")
            }
            Section("Map location") {
                let coordinate = CLLocationCoordinate2D(latitude: latitudeDraft, longitude: longitudeDraft)
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
                        latitudeDraft = updated.latitude
                        longitudeDraft = updated.longitude
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
                    PlaceActivitySelection(selection: $defaultActivityDraft)
                } label: {
                    LabeledContent("Activity", value: defaultActivityDraft.isEmpty ? "Choose an activity" : defaultActivityDraft)
                }
            }
            Section {
                Slider(value: $radiusDraft, in: 25...500, step: 25)
                LabeledContent("Recognition radius", value: "\(Int(radiusDraft)) m")
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
            if !loadedDraft {
                nameDraft = place.name
                latitudeDraft = place.latitude
                longitudeDraft = place.longitude
                radiusDraft = place.radius
                defaultActivityDraft = place.defaultActivity
                roleDraft = place.homeWorkRole
                loadedDraft = true
            }
            let coordinate = CLLocationCoordinate2D(latitude: latitudeDraft, longitude: longitudeDraft)
            mapPosition = .region(MKCoordinateRegion(center: coordinate,
                                                      span: .init(latitudeDelta: 0.004, longitudeDelta: 0.004)))
        }
        .task { backfillPreview = try? SavedPlaceLearning.preview(place, context: context) }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
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
                let result = VisitMutationService.perform(context: context, kind: .savedPlaceChange) {
                    context.delete(place)
                    return .init()
                }
                if result.committed {
                    recorder.invalidateSavedPlaceCache()
                    dismiss()
                } else {
                    saveFailed = true
                }
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
        place.latitude = latitudeDraft
        place.longitude = longitudeDraft
        place.radius = radiusDraft
        place.defaultActivity = defaultActivityDraft
        place.homeWorkRole = roleDraft
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
