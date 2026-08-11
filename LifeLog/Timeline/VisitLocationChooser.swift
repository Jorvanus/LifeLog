import SwiftUI
import SwiftData
import MapKit

/// "Where?" — type a name, or pick from what is actually around you.
///
/// The old Add Visit screen made you think of a search term first: a text field, a
/// Search button, then results. Standing in a place you can see, the useful question
/// is not "what would I search for" but "which of these is it", so the places nearby
/// are listed on arrival, closest first, with how far away each one is.
///
/// That answers "I am here now" well and a retrospective entry badly: filling in a
/// visit hours or days after the fact means standing somewhere else entirely, where
/// "nearby" is the wrong question. Submitting the text field runs a real Apple Maps
/// search instead of only listing what's close, and "Choose on map" drops a movable
/// pin for a place search can't find at all.
struct VisitLocationChooser: View {
    @Binding var name: String
    @Binding var resolution: ManualPlaceResolution
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    /// Anchored on the most recent recorded location rather than asking Core Location
    /// again: it is where the person is, and it keeps this screen off the permission
    /// and battery path entirely. Also the starting point for "Choose on map" and the
    /// soft bias for a text search, not a hard limit on either. Fetched with fetchLimit = 1
    /// in `load()` rather than an unbounded `@Query` over every visit in history.
    @State private var anchorCoordinate: CLLocationCoordinate2D?
    @Query(sort: \SavedPlace.name) private var savedPlaces: [SavedPlace]

    @State private var nearby: [NearbyPlace] = []
    @State private var isSearching = true
    @State private var searchFailed = false

    @State private var searchResults: [NearbyPlace] = []
    @State private var isSearchingByName = false
    @State private var searchAttempted = false
    @State private var textSearchFailed = false

    // What's typed, not what's chosen. `name`/`resolution` are the caller's own
    // draft state (never the live model directly), but writing every keystroke
    // into them meant leaving this screen without picking anything -- back
    // button, swipe, whatever -- still left the half-typed text sitting in the
    // place field as though it had been chosen. Only an explicit pick (a row, a
    // search result, "Use" on the map) writes back; typing alone never does.
    @State private var query: String

    init(name: Binding<String>, resolution: Binding<ManualPlaceResolution>) {
        _name = name
        _resolution = resolution
        _query = State(initialValue: name.wrappedValue)
    }

    struct NearbyPlace: Identifiable {
        let name: String
        let coordinate: CLLocationCoordinate2D
        let metres: CLLocationDistance
        /// Set when LifeLog has recorded this place before, so somewhere you use is
        /// never presented as though it were new.
        let isKnown: Bool
        var id: String { "\(name)-\(coordinate.latitude)-\(coordinate.longitude)" }
    }

    private var anchor: CLLocationCoordinate2D? {
        anchorCoordinate
    }

