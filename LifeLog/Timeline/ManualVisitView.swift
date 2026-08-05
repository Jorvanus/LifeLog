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
    @State private var resolution: ManualPlaceResolution = .none
    @State private var saveFailed = false

    /// Gaps in the recent timeline, offered as a starting point. Adding an entry by
    /// hand is nearly always filling in something LifeLog missed, and it already knows
    /// where the holes are and what sat either side of them.
    @Query(filter: #Predicate<Visit> { $0.source != "imported-journal" },
           sort: \Visit.arrival, order: .reverse) private var visits: [Visit]

    private var suggestions: [VisitSuggestion] {
        VisitSuggestion.make(from: visits)
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
                    Button("Save") { save() }
                        .disabled(TextSafety.clean(place, maximumLength: 120).isEmpty)
                }
            }
            .alert("Couldn’t save visit", isPresented: $saveFailed) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("LifeLog left your existing timeline unchanged.")
            }
        }
    }

    private func save() {
        let safePlace = TextSafety.clean(place, maximumLength: 120)
        let safeActivity = TextSafety.clean(activity, maximumLength: 80)
        let safeDeparture = max(arrival, departure)
        let coordinate = resolution.coordinate
        let inferred = InferenceEngine.activity(placeName: safePlace, arrival: arrival)
        context.insert(Visit(arrival: arrival, departure: safeDeparture,
                             latitude: coordinate?.latitude ?? 0, longitude: coordinate?.longitude ?? 0,
                             placeName: safePlace,
                             inferredActivity: safeActivity.isEmpty ? inferred : safeActivity,
                             userActivity: safeActivity.isEmpty ? nil : safeActivity, source: "manual",
                             recognitionConfidence: resolution.confidence))
        do {
            try context.save()
            InsightsInvalidation.invalidate(reason: "Manual visit added", context: context)
            dismiss()
        } catch {
            saveFailed = true
        }
    }
}
