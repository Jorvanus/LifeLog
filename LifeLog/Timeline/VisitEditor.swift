import SwiftUI
import SwiftData
import MapKit
import CoreLocation

/// Editing one visit: its place, activity, times and note, the nearby Apple Maps
/// alternatives, and the correction history behind it.

struct VisitEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Bindable var visit: Visit
    @Query(sort: \VisitCorrection.changedAt, order: .reverse) private var corrections: [VisitCorrection]
    @State private var saveFailed = false
    @State private var confirmingDelete = false
    @State private var confirmingDeleteSplit = false
    @State private var correctionBaseline: VisitCorrectionSnapshot?
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var adjustingLocation = false
    @State private var showingNearbyPlaces = false

    // Typing goes here, not straight into the visit. Writing the model on every
    // keystroke changed the store on every keystroke, and every `@Query` in the app
    // — this screen's own, and the Timeline still mounted behind it — re-fetched in
    // response. The place field was unusable on a full archive because of it. The
    // model is written at the one point that already existed for it, `sanitizeVisit`.
    @State private var placeNameDraft = ""
    @State private var activityDraft = ""
    @State private var noteDraft = ""
    @State private var loadedDrafts = false

    // Read once on appear rather than derived in `body`. Both were recomputed on
    // every evaluation: the catalogue is a JSON decode and a localised sort, and the
    // visits here used to be filtered out of a `@Query` holding the whole archive.
    @State private var catalogue: [ActivityDefinition] = []
    @State private var visitsHere: [Visit] = []

    // For a record with no position of its own, the places either side of it.
    @State private var neighbours = SurroundingStays.Neighbours()
    @State private var contextPosition: MapCameraPosition = .automatic

    // Saved Places near enough to explain this one, read once rather than derived.
    @State private var nearbySavedPlaces: [SavedPlace] = []

    private let activities = ["At home", "Working", "Eating", "Shopping", "Exercising", "Healthcare", "Studying", "Travelling", "Socialising", "Visiting"]

    private var availableActivities: [String] {
        let names = catalogue.map(\.name)
        return names.isEmpty ? activities : names
    }

    var body: some View {
        Form {
            if visit.needsCategorisation {
                Section {
                    Label("This place isn’t recognised yet", systemImage: "questionmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Categorise it once and LifeLog will recognise this location next time.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if canLearnPlace {
                    Section("Quick labels") {
                        Button {
                            applyQuickLabel(name: "Home", activity: "At home")
                        } label: {
                            Label("Set as Home", systemImage: "house.fill")
                        }
                        Button {
                            applyQuickLabel(name: "Work", activity: "Working")
                        } label: {
                            Label("Set as Work", systemImage: "building.2.fill")
                        }
                    }
                }
            }
            if visit.needsCategorisation && !visit.placeSuggestions.isEmpty {
                Section {
                    ForEach(visit.placeSuggestions) { suggestion in
                        Button {
                            select(suggestion)
                        } label: {
                            HStack(spacing: 12) {
                                ActivityIcon(activity: suggestion.suggestedActivity, context: suggestion.name,
                                             color: activityColor(suggestion.suggestedActivity), size: 42)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(suggestion.name).foregroundStyle(.primary)
                                    Text("\(suggestion.suggestedActivity) · \(Int(suggestion.distance.rounded())) m away")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                } header: {
                    Text("Nearby places")
                } footer: {
                    Text("Suggestions are nearby public places from Apple Maps.")
                }
            }
            if visit.hasRoute {
                Section {
                    Map(position: $mapPosition) {
                        MapPolyline(coordinates: visit.route.map(\.coordinate))
                            .stroke(activityColor(visit.activity), lineWidth: 4)
                    }
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .mapControls { MapCompass() }
                    .accessibilityIdentifier("visit-route-map")
                    Text(routeSummary)
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("Journey")
                } footer: {
                    // Said plainly, because this is the most precise location data
                    // LifeLog holds and the person should know it is here.
                    Text("The path this walk followed, recorded by Apple Health.")
                }
            }
            // Only where there would otherwise be no map at all, and only for a
            // genuine device recording — a manually typed place with no coordinate
            // yet gets the editable map below instead, not this read-only context.
            if showsNeighbourContextInsteadOfMap, neighbours.before != nil || neighbours.after != nil {
                Section {
                    Map(position: $contextPosition) {
                        if let before = neighbours.before {
                            Marker("Before: \(before.displayPlaceName)", systemImage: "figure.stand",
                                   coordinate: before.coordinate)
                                .tint(.green)
                        }
                        if let after = neighbours.after {
                            Marker("After: \(after.displayPlaceName)", systemImage: "mappin",
                                   coordinate: after.coordinate)
                                .tint(.orange)
                        }
                    }
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .mapControls { MapCompass() }
                    .accessibilityIdentifier("visit-context-map")
                    Text(surroundingSummary)
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("Where this happened")
                } footer: {
                    // Said plainly rather than dressed up. The pins are not this entry's
                    // position — LifeLog has none for it — they are the places either
                    // side of it, which is what makes a wrong one recognisable.
                    Text("This entry came from Apple Health, which records movement without a location, so LifeLog has no position for it. These are the places recorded either side of it.")
                }
            }
            // Shown for every stay with no route, except the one case the section
            // above already owns: a genuine device recording with no location at all,
            // where a precise pin would be invented rather than corrected. Anything
            // else without a coordinate — a place typed by hand in Add Visit, chiefly
            // — previously had no way to ever get one; this is that way.
            // `recordedCoordinate == nil` is itself the cue to place the first pin;
            // once set, a tap only moves it while `adjustingLocation` guards against
            // nudging it by accident.
            if !visit.hasRoute, !showsNeighbourContextInsteadOfMap {
                Section {
                    MapReader { proxy in
                        Map(position: $mapPosition) {
                            if let coordinate = recordedCoordinate {
                                Marker("Recorded location", coordinate: coordinate)
                                    .tint(adjustingLocation ? .orange : .blue)
                            }
                        }
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .mapControls { MapCompass(); MapUserLocationButton() }
                        .onTapGesture(coordinateSpace: .local) { point in
                            guard recordedCoordinate == nil || adjustingLocation,
                                  let updated = proxy.convert(point, from: .local),
                                  CLLocationCoordinate2DIsValid(updated) else { return }
                            visit.latitude = updated.latitude
                            visit.longitude = updated.longitude
                            mapPosition = .region(region(centeredOn: updated))
                            adjustingLocation = false
                        }
                    }
                    .accessibilityIdentifier("visit-location-map-picker")
                    Text(mapLocationFooterText)
                        .font(.footnote).foregroundStyle(.secondary)
                    if recordedCoordinate != nil {
                        Button {
                            adjustingLocation.toggle()
                        } label: {
                            Label(adjustingLocation ? "Finish adjusting pin" : "Adjust pin location",
                                  systemImage: adjustingLocation ? "checkmark.circle" : "mappin.and.ellipse")
                        }
                    }
                } header: {
                    Text("Map location")
                } footer: {
                    Text("Adjusting the pin changes this visit’s stored coordinate. It does not contact Apple Maps until you choose a place suggestion or save a place.")
                }
            }
            Section {
                TextField("Place name", text: $placeNameDraft)
                    .onSubmit { reloadVisitsHere() }
                if recordedCoordinate != nil {
                    Button {
                        showingNearbyPlaces = true
                    } label: {
                        Label("Choose nearby Apple Maps place", systemImage: "mappin.and.ellipse")
                    }
                }
                if visit.needsConfirmation {
                    // Without this there is no way to agree with a weak guess:
                    // dismissing the editor leaves the confidence untouched, so the
                    // visit would return to the review queue forever.
                    Button { confirmPlace() } label: {
                        Label("Yes, this is right", systemImage: "checkmark.circle.fill")
                    }
                    .accessibilityIdentifier("confirm-place")
                }
            } header: {
                Text("Place")
            } footer: {
                if visit.needsConfirmation {
                    Text("LifeLog matched this from Apple Maps but isn\u{2019}t confident. Confirming remembers it for future visits here; correcting the name teaches it instead.")
                }
            }
            Section("What were you doing?") {
                if !historicalActivities.isEmpty {
                    Menu {
                        ForEach(historicalActivities, id: \.self) { activity in
                            Button(activity) { activityDraft = activity }
                        }
                    } label: {
                        Label("Use a previous activity here", systemImage: "clock.arrow.circlepath")
                    }
                }
                Picker("Activity", selection: $activityDraft) {
                    Text("Choose an activity").tag("")
                    ForEach(availableActivities, id: \.self) { Text($0).tag($0) }
                }
                TextField("Or enter your own", text: $activityDraft)
                TextField("Notes", text: $noteDraft, axis: .vertical)
            }
            Text("Changing the activity or place type updates this visit. For a recognised location, saving also learns the choice for future check-ins; you can edit it again at any time.")
                .font(.footnote).foregroundStyle(.secondary)
            Section("Recognition") {
                // Confidence is the verdict; these are the workings. Kept in the same
                // section rather than a new one, because "how sure" and "on what
                // grounds" are one question and reading them apart is what made the
                // verdict feel arbitrary.
                LabeledContent("Confidence", value: visit.confidenceLabel)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Why this place?")
                        .font(.subheadline.weight(.semibold))
                    if placeReasons.isEmpty {
                        Text("Nothing was recorded about how this place was identified.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(placeReasons, id: \.self) { reason in
                            Text(reason).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("place-evidence")
                VStack(alignment: .leading, spacing: 5) {
                    if let score = visit.placeScoreBreakdown {
                        Text("Place score breakdown")
                            .font(.subheadline.weight(.semibold))
                        ForEach(score.lines, id: \.self) { line in
                            Text(line).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Inferred activity evidence")
                        .font(.subheadline.weight(.semibold))
                    Text(inferenceEvidenceText)
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("This is an inference, not a confirmed fact. You can edit the activity above.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !matchingCorrections.isEmpty {
                    ForEach(matchingCorrections.prefix(5)) { correction in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(correction.reason).font(.caption.bold())
                            Text("\(correction.previousPlaceName) → \(correction.newPlaceName)")
                            Text("\(correction.previousActivity) → \(correction.newActivity)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("No corrections recorded for this visit yet.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Time") {
                DatePicker("Arrived", selection: $visit.arrival)
                DatePicker("Left", selection: Binding(get: { visit.departure ?? .now }, set: { visit.departure = $0 }))
            }
            if visit.latitude != 0 || visit.longitude != 0 {
                Section {
                    Button {
                        learnPlace()
                    } label: {
                        Label("Save & Learn Place", systemImage: "brain.head.profile")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!canLearnPlace)
                } footer: {
                    Text("LifeLog will update a nearby saved geofence or create a new 100-metre geofence, then reuse this place and activity automatically.")
                }
            }
            Section {
                Button("Delete Visit", role: .destructive) { presentDeleteConfirmation() }
                    .accessibilityIdentifier("delete-visit")
            } footer: {
                // Was a trash glyph in the top-left corner, a thumb's width from the
                // back button. A destructive action does not belong where a person
                // reaches to leave the screen.
                Text("Removes this entry from your timeline. This cannot be undone.")
            }
        }
        .navigationTitle(visit.needsCategorisation ? "Categorise Place" : "Visit")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingNearbyPlaces) {
            if let coordinate = recordedCoordinate {
                NearbyPlacePicker(coordinate: coordinate, arrival: visit.arrival) { suggestion in
                    select(suggestion)
                    visit.latitude = suggestion.latitude
                    visit.longitude = suggestion.longitude
                    showingNearbyPlaces = false
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { saveAndDismiss() }
            }
        }
        .alert("Couldn’t save changes", isPresented: $saveFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("LifeLog left your existing timeline unchanged.")
        }
        .confirmationDialog("Delete this visit?", isPresented: $confirmingDelete) {
            Button("Delete visit", role: .destructive) { deleteVisit(splitTime: false) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("If the visits before and after it are the same place and activity, their time will be merged. Otherwise no surrounding visit will be guessed.")
        }
        .confirmationDialog("The visits before and after this one are different.", isPresented: $confirmingDeleteSplit) {
            Button("Split time between them", role: .destructive) { deleteVisit(splitTime: true) }
            Button("Leave as unlogged", role: .destructive) { deleteVisit(splitTime: false) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You can split the freed time evenly between the visit before and the one after, or leave it unlogged to fill in yourself later.")
        }
        .onAppear {
            // Guarded: `onAppear` fires again when this screen comes back to the
            // front, and re-seeding from the model there would discard whatever had
            // been typed and not yet committed.
            if !loadedDrafts {
                placeNameDraft = visit.placeName
                activityDraft = visit.userActivity ?? ""
                noteDraft = visit.note
                loadedDrafts = true
            }
            if catalogue.isEmpty { catalogue = ActivityCatalog.load() }
            reloadVisitsHere()
            nearbySavedPlaces = (try? PlaceEvidence.nearbyPlaces(of: visit, context: context)) ?? []
            if !visit.hasRoute, recordedCoordinate == nil {
                neighbours = (try? SurroundingStays.around(visit, context: context)) ?? .init()
                // Also seeds the editable map below: a visit with no coordinate yet
                // still needs somewhere sensible to start, and the places either side
                // of it are the best guess available.
                if let region = region(covering: neighbours) {
                    contextPosition = .region(region)
                    mapPosition = .region(region)
                }
            }
            if correctionBaseline == nil { correctionBaseline = currentSnapshot }
            if let coordinate = recordedCoordinate {
                mapPosition = .region(region(centeredOn: coordinate))
            }
        }
        .onDisappear {
            guard !saveFailed else { return }
            sanitizeVisit()
            try? persistChanges(forceLearning: false)
        }
    }

    private var historicalActivities: [String] {
        var values = visitsHere.map(\.activity)
        values.append(contentsOf: catalogue.map(\.name))
        return Array(Set(values)).filter { !$0.isEmpty }.sorted()
    }

    /// Other visits to the place currently named in the field.
    ///
    /// Answers both questions this screen asks of the archive — which activities have
    /// been used here, and how many times the place has been visited before — so they
    /// are fetched once instead of scanned twice per keystroke.
    private func reloadVisitsHere() {
        visitsHere = (try? PlaceVisitLookup.visits(named: placeNameDraft,
                                                   excluding: visit.persistentModelID,
                                                   context: context)) ?? []
    }

    /// Whether the walk came back to where it started is the thing a person actually
    /// recognises about it — a loop from home reads differently from a walk somewhere.
    private var routeSummary: String {
        let points = visit.route
        guard let first = points.first, let last = points.last else { return "No path recorded" }
        let distance = formattedDistance(visit.routeDistance)
        let returned = last.location.distance(from: first.location) <= ActivityLocationPolicy.departureRadius
        return returned ? "\(distance) · returned to the start" : "\(distance) · ended elsewhere"
    }

    /// What the two pins amount to, in the terms the mistake shows up in.
    ///
    /// The distance is the point. Half an hour of walking that begins and ends 455 m
    /// apart is not half an hour of walking, and the number says so faster than the
    /// map does.
    private var surroundingSummary: String {
        let span = formattedDuration(visit.duration)
        guard let before = neighbours.before, let after = neighbours.after else {
            let only = neighbours.before ?? neighbours.after
            guard let only else { return span }
            let side = neighbours.before != nil ? "After" : "Before"
            return "\(span) · \(side) \(only.displayPlaceName)"
        }
        if NameKey.same(before.placeName, after.placeName) {
            return "\(span) · started and ended at \(before.displayPlaceName)"
        }
        let metres = CLLocation(latitude: before.latitude, longitude: before.longitude)
            .distance(from: CLLocation(latitude: after.latitude, longitude: after.longitude))
        return "\(span) · \(before.displayPlaceName) to \(after.displayPlaceName), "
             + "\(formattedDistance(metres)) apart"
    }

    /// The region holding both pins, with enough margin that neither sits on an edge.
    private func region(covering neighbours: SurroundingStays.Neighbours) -> MKCoordinateRegion? {
        let points = [neighbours.before, neighbours.after].compactMap { $0?.coordinate }
        guard let first = points.first else { return nil }
        guard points.count > 1 else { return region(centeredOn: first) }
        let latitudes = points.map(\.latitude)
        let longitudes = points.map(\.longitude)
        let centre = CLLocationCoordinate2D(
            latitude: (latitudes.min()! + latitudes.max()!) / 2,
            longitude: (longitudes.min()! + longitudes.max()!) / 2
        )
        // A floor as well as the measured span: two pins a hundred metres apart would
        // otherwise zoom in so far that neither place is recognisable.
        return MKCoordinateRegion(
            center: centre,
            span: MKCoordinateSpan(
                latitudeDelta: max((latitudes.max()! - latitudes.min()!) * 1.6, 0.004),
                longitudeDelta: max((longitudes.max()! - longitudes.min()!) * 1.6, 0.004)
            )
        )
    }

    private var placeReasons: [String] {
        PlaceEvidence.reasons(for: visit, savedPlaces: nearbySavedPlaces, recurrence: visitsHere.count)
    }

    private var inferenceEvidenceText: String {
        var evidence = visit.inferenceEvidence
        let recurrence = visitsHere.count
        if recurrence > 0 { evidence.append("Recurring place (\(recurrence) prior check-in\(recurrence == 1 ? "" : "s"))") }
        return evidence.isEmpty ? "No inference evidence recorded" : evidence.joined(separator: " · ")
    }

    /// Accepts a weak Apple Maps guess as correct. The inferred activity becomes an
    /// explicit choice so the visit stops reading as a guess, and learning it saves
    /// the place for future arrivals.
    private func confirmPlace() {
        if activityDraft.isEmpty { activityDraft = visit.inferredActivity }
        visit.recognitionConfidence = "confirmed"
        learnPlace()
    }

    private func learnPlace() {
        sanitizeVisit()
        do {
            try persistChanges(forceLearning: true)
            dismiss()
        } catch {
            saveFailed = true
        }
    }

    private func select(_ suggestion: PlaceSuggestion) {
        placeNameDraft = suggestion.name
        activityDraft = suggestion.suggestedActivity
        visit.recognitionConfidence = "confirmed"
        reloadVisitsHere()
    }

    private func applyQuickLabel(name: String, activity: String) {
        placeNameDraft = name
        activityDraft = activity
        visit.recognitionConfidence = "confirmed"
        learnPlace()
    }

    private func saveAndDismiss() {
        sanitizeVisit()
        do {
            try persistChanges(forceLearning: false)
            dismiss()
        } catch {
            saveFailed = true
        }
    }

    private func deletionNeighbours() -> (previous: Visit?, next: Visit?) {
        guard let all = try? context.fetch(FetchDescriptor<Visit>(sortBy: [SortDescriptor(\.arrival)])) else {
            return (nil, nil)
        }
        let previous = all.filter { $0.id != visit.id && ($0.departure ?? .now) <= visit.arrival }
            .max { $0.arrival < $1.arrival }
        let end = visit.departure ?? visit.arrival
        let next = all.filter { $0.id != visit.id && $0.arrival >= end }
            .min { $0.arrival < $1.arrival }
        return (previous, next)
    }

    /// Same-place/same-activity neighbours always merge silently -- that case has
    /// only one sensible outcome. Different neighbours don't: splitting the freed
    /// time is a real choice, not a default, so that case alone asks first.
    private func presentDeleteConfirmation() {
        let (previous, next) = deletionNeighbours()
        if let previous, let next, !sameActivityLocation(previous, next) {
            confirmingDeleteSplit = true
        } else {
            confirmingDelete = true
        }
    }

    private func deleteVisit(splitTime: Bool) {
        do {
            let (previous, next) = deletionNeighbours()
            if let previous, let next, sameActivityLocation(previous, next) {
                previous.departure = next.departure ?? next.arrival
            } else if splitTime, let previous, let next {
                let gapStart = previous.departure ?? visit.arrival
                let midpoint = gapStart.addingTimeInterval(next.arrival.timeIntervalSince(gapStart) / 2)
                previous.departure = midpoint
                next.arrival = midpoint
            }
            context.delete(visit)
            try context.save()
            dismiss()
        } catch {
            saveFailed = true
        }
    }

    private func sameActivityLocation(_ lhs: Visit, _ rhs: Visit) -> Bool {
        NameKey.same(lhs.placeName, rhs.placeName) && NameKey.same(lhs.activity, rhs.activity)
    }

    /// The one place the typed text reaches the visit. Every path that persists —
    /// Done, Save & Learn Place, and leaving the screen — goes through here first,
    /// so there is a single commit point rather than a write per keystroke.
    private func sanitizeVisit() {
        PlaceLookupService.cancelAllLookups()
        // Nothing to commit if the fields were never filled from the visit. Without
        // this, a screen dismissed before it appeared would write its empty drafts
        // over a real place name.
        guard loadedDrafts else { return }
        visit.placeName = TextSafety.clean(placeNameDraft, maximumLength: 120)
        // Nil, not empty: `ActivityImportActor`, `WorkoutJourneys` and the travel
        // policy all read `userActivity == nil` to mean "the person has not said",
        // and an empty string there reads as an answer they never gave.
        let activity = TextSafety.clean(activityDraft, maximumLength: 80)
        visit.userActivity = activity.isEmpty ? nil : activity
        visit.note = TextSafety.clean(noteDraft, maximumLength: 2_000)
        if let departure = visit.departure, departure < visit.arrival {
            visit.departure = visit.arrival
        }
        // Back into the fields, so what is shown is what was stored.
        placeNameDraft = visit.placeName
        activityDraft = visit.userActivity ?? ""
        noteDraft = visit.note
    }

    private var canLearnPlace: Bool {
        let activity = activityDraft.isEmpty ? visit.inferredActivity : activityDraft
        return (visit.latitude != 0 || visit.longitude != 0) &&
        !TextSafety.clean(placeNameDraft, maximumLength: 100).isEmpty &&
        !TextSafety.clean(activity, maximumLength: 80).isEmpty
    }

    private var recordedCoordinate: CLLocationCoordinate2D? {
        let coordinate = CLLocationCoordinate2D(latitude: visit.latitude, longitude: visit.longitude)
        guard CLLocationCoordinate2DIsValid(coordinate),
              coordinate.latitude != 0 || coordinate.longitude != 0 else { return nil }
        return coordinate
    }

    /// Whether this visit is the one case that keeps the read-only "places either
    /// side of it" map instead of the editable one: a genuine device recording (a
    /// walk, a workout) that Health or Motion gave no coordinate for. Anything else
    /// with no coordinate — a hand-typed Add Visit entry above all — gets the
    /// editable map, since there is nothing here to protect it from.
    private var showsNeighbourContextInsteadOfMap: Bool {
        !visit.hasRoute && recordedCoordinate == nil && ActivityLocationPolicy.isDeviceActivity(visit)
    }

    private var mapLocationFooterText: String {
        guard recordedCoordinate != nil else { return "Tap the map to set this visit’s location." }
        return adjustingLocation
            ? "Tap the map to move the pin, then tap Done to save it."
            : "Recorded at the location shown above."
    }

    private func region(centeredOn coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate,
                           span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004))
    }

    private var currentSnapshot: VisitCorrectionSnapshot {
        VisitCorrectionSnapshot(
            placeName: visit.placeName,
            activity: visit.userActivity ?? visit.inferredActivity,
            confidence: visit.recognitionConfidence ?? "pending"
        )
    }

    private var matchingCorrections: [VisitCorrection] {
        corrections.filter {
            abs($0.visitArrival.timeIntervalSince(visit.arrival)) < 1 &&
            abs($0.latitude - visit.latitude) < 0.00001 &&
            abs($0.longitude - visit.longitude) < 0.00001
        }
    }

    private func persistChanges(forceLearning: Bool) throws {
        let corrected = correctionBaseline.map { $0 != currentSnapshot } ?? false
        // A walk or workout carries no coordinate, so Saved Place learning cannot
        // reach it and its confidence would stay "device" — which is exactly what the
        // importer overwrites when Health or Motion replays the same sample. Relabel
        // a walk as "Dog walk" and the next import would quietly undo it.
        if corrected, ActivityLocationPolicy.isDeviceActivity(visit) {
            visit.recognitionConfidence = "confirmed"
        }
        if corrected, ActivityLocationPolicy.isLocationVisit(visit) {
            // A manual location/activity correction is stronger evidence than a
            // delayed callback, Maps result, or Saved Place default.
            visit.recognitionConfidence = "confirmed"
            visit.placeFieldProvenance = "manual"
        }
        if forceLearning || corrected {
            let result = try SavedPlaceLearning.upsert(
                from: visit,
                previousPlaceName: correctionBaseline?.placeName,
                context: context
            )
            // A correction can also create a Saved Place. That useful side effect
            // must not erase the audit row that prevents later automation from
            // appearing to be the person's choice.
            if corrected {
                CorrectionHistory.record(visit: visit, from: correctionBaseline ?? currentSnapshot,
                                         context: context, reason: "Manual correction")
            } else if result == nil {
                CorrectionHistory.record(visit: visit, from: correctionBaseline ?? currentSnapshot,
                                         context: context, reason: "Manual correction")
                try context.save()
            }
        } else {
            try context.save()
        }
        if corrected || forceLearning {
            // The correction is now part of the evidence set. Re-score after it
            // has been recorded, but keep the confirmed choice untouched.
            _ = PlaceScoreLifecycle.rescore(visit, stage: .correction, context: context)
            _ = try ActivityLocationPolicy.resolveAfterLocationMutation(context: context, reason: "manual correction")
            try context.save()
        }
        InsightsInvalidation.invalidate(reason: corrected ? "visit correction" : "visit edit", context: context)
        correctionBaseline = currentSnapshot
    }
}

/// Visits recorded at a place, found by name.
///
/// The editor asks this two things — which activities have been used here before, and
/// how many times the place has been visited — and used to answer both by filtering a
/// `@Query` holding every visit in the archive. That loaded the whole archive to open
/// one visit, and scanned it three times over on every evaluation of the view.
///
/// The predicate narrows in the store first. `localizedStandardContains` ignores case
/// and diacritics, so it returns a superset of the names `NameKey` calls the same; the
/// exact match is then applied to that much smaller set, which keeps the comparison
/// identical to the one used everywhere else rather than weakening it to `==`.
enum PlaceVisitLookup {
    @MainActor
    static func visits(named name: String, excluding identifier: PersistentIdentifier?,
                       context: ModelContext) throws -> [Visit] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = NameKey.matching(trimmed)
        // A placeholder name is not a place, so "everything still being identified"
        // is not a history of anywhere.
        guard !key.isEmpty, !Visit.isPlaceholderName(trimmed) else { return [] }
        let candidates = try context.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.placeName.localizedStandardContains(trimmed) }
        ))
        return candidates.filter { $0.id != identifier && NameKey.matching($0.placeName) == key }
    }
}

/// The places either side of a record that has no position of its own.
///
/// A walk or a commute imported from Health carries no coordinate and no route —
/// `walkingRecords` builds them from step counts, which have no location — so the
/// editor showed no map at all for exactly the entries hardest to judge. LifeLog
/// cannot say where you were during one of these, and inventing a position would be
/// worse than showing none. What it does know is where you were before and after,
/// and for a record wrongly spanning a drive between two shops that is the whole
/// story: two pins 455 m apart, half an hour of "walking" between them.
///
/// Scoped to a window rather than fetched whole. The editor is opened from a
/// timeline, so the neighbours are minutes away, and this must not become the
/// archive-wide query the rest of this screen was just moved off.
enum SurroundingStays {
    struct Neighbours {
        var before: Visit?
        var after: Visit?
        var haveBoth: Bool { before != nil && after != nil }
    }

    @MainActor
    static func around(_ visit: Visit, context: ModelContext,
                       window: TimeInterval = 6 * 60 * 60) throws -> Neighbours {
        let start = visit.arrival.addingTimeInterval(-window)
        let end = (visit.departure ?? visit.arrival).addingTimeInterval(window)
        let nearby = try context.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.arrival >= start && $0.arrival <= end },
            sortBy: [SortDescriptor(\.arrival)]
        ))
        let located = nearby.filter {
            ActivityLocationPolicy.isLocationVisit($0) &&
            !ActivityLocationPolicy.isSupersededLocation($0) &&
            ($0.latitude != 0 || $0.longitude != 0)
        }
        let ownEnd = visit.departure ?? visit.arrival
        return Neighbours(
            // At or before this record began, latest first — the place it left.
            before: located.last { ($0.departure ?? $0.arrival) <= visit.arrival },
            // At or after it ended — the place it arrived at.
            after: located.first { $0.arrival >= ownEnd }
        )
    }
}

private struct NearbyPlacePicker: View {
    @Environment(\.dismiss) private var dismiss
    let coordinate: CLLocationCoordinate2D
    let arrival: Date
    let onSelect: (PlaceSuggestion) -> Void
    @State private var suggestions: [PlaceSuggestion] = []
    @State private var isLoading = true
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Searching Apple Maps…")
                } else if failed || suggestions.isEmpty {
                    ContentUnavailableView("No nearby places found", systemImage: "mappin.slash",
                                           description: Text("Try adjusting the pin or enter the place name manually."))
                } else {
                    List(suggestions) { suggestion in
                        Button {
                            onSelect(suggestion)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                ActivityIcon(activity: suggestion.suggestedActivity,
                                             context: suggestion.name,
                                             color: activityColor(suggestion.suggestedActivity), size: 42)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(suggestion.name).foregroundStyle(.primary)
                                    Text("\(suggestion.suggestedActivity) · \(Int(suggestion.distance.rounded())) m away")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Nearby Apple Maps Places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task {
                do {
                    let result = try await PlaceLookupService.nearbyPlaces(at: coordinate, radius: 250, arrival: arrival)
                    suggestions = result.suggestions
                } catch {
                    failed = true
                }
                isLoading = false
            }
        }
    }
}
