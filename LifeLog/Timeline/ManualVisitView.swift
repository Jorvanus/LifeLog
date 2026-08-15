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

extension ManualPlaceResolution: Equatable {
    static func == (lhs: ManualPlaceResolution, rhs: ManualPlaceResolution) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case let (.pinned(left), .pinned(right)):
            return left.latitude == right.latitude && left.longitude == right.longitude
        case let (.matched(leftName, leftCoordinate), .matched(rightName, rightCoordinate)):
            return leftName == rightName &&
                leftCoordinate.latitude == rightCoordinate.latitude &&
                leftCoordinate.longitude == rightCoordinate.longitude
        default:
            return false
        }
    }
}

struct ManualVisitView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    /// The day (or window) this sheet was opened for, so Suggestions offers gaps
    /// from the same period the person is already looking at rather than the most
    /// recent holes anywhere in the archive.
    let range: DateInterval
    @State private var place = ""
    @State private var activity = ""
    @State private var arrival = Date()
    @State private var departure = Date()
    @State private var resolution: ManualPlaceResolution = .none
    @State private var saveFailed = false
    @State private var confirmingOverlap = false

    /// Scoped to `range` rather than the whole archive, and including every source
    /// — imported-journal too — since `VisitSuggestion` now needs the same picture
    /// of "already covered" that Insights uses to report unlogged time.
    @Query private var visits: [Visit]
    @Query private var savedPlaces: [SavedPlace]

    init(range: DateInterval) {
        self.range = range
        let fetchStart = range.start
        let fetchEnd = range.end
        _visits = Query(
            filter: #Predicate<Visit> { $0.arrival < fetchEnd && ($0.departure == nil || $0.departure! >= fetchStart) },
            sort: \Visit.arrival, order: .reverse
        )
    }

    private var suggestions: [VisitSuggestion] {
        VisitSuggestion.make(from: visits, range: range, savedPlaces: savedPlaces)
    }

    /// `departure` alone can predate `arrival` while the person is still dragging
    /// the picker; this is the value actually written, so overlap detection asks
    /// the same question `save()` does rather than a looser one.
    private var effectiveDeparture: Date { max(arrival, departure) }

    /// Existing visits this entry would claim the same minutes as. Nothing here
    /// changes what gets saved — a hand-entered visit is left exactly as written,
    /// the same rule `canRejoin` and `mergeOverlappingStays` already apply — this
    /// only tells the person before it happens, since nothing downstream else will.
    private var overlappingVisits: [Visit] {
        Self.overlapping(arrival: arrival, departure: effectiveDeparture, among: visits)
    }

    /// A free function so the overlap rule can be checked without standing up the
    /// view: any visit whose own span shares a minute with `[arrival, departure)`.
    static func overlapping(arrival: Date, departure: Date, among visits: [Visit], now: Date = .now) -> [Visit] {
        visits.filter { $0.arrival < departure && ($0.departure ?? now) > arrival }
    }

    private var overlapSummary: String {
        overlappingVisits
            .sorted { $0.arrival < $1.arrival }
            .map { "\($0.displayPlaceName), \($0.arrival.formatted(date: .omitted, time: .shortened))–\(($0.departure ?? .now).formatted(date: .omitted, time: .shortened))" }
            .joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        VisitLocationChooser(name: $place, resolution: $resolution)
                    } label: {
                        LabeledContent("Location") {
                            Text(place.isEmpty ? "Choose location" : place)
                                .foregroundStyle(place.isEmpty ? .secondary : .primary)
                        }
                    }
                    .accessibilityIdentifier("choose-location-link")

                    NavigationLink {
                        PlaceActivitySelection(selection: $activity)
                    } label: {
                        LabeledContent("What did you do?") {
                            Text(activity.isEmpty ? "Choose activity" : activity)
                                .foregroundStyle(activity.isEmpty ? .secondary : .primary)
                        }
                    }
                    .accessibilityIdentifier("choose-activity-link")
                }

                Section("Time") {
                    DatePicker("Start", selection: $arrival)
                    DatePicker("End", selection: $departure)
                }

                if !suggestions.isEmpty {
                    Section {
                        ForEach(suggestions) { suggestion in
                            Button {
                                arrival = suggestion.start
                                departure = suggestion.end
                                if place.isEmpty { place = suggestion.place }
                                if activity.isEmpty { activity = suggestion.activity }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(suggestion.timeRange).font(.subheadline.weight(.medium))
                                    Text(suggestion.summary).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Suggestions")
                    } footer: {
                        Text("Times LifeLog has nothing recorded for, and what it would guess from what sat either side. Tap one to fill this in.")
                    }
                }
            }
            .navigationTitle("Add Visit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { attemptSave() }
                        .disabled(TextSafety.clean(place, maximumLength: 120).isEmpty)
                }
            }
            .alert("Couldn’t save visit", isPresented: $saveFailed) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("LifeLog left your existing timeline unchanged.")
            }
            .alert("This overlaps your existing timeline", isPresented: $confirmingOverlap) {
                Button("Save Anyway", role: .destructive) { save() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This time overlaps:\n\(overlapSummary)")
            }
        }
    }

    private func attemptSave() {
        if overlappingVisits.isEmpty {
            save()
        } else {
            confirmingOverlap = true
        }
    }

    private func save() {
        let safePlace = TextSafety.clean(place, maximumLength: 120)
        let safeActivity = TextSafety.clean(activity, maximumLength: 80)
        let safeDeparture = effectiveDeparture
        let coordinate = resolution.coordinate
        let inferred = InferenceEngine.activity(placeName: safePlace, arrival: arrival)
        let visit = Visit(arrival: arrival, departure: safeDeparture,
                             latitude: coordinate?.latitude ?? 0, longitude: coordinate?.longitude ?? 0,
                             placeName: safePlace,
                             inferredActivity: safeActivity.isEmpty ? inferred : safeActivity,
                             userActivity: safeActivity.isEmpty ? nil : safeActivity, source: "manual",
                             recognitionConfidence: resolution.confidence,
                             placeFieldProvenance: "manual")
        let result = VisitMutationService.perform(context: context, kind: .manualVisit) {
            context.insert(visit)
            return .init(affectedVisit: visit, callbackInterval: DateInterval(start: arrival, end: safeDeparture),
                         coordinate: coordinate, changedCount: 1)
        }
        if result.committed {
            dismiss()
        } else {
            saveFailed = true
        }
    }
}
