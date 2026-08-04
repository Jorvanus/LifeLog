import SwiftUI
import SwiftData
import MapKit

/// Describes how confidently a manually entered location was identified.
/// A map pin is still useful when Apple Maps has no business result, but it
/// must remain distinguishable from a confirmed business match.
enum ManualPlaceResolution {
    case none
    case pinned(CLLocationCoordinate2D)
    case matched(name: String, coordinate: CLLocationCoordinate2D)

    var confidence: String? {
        switch self {
        case .none: return nil
        case .pinned: return "low"
        case .matched: return "confirmed"
        }
    }

    var coordinate: CLLocationCoordinate2D? {
        switch self {
        case .none: return nil
        case .pinned(let coordinate), .matched(_, let coordinate): return coordinate
        }
    }
}

struct ManualVisitView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var place = ""
    @State private var activity = ""
    @State private var arrival = Date()
    @State private var departure = Date()
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var resolution: ManualPlaceResolution = .none
    @State private var isSearching = false
    @State private var searchMessage: String?
    @State private var saveFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Location") {
                    TextField("Search Apple Maps or enter a name", text: $searchText)
                        .textInputAutocapitalization(.words)
                        .onSubmit { search() }

                    Button {
                        search()
                    } label: {
                        Label(isSearching ? "Searching…" : "Search nearby places", systemImage: "magnifyingglass")
                    }
                    .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)

                    if !searchResults.isEmpty {
                        ForEach(searchResults.indices, id: \.self) { index in
                            let item = searchResults[index]
                            Button { choose(item) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name ?? "Unnamed place").foregroundStyle(.primary)
                                    if let address = item.address?.shortAddress ??
                                        item.addressRepresentations?.fullAddress(includingRegion: true, singleLine: true) {
                                        Text(address).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    MapReader { proxy in
                        Map(position: $mapPosition) {
                            if let coordinate = resolution.coordinate {
                                Marker(place.isEmpty ? "Selected location" : place, coordinate: coordinate)
                                    .tint(resolution.confidence == "confirmed" ? .blue : .orange)
                            }
                            ForEach(searchResults.indices, id: \.self) { index in
                                let item = searchResults[index]
                                let coordinate = item.location.coordinate
                                Annotation(item.name ?? "Place", coordinate: coordinate) {
                                    Image(systemName: "mappin.circle.fill")
                                        .font(.title2).foregroundStyle(.blue)
                                }
                            }
                        }
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .mapControls { MapCompass(); MapUserLocationButton() }
                        .onTapGesture(coordinateSpace: .local) { point in
                            guard let coordinate = proxy.convert(point, from: .local) else { return }
                            resolution = .pinned(coordinate)
                            if place.isEmpty { place = "Pinned location" }
                            searchResults = []
                        }
                    }

                    switch resolution {
                    case .matched:
                        Label("Apple Maps match selected", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    case .pinned:
                        Label("Pinned location — no business match", systemImage: "mappin.and.ellipse")
                            .foregroundStyle(.orange)
                    case .none:
                        Text("Search for a business, or tap the map to save a coordinate-only visit.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let searchMessage {
                        Text(searchMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("Details") {
                    TextField("Place name", text: $place)
                    TextField("What were you doing?", text: $activity)
                    DatePicker("Arrived", selection: $arrival)
                    DatePicker("Left", selection: $departure)
                }
            }
            .navigationTitle("Add Visit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Couldn’t save visit", isPresented: $saveFailed) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("LifeLog left your existing timeline unchanged.")
            }
        }
    }

    private func search() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearching = true
        searchMessage = nil
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .pointOfInterest
        if let region = mapPosition.region { request.region = region }

        Task { @MainActor in
            do {
                let response = try await MKLocalSearch(request: request).start()
                searchResults = Array(response.mapItems.prefix(5))
                if searchResults.isEmpty {
                    searchMessage = "No business match found. Tap the map to use a coordinate-only visit."
                }
            } catch {
                searchResults = []
                searchMessage = "Apple Maps search was unavailable. Tap the map or enter the place manually."
            }
            isSearching = false
        }
    }

    private func choose(_ item: MKMapItem) {
        let coordinate = item.location.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        let name = TextSafety.clean(item.name ?? "Selected place", maximumLength: 120)
        place = name
        resolution = .matched(name: name, coordinate: coordinate)
        mapPosition = .region(MKCoordinateRegion(center: coordinate,
                                                  latitudinalMeters: 900,
                                                  longitudinalMeters: 900))
        searchResults = []
        searchMessage = nil
    }

    private func save() {
        let safePlace = TextSafety.clean(place, maximumLength: 120)
        let safeActivity = TextSafety.clean(activity, maximumLength: 80)
        let safeDeparture = max(arrival, departure)
        let coordinate = resolution.coordinate
        let latitude = coordinate?.latitude ?? 0
        let longitude = coordinate?.longitude ?? 0
        let inferred = InferenceEngine.activity(placeName: safePlace, category: "Other", arrival: arrival)
        context.insert(Visit(arrival: arrival, departure: safeDeparture, latitude: latitude, longitude: longitude,
                             placeName: safePlace, placeCategory: "Other",
                             inferredActivity: safeActivity.isEmpty ? inferred : safeActivity,
                             userActivity: safeActivity.isEmpty ? nil : safeActivity, source: "manual",
                             recognitionConfidence: resolution.confidence))
        do {
            try context.save()
            dismiss()
        } catch {
            saveFailed = true
        }
    }
}
