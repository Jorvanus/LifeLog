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

    /// The visit being edited already has a coordinate more relevant than
    /// wherever the phone last recorded one -- editing a visit from last week
    /// in another city otherwise centred the map, and searched "nearby", on
    /// today's location instead of the one actually being corrected. `nil` for
    /// Add Visit, which has no visit yet to have a coordinate of its own.
    let recordedCoordinate: CLLocationCoordinate2D?

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

    init(name: Binding<String>, resolution: Binding<ManualPlaceResolution>,
         recordedCoordinate: CLLocationCoordinate2D? = nil) {
        _name = name
        _resolution = resolution
        self.recordedCoordinate = recordedCoordinate
        // Left blank rather than seeded from `name`: a real current guess is
        // usually a long, specific name that matches nothing else nearby, so
        // pre-filling it just filtered the nearby list down to "no matches" the
        // instant this screen opened. The current guess is shown as a checkmark
        // in that list instead, the way it's already known -- Places nearby
        // still doubles as "confirm what LifeLog already thinks" this way.
        _query = State(initialValue: "")
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
        recordedCoordinate ?? anchorCoordinate
    }

    /// Narrows what's already loaded rather than re-querying Apple Maps per
    /// keystroke -- the list below the text field should react as you type,
    /// not only once you submit (that's what the separate "Search results"
    /// section, and its live Apple Maps request, are for).
    ///
    /// While typing, this searches every saved place by name -- not just the
    /// ones within `load()`'s 800m proximity cutoff. Fixing an old visit means
    /// standing somewhere else entirely, where a saved place from that day is
    /// often nowhere near "nearby"; a name match should still find it. Apple's
    /// own nearby points of interest stay proximity-scoped, since there is no
    /// bounded list of those to search globally.
    private var filteredNearby: [NearbyPlace] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nearby }
        let matchingSaved = savedPlaces
            .filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
            .map { place -> NearbyPlace in
                let distance = anchor.map {
                    CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                        .distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))
                } ?? 0
                return NearbyPlace(name: place.name, coordinate: place.coordinate, metres: distance, isKnown: true)
            }
        var seen = Set(matchingSaved.map { $0.name.lowercased() })
        var merged = matchingSaved
        for poi in nearby where !poi.isKnown && poi.name.localizedCaseInsensitiveContains(trimmed) {
            guard seen.insert(poi.name.lowercased()).inserted else { continue }
            merged.append(poi)
        }
        return merged.sorted { $0.metres < $1.metres }
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
                    Text("Anywhere you've recorded a visit under this name, plus Apple Maps.")
                }
            }

            Section {
                NavigationLink {
                    ChooseOnMapView(name: query, coordinate: anchor ?? .init(latitude: 0, longitude: 0)) { chosen, coordinate in
                        name = chosen
                        resolution = .matched(name: chosen, coordinate: coordinate)
                    }
                } label: {
                    Label("Choose on map", systemImage: "mappin.and.ellipse")
                }
                .accessibilityIdentifier("choose-on-map-link")
            } footer: {
                Text("Drop a pin anywhere — for a place search can't find, or one you'd rather point to yourself. Named above; the map only decides where.")
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
                    Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Places nearby" : "Matching places")
                    Spacer()
                    if anchor != nil { Text("Ordered by distance").font(.caption2).textCase(nil) }
                }
            } footer: {
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "From Apple Maps, plus places already in your timeline. The arrow beside a name opens it on a map."
                     : "Every saved place matching the name, wherever it is, plus nearby Apple Maps points of interest. The arrow beside a name opens it on a map.")
            }
        }
        .navigationTitle("Where?")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .onChange(of: resolution) { _, newValue in
            // A pick made straight from this screen's own row is a plain button,
            // so it could call `dismiss()` directly and it worked. A pick made on
            // "Choose on map" or a place's own detail screen comes back through a
            // callback captured two navigation levels up -- that `dismiss()`,
            // called from a grandchild, did not reliably pop back this far. This
            // reacts to the choice itself instead, however many screens away it
            // was made, and is the one place any pick now dismisses from.
            if case .matched = newValue { dismiss() }
        }
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

    /// Whether this row is what LifeLog already has recorded for the visit --
    /// shown as a checkmark rather than by pre-filling the text field, since a
    /// pre-filled field filtered this very list down to nothing the moment the
    /// screen opened.
    private func isCurrentGuess(_ place: NearbyPlace) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return NameKey.same(place.name, trimmed)
    }

    @ViewBuilder
    private func row(for place: NearbyPlace) -> some View {
        HStack {
            Button {
                choose(place)
            } label: {
                HStack(spacing: 8) {
                    if isCurrentGuess(place) {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.semibold)).foregroundStyle(.blue)
                            .accessibilityLabel("Current place")
                    } else if place.isKnown {
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
            // Apple Maps alone has nothing behind this for a place LifeLog has
            // never recorded -- no history, nothing to merge or delete, just the
            // same name and coordinate already on screen. The detail link (and
            // the disclosure chevron a `NavigationLink` draws automatically in a
            // `List` row) only earns its place when there's a real destination:
            // a place LifeLog already knows.
            if place.isKnown {
                NavigationLink {
                    LocationDetailView(name: place.name, coordinate: place.coordinate) { chosen, coordinate in
                        name = chosen
                        resolution = .matched(name: chosen, coordinate: coordinate)
                    }
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .frame(width: 30)
                .accessibilityLabel("Details for \(place.name)")
            }
        }
    }

    private func choose(_ place: NearbyPlace) {
        name = place.name
        resolution = .matched(name: place.name, coordinate: place.coordinate)
    }

    private func load() async {
        // Only needed as a fallback: a real `recordedCoordinate` already answers
        // this, and skips the fetch entirely.
        if recordedCoordinate == nil, anchorCoordinate == nil {
            let predicate = #Predicate<Visit> { visit in
                visit.latitude != 0
            }
            let sortByArrival = SortDescriptor(\Visit.arrival, order: .reverse)
            var descriptor = FetchDescriptor<Visit>(predicate: predicate, sortBy: [sortByArrival])
            descriptor.fetchLimit = 1
            let matchingVisits = try? context.fetch(descriptor)
            anchorCoordinate = matchingVisits?.first?.coordinate
        }
        guard let anchor else {
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
    ///
    /// Also searches the recorded archive for the same substring, not only
    /// `savedPlaces` (already covered live, per keystroke, by `filteredNearby`).
    /// Fixing an old visit at a place that was only ever recorded once or twice --
    /// never repeated enough to be learned into a Saved Place -- otherwise had no
    /// way back into this screen at all. Run on submit rather than per keystroke,
    /// same as the Apple Maps request beside it: an archive substring scan is
    /// bounded but not free, and this field already has a live, cheap filter for
    /// the common case.
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

        func distance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
            origin?.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) ?? 0
        }

        let historyMatches = ((try? PlaceVisitLookup.matchingPlaces(containing: cleanedQuery, context: context)) ?? [])
            .map { NearbyPlace(name: $0.name, coordinate: $0.coordinate, metres: distance(to: $0.coordinate), isKnown: true) }
        var seen = Set(historyMatches.map { $0.name.lowercased() })

        do {
            let response = try await MKLocalSearch(request: request).start()
            let mapMatches = response.mapItems.compactMap { item -> NearbyPlace? in
                guard let itemName = item.name else { return nil }
                let coordinate = item.location.coordinate
                guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
                let cleanedName = TextSafety.clean(itemName, maximumLength: 120)
                guard seen.insert(cleanedName.lowercased()).inserted else { return nil }
                return NearbyPlace(name: cleanedName, coordinate: coordinate, metres: distance(to: coordinate), isKnown: false)
            }
            searchResults = (historyMatches + mapMatches).sorted { $0.metres < $1.metres }
        } catch {
            searchResults = historyMatches.sorted { $0.metres < $1.metres }
            textSearchFailed = historyMatches.isEmpty
        }
        isSearchingByName = false
    }
}