    /// Narrows what's already loaded rather than re-querying Apple Maps per
    /// keystroke -- the list below the text field should react as you type,
    /// not only once you submit (that's what the separate "Search results"
    /// section, and its live Apple Maps request, are for).
    private var filteredNearby: [NearbyPlace] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nearby }
        return nearby.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        List {
            Section {
                TextField("e.g. Aaron's Gardens", text: $query)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.search)
                    .onSubmit { Task { await search() } }
                    .onChange(of: query) { _, updated in
                        if updated.isEmpty {
                            searchAttempted = false
                            searchResults = []
                        }
                    }
                    .accessibilityIdentifier("location-name-field")
            } header: {
                Text("Location")
            } footer: {
                Text("Type a name and search, or choose a place nearby below.")
            }

            if searchAttempted {
                Section {
                    if isSearchingByName {
                        HStack(spacing: 10) { ProgressView(); Text("Searching…") }
                    } else if searchResults.isEmpty {
                        Text(textSearchFailed
                             ? "Apple Maps could not be reached. Try again, or choose on the map below."
                             : "No matches for “\(query)”. Try a different name, or choose on the map below.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ForEach(searchResults) { place in row(for: place) }
                    }
                } header: {
                    Text("Search results")
                } footer: {
                    Text("From Apple Maps, wherever the place actually is.")
                }
            }

            Section {
                NavigationLink {
                    LocationDetailView(name: query, coordinate: anchor ?? .init(latitude: 0, longitude: 0)) { chosen, coordinate in
                        name = chosen
                        resolution = .matched(name: chosen, coordinate: coordinate)
                        dismiss()
                    }
                } label: {
                    Label("Choose on map", systemImage: "mappin.and.ellipse")
                }
                .accessibilityIdentifier("choose-on-map-link")
            } footer: {
                Text("Drop a pin anywhere — for a place search can't find, or one you'd rather point to yourself.")
            }

            Section {
                if isSearching {
                    HStack(spacing: 10) { ProgressView(); Text("Looking around you…") }
                } else if nearby.isEmpty {
                    Text(searchFailed
                         ? "Apple Maps could not be reached."
                         : "Nothing found nearby.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else if filteredNearby.isEmpty {
                    Text("No nearby matches for “\(query)”.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(filteredNearby) { place in row(for: place) }
                }
            } header: {
                HStack {
                    Text("Places nearby")
                    Spacer()
                    if anchor != nil { Text("Ordered by distance").font(.caption2).textCase(nil) }
                }
            } footer: {
                Text("From Apple Maps, plus places already in your timeline. The arrow beside a name opens it on a map.")
            }
        }
        .navigationTitle("Where?")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            // The default back button pops the same as this, but reads as "go
            // back" rather than "discard" -- and nothing here is written back to
            // the caller until an explicit pick anyway, so this is never lying.
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .accessibilityIdentifier("visit-location-chooser")
        .task { await load() }
    }

    @ViewBuilder
    private func row(for place: NearbyPlace) -> some View {
        HStack {
            Button {
                choose(place)
            } label: {
                HStack(spacing: 8) {
                    if place.isKnown {
                        Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                            .font(.caption).foregroundStyle(.blue)
                            .accessibilityLabel("Used before")
                    }
                    Text(place.name).foregroundStyle(.primary)
                    Spacer()
                    Text("\(Int(place.metres.rounded())) m")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            NavigationLink {
                LocationDetailView(name: place.name, coordinate: place.coordinate) { chosen, coordinate in
                    name = chosen
                    resolution = .matched(name: chosen, coordinate: coordinate)
                    dismiss()
                }
            } label: { EmptyView() }
                .labelsHidden()
                .frame(width: 26)
                .accessibilityLabel("Details for \(place.name)")
        }
    }

    private func choose(_ place: NearbyPlace) {
        name = place.name
        resolution = .matched(name: place.name, coordinate: place.coordinate)
        dismiss()
    }

    private func load() async {
        if anchorCoordinate == nil {
            let predicate = #Predicate<Visit> { visit in
                visit.latitude != 0
            }
            let sortByArrival = SortDescriptor(\Visit.arrival, order: .reverse)
            var descriptor = FetchDescriptor<Visit>(predicate: predicate, sortBy: [sortByArrival])
            descriptor.fetchLimit = 1
            let matchingVisits = try? context.fetch(descriptor)
            anchorCoordinate = matchingVisits?.first?.coordinate
        }
        guard let anchor = anchorCoordinate else {
            isSearching = false
            return
        }
        var results: [NearbyPlace] = []
        let origin = CLLocation(latitude: anchor.latitude, longitude: anchor.longitude)

        // Places already in the timeline come first in the merge, so somewhere the
        // person uses keeps its own name rather than Apple's wording for it.
        var known = Set<String>()
        for place in savedPlaces {
            let distance = origin.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))
            guard distance <= 800 else { continue }
            known.insert(place.name.lowercased())
            results.append(NearbyPlace(name: place.name, coordinate: place.coordinate,
                                       metres: distance, isKnown: true))
        }

        let request = MKLocalPointsOfInterestRequest(center: anchor, radius: 400)
        do {
            let response = try await MKLocalSearch(request: request).start()
            for item in response.mapItems {
                guard let itemName = item.name, !known.contains(itemName.lowercased()) else { continue }
                let coordinate = item.location.coordinate
                guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
                results.append(NearbyPlace(
                    name: TextSafety.clean(itemName, maximumLength: 120),
                    coordinate: coordinate,
                    metres: origin.distance(from: CLLocation(latitude: coordinate.latitude,
                                                             longitude: coordinate.longitude)),
                    isKnown: false
                ))
            }
        } catch {
            searchFailed = results.isEmpty
        }
        nearby = results.sorted { $0.metres < $1.metres }
        isSearching = false
    }

    /// A search by name rather than by proximity — the thing this screen otherwise
    /// has no way to do. Biased loosely toward `anchor` when one exists so a common
    /// name (a chain café, a bank branch) prefers the nearby result, but Apple Maps
    /// still surfaces a distant, well-matched name over that bias.
    private func search() async {
        let cleanedQuery = TextSafety.clean(query, maximumLength: 120)
        guard !cleanedQuery.isEmpty else {
            searchAttempted = false
            searchResults = []
            return
        }
        searchAttempted = true
        isSearchingByName = true
        textSearchFailed = false

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = cleanedQuery
        if let anchor {
            request.region = MKCoordinateRegion(center: anchor, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        let origin = anchor.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }

        do {
            let response = try await MKLocalSearch(request: request).start()
            searchResults = response.mapItems.compactMap { item -> NearbyPlace? in
                guard let itemName = item.name else { return nil }
                let coordinate = item.location.coordinate
                guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
                let distance = origin?.distance(from: CLLocation(latitude: coordinate.latitude,
                                                                  longitude: coordinate.longitude)) ?? 0
                return NearbyPlace(name: TextSafety.clean(itemName, maximumLength: 120),
                                   coordinate: coordinate, metres: distance, isKnown: false)
            }.sorted { $0.metres < $1.metres }
        } catch {
            searchResults = []
            textSearchFailed = true
        }
        isSearchingByName = false
    }
}