/// Drops a pin and, at wherever it lands, offers the same two sources
/// `VisitLocationChooser` itself starts from: nearby Apple Maps points of
/// interest and already-saved places. The name was already typed on the
/// previous screen, so this page carries no naming field of its own -- it
/// only decides where, either by accepting the bare pin under that name or
/// by picking a named suggestion at the dropped position outright.
struct ChooseOnMapView: View {
    let initialName: String
    let onUse: (String, CLLocationCoordinate2D) -> Void
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SavedPlace.name) private var savedPlaces: [SavedPlace]

    @State private var coordinate: CLLocationCoordinate2D
    @State private var position: MapCameraPosition
    @State private var suggestions: [VisitLocationChooser.NearbyPlace] = []
    @State private var isSearching = false
    @State private var searchFailed = false
    @State private var searchTask: Task<Void, Never>?

    init(name: String, coordinate: CLLocationCoordinate2D,
         onUse: @escaping (String, CLLocationCoordinate2D) -> Void) {
        self.initialName = name
        self.onUse = onUse
        _coordinate = State(initialValue: coordinate)
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: coordinate, latitudinalMeters: 320, longitudinalMeters: 320)))
    }

    private var trimmedName: String { TextSafety.clean(initialName, maximumLength: 120) }

    var body: some View {
        Form {
            Section {
                MapReader { proxy in
                    Map(position: $position) {
                        Marker(trimmedName.isEmpty ? "Selected location" : trimmedName, coordinate: coordinate)
                    }
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .onTapGesture(coordinateSpace: .local) { point in
                        guard let updated = proxy.convert(point, from: .local),
                              CLLocationCoordinate2DIsValid(updated) else { return }
                        coordinate = updated
                        refreshSuggestions()
                    }
                }
                .accessibilityIdentifier("choose-on-map-view")
            } header: {
                Text("Map")
            } footer: {
                Text("Tap the map to move the pin.")
            }

            Section {
                Button {
                    onUse(trimmedName, coordinate)
                    dismiss()
                } label: {
                    Label(trimmedName.isEmpty ? "Use this exact spot" : "Use “\(trimmedName)” at this spot",
                          systemImage: "mappin.and.ellipse")
                }
                .disabled(trimmedName.isEmpty)
                .accessibilityIdentifier("use-dropped-pin")
            } footer: {
                Text(trimmedName.isEmpty
                     ? "Type a name on the previous screen to use this exact pin."
                     : "Uses the pin's position with the name you typed.")
            }

            Section {
                if isSearching {
                    HStack(spacing: 10) { ProgressView(); Text("Looking near the pin…") }
                } else if suggestions.isEmpty {
                    Text(searchFailed
                         ? "Apple Maps could not be reached."
                         : "Nothing found at this spot.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(suggestions) { place in
                        Button {
                            onUse(place.name, place.coordinate)
                            dismiss()
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
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Near this pin")
            } footer: {
                Text("From Apple Maps and places you've already saved, closest to the pin first. Picking one uses its own name and exact position instead of the pin.")
            }
        }
        .navigationTitle("Choose on Map")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("choose-on-map-screen")
        .task { refreshSuggestions() }
    }

    /// Re-run at the new pin position rather than the map's original centre --
    /// the whole point of dropping a pin is to point somewhere the initial
    /// anchor didn't already cover.
    private func refreshSuggestions() {
        searchTask?.cancel()
        isSearching = true
        searchFailed = false
        let target = coordinate
        searchTask = Task {
            var results: [VisitLocationChooser.NearbyPlace] = []
            let origin = CLLocation(latitude: target.latitude, longitude: target.longitude)
            var known = Set<String>()
            for place in savedPlaces {
                let distance = origin.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))
                guard distance <= 400 else { continue }
                known.insert(place.name.lowercased())
                results.append(.init(name: place.name, coordinate: place.coordinate, metres: distance, isKnown: true))
            }
            let request = MKLocalPointsOfInterestRequest(center: target, radius: 200)
            // Required, classified the same as the other two MapKit lookups in
            // this file: a swallowed failure here previously looked identical to
            // "nothing nearby", with no way to tell the person Maps just didn't
            // answer. `searchFailed` distinguishes the two in the empty-state text.
            do {
                let response = try await MKLocalSearch(request: request).start()
                for item in response.mapItems {
                    guard let itemName = item.name, !known.contains(itemName.lowercased()) else { continue }
                    let itemCoordinate = item.location.coordinate
                    guard CLLocationCoordinate2DIsValid(itemCoordinate) else { continue }
                    results.append(.init(
                        name: TextSafety.clean(itemName, maximumLength: 120),
                        coordinate: itemCoordinate,
                        metres: origin.distance(from: CLLocation(latitude: itemCoordinate.latitude,
                                                                 longitude: itemCoordinate.longitude)),
                        isKnown: false
                    ))
                }
            } catch {
                searchFailed = results.isEmpty
            }
            guard !Task.isCancelled else { return }
            suggestions = results.sorted { $0.metres < $1.metres }
            isSearching = false
        }
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
    @State private var actionFailed = false
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
                    .onAppear {
                        Diagnostics.record(context, subsystem: "LocationDetailView",
                                           message: "Map appeared", severity: "info",
                                           category: Diagnostics.Category.performance)
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
                    let mutation = VisitMutationService.finalize(
                        context: context,
                        kind: .savedPlaceChange,
                        change: .init(changedCount: 1)
                    )
                    // Required: a rolled-back mutation must not read as a
                    // completed deletion. `VisitMutationService` has already
                    // rolled `context` back by this point; this view must not
                    // dismiss as though the place is gone.
                    guard mutation.committed else { actionFailed = true; return }
                }
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your timeline keeps all \(history.count) of its visits.")
        }
        .alert("Couldn’t save changes", isPresented: $actionFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("LifeLog couldn’t save that change. Nothing was lost — try again.")
        }
        .navigationTitle(name.isEmpty ? "Location" : name)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("location-detail-screen")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Use") {
                    onUse(TextSafety.clean(name, maximumLength: 120), coordinate)
                    dismiss()
                }
                    .disabled(TextSafety.clean(name, maximumLength: 120).isEmpty)
            }
        }
        .onAppear {
            Diagnostics.record(context, subsystem: "LocationDetailView",
                               message: "Form appeared", severity: "info",
                               category: Diagnostics.Category.performance)
        }
        .task(id: name) {
            Diagnostics.record(context, subsystem: "LocationDetailView",
                               message: "History task started", severity: "info",
                               category: Diagnostics.Category.performance)
            let targetName = name
            guard !targetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                history = []
                return
            }
            // Yield so the push navigation transition finishes rendering before SQLite scans history
            await Task.yield()
            let startedAt = Date.now
            history = (try? PlaceVisitLookup.visits(named: targetName, excluding: nil, context: context)) ?? []
            Diagnostics.performance(context, subsystem: "LocationDetailView",
                                    operation: "history fetch", startedAt: startedAt,
                                    itemCount: history.count, threshold: 0)
            Diagnostics.record(context, subsystem: "LocationDetailView",
                               message: "History task finished (\(history.count) items)", severity: "info",
                               category: Diagnostics.Category.performance)
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
        // Required, not best effort: this fetch finds every visit the merge is
        // supposed to carry over. Defaulting a failure to `[]` would still
        // delete `source` and report success while silently renaming nothing —
        // exactly the "mutation appears successful but wasn't" this audit
        // exists to catch. Abort instead, with `source` left untouched.
        let matching: [Visit]
        do {
            matching = try PlaceVisitLookup.visits(named: sourceName, excluding: nil, context: context)
        } catch {
            Diagnostics.record(error, context: context, subsystem: "LocationDetailView", operation: "merge visit lookup")
            actionFailed = true
            return
        }
        for visit in matching {
            visit.placeName = target.name
        }
        context.delete(source)
        let mutation = VisitMutationService.finalize(
            context: context,
            kind: .savedPlaceChange,
            change: .init(changedCount: matching.count + 1)
        )
        guard mutation.committed else { actionFailed = true; return }
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