/// One place on a map, for when the list's wording is wrong or the pin is.
///
/// Choosing where you were is also when you notice a place is wrong — two entries for
/// the same café, or one you named badly months ago. Its history, a merge and a delete
/// live here rather than only in Settings, because here is where you are looking at it.
struct LocationDetailView: View {
    @State var name: String
    @State private var coordinate: CLLocationCoordinate2D
    @State private var position: MapCameraPosition
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedPlace.name) private var savedPlaces: [SavedPlace]

    // An unbounded `@Query` over every `Visit` used to sit here, hydrating the
    // entire archive into memory just to count how many matched this one name --
    // tens of thousands of records on a real archive, which read as this screen
    // hanging outright rather than being merely slow. `PlaceVisitLookup` already
    // does the narrow-then-match version of this for `VisitEditor`; reused here.
    @State private var history: [Visit] = []
    let onUse: (String, CLLocationCoordinate2D) -> Void

    /// The saved place this is, if LifeLog already knows it — by name, or by being
    /// close enough that two pins are plainly the same doorway.
    private var savedPlace: SavedPlace? {
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return savedPlaces.first { place in
            place.name.caseInsensitiveCompare(name) == .orderedSame ||
            origin.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude)) <= 60
        }
    }

    init(name: String, coordinate: CLLocationCoordinate2D,
         onUse: @escaping (String, CLLocationCoordinate2D) -> Void) {
        _name = State(initialValue: name)
        _coordinate = State(initialValue: coordinate)
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: coordinate, latitudinalMeters: 320, longitudinalMeters: 320)))
        self.onUse = onUse
    }

    var body: some View {
        Form {
            Section {
                MapReader { proxy in
                    Map(position: $position) {
                        Marker(name.isEmpty ? "Selected location" : name, coordinate: coordinate)
                    }
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .onTapGesture(coordinateSpace: .local) { point in
                        guard let updated = proxy.convert(point, from: .local),
                              CLLocationCoordinate2DIsValid(updated) else { return }
                        coordinate = updated
                    }
                }
                .accessibilityIdentifier("location-detail-map")
            } header: {
                Text("Map")
            } footer: {
                Text("Tap the map to move the pin.")
            }
            Section("Name") {
                TextField("Name", text: $name).textInputAutocapitalization(.words)
            }
            Section("Location") {
                LabeledContent("Latitude", value: String(format: "%.5f", coordinate.latitude))
                LabeledContent("Longitude", value: String(format: "%.5f", coordinate.longitude))
            }
            if !history.isEmpty {
                Section {
                    NavigationLink {
                        PlaceVisitList(placeName: name, visits: history)
                    } label: {
                        LabeledContent("History", value: "\(history.count) \(history.count == 1 ? "visit" : "visits")")
                    }
                    .accessibilityIdentifier("location-history-link")
                } footer: {
                    Text("Everything recorded here.")
                }
            }
            if let savedPlace {
                Section {
                    NavigationLink {
                        PlaceMergePicker(source: savedPlace, candidates: savedPlaces) { target in
                            merge(savedPlace, into: target)
                        }
                    } label: {
                        Label("Merge with…", systemImage: "arrow.triangle.merge")
                    }
                    .accessibilityIdentifier("merge-place-link")
                    Button("Delete this location", role: .destructive) { confirmingDelete = true }
                        .accessibilityIdentifier("delete-location")
                } footer: {
                    Text("Merging moves this place's history onto the one you choose. Deleting leaves every visit exactly as recorded — LifeLog just stops recognising the place.")
                }
            }
        }
        .confirmationDialog("Delete this location?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let savedPlace {
                    context.delete(savedPlace)
                    _ = try? ActivityLocationPolicy.resolveAfterLocationMutation(context: context, reason: "Saved Place deletion")
                    try? context.save()
                    InsightsInvalidation.invalidate(reason: "Saved place deleted", context: context)
                }
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your timeline keeps all \(history.count) of its visits.")
        }
        .navigationTitle(name.isEmpty ? "Location" : name)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("location-detail-screen")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Use") { onUse(TextSafety.clean(name, maximumLength: 120), coordinate) }
                    .disabled(TextSafety.clean(name, maximumLength: 120).isEmpty)
            }
        }
        .task(id: name) {
            let targetName = name
            guard !targetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                history = []
                return
            }
            // Yield so the push navigation transition finishes rendering before SQLite scans history
            await Task.yield()
            history = (try? PlaceVisitLookup.visits(named: targetName, excluding: nil, context: context)) ?? []
        }
    }
}


private extension LocationDetailView {
    /// Moves this place's history onto another and removes the duplicate.
    ///
    /// Visits are renamed rather than deleted: the person was there, whichever of two
    /// entries for the same doorway happened to record it.
    func merge(_ source: SavedPlace, into target: SavedPlace) {
        let sourceName = source.name
        let matching = (try? PlaceVisitLookup.visits(named: sourceName, excluding: nil, context: context)) ?? []
        for visit in matching {
            visit.placeName = target.name
        }
        context.delete(source)
        _ = try? ActivityLocationPolicy.resolveAfterLocationMutation(context: context, reason: "Saved Place merge")
        try? context.save()
        InsightsInvalidation.invalidate(reason: "Saved places merged", context: context)
        name = target.name
        dismiss()
    }
}

/// The visits recorded at one place.
private struct PlaceVisitList: View {
    let placeName: String
    let visits: [Visit]

    var body: some View {
        List {
            ForEach(visits) { visit in
                NavigationLink { VisitEditor(visit: visit) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(visit.activity).font(.headline)
                        Text(visit.arrival.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(placeName)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("place-visit-list")
    }
}

/// Which place to merge into. Deliberately a plain list of the others: merging is
/// rare, and picking the wrong one silently rewrites history.
private struct PlaceMergePicker: View {
    let source: SavedPlace
    let candidates: [SavedPlace]
    let onPick: (SavedPlace) -> Void
    @State private var pending: SavedPlace?

    var body: some View {
        List {
            Section {
                ForEach(candidates.filter { $0.persistentModelID != source.persistentModelID }) { place in
                    Button(place.name) { pending = place }
                }
            } footer: {
                Text("Every visit recorded as “\(source.name)” is renamed to the place you choose, and “\(source.name)” is removed.")
            }
        }
        .navigationTitle("Merge \(source.name)")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("merge-place-picker")
        .confirmationDialog("Merge into \(pending?.name ?? "")?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible) {
            Button("Merge", role: .destructive) {
                if let pending { onPick(pending) }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        }
    }
}
