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
    @State private var arrival: Date
    @State private var departure: Date
    @State private var resolution: ManualPlaceResolution = .none
    @State private var recordingJourney = false
    @State private var saveFailed = false
    @State private var confirmingOverlap = false
    /// The two closest visits on each side of `range`, fetched once when the sheet
    /// appears — not the same visits `visits` below already holds, which is
    /// deliberately bounded to *inside* the gap. One Health walking fragment is
    /// often not enough context to identify a gap, so show the surrounding sequence
    /// rather than making that fragment look like the whole story.
    @State private var beforeVisits: [Visit] = []
    @State private var afterVisits: [Visit] = []
    @State private var travelEndpoints: TravelGapEndpointResolver.Endpoints?
    @State private var gapSuggestionViewModel: GapSuggestionViewModel
    /// A deterministic resolver rule may safely prepare the blank form, but it
    /// never saves or prevents a person changing either field.
    @State private var automaticDraftMessage: String?
    /// What the form's fields looked like right after "Use as draft" populated
    /// them, kept only to tell "saved as suggested" from "edited before saving"
    /// at save time — `nil` whenever no suggestion has been accepted this
    /// session, so ordinary hand-typed entries never touch gap-suggestion
    /// diagnostics at all.
    @State private var acceptedDraftSnapshot: DraftSnapshot?

    private struct DraftSnapshot: Equatable {
        let place: String
        let activity: String
        let arrival: Date
        let departure: Date
    }

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
        // The whole point of opening this sheet from a specific gap: it must start
        // scoped to that gap, not to "right now" — the previous default silently
        // discarded the very range the caller went to the trouble of passing in.
        _arrival = State(initialValue: range.start)
        _departure = State(initialValue: range.end)
        _gapSuggestionViewModel = State(initialValue: GapSuggestionViewModel(service: Self.gapSuggestionService(for: range)))
    }

    /// Seeded UI tests switch onto `FakeGapSuggestionService` the same way
    /// `AskLifeLogView`'s own planner chooser does, rather than depending on
    /// live Apple Intelligence.
    private static func gapSuggestionService(for range: DateInterval) -> GapSuggestionRequesting {
        if InternalLaunchArguments.contains(FakeGapSuggestionService.launchArgument) {
            return FakeGapSuggestionService.uiTestService(gapStart: range.start)
        }
        return FoundationModelsGapSuggestionService()
    }

    private var suggestions: [VisitSuggestion] {
        VisitSuggestion.make(from: visits, range: range, savedPlaces: savedPlaces)
    }

    /// The immediate records remain the evidence for existing suggestions and the
    /// travel draft. The second rows are additional human context, not new inference.
    private var beforeVisit: Visit? { beforeVisits.first }
    private var afterVisit: Visit? { afterVisits.first }

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

    /// A visit saved with departure equal to arrival records nothing -- no duration,
    /// no evidence of what happened -- and, unlike an automatic guess, a manual entry
    /// is never folded into anything else by the repair passes, so it would stand
    /// apart forever after.
    static func canSave(place: String, arrival: Date, departure: Date) -> Bool {
        !TextSafety.clean(place, maximumLength: 120).isEmpty && max(arrival, departure) > arrival
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
                if !beforeVisits.isEmpty || !afterVisits.isEmpty {
                    Section {
                        ForEach(Array(beforeVisits.enumerated()), id: \.offset) { index, visit in
                            BorderingVisitRow(label: index == 0 ? "Immediately before" : "Earlier", visit: visit) {
                                selectPlace(from: visit)
                            }
                            .accessibilityIdentifier(index == 0
                                ? "manual-visit-before-context"
                                : "manual-visit-before-context-\(index)")
                        }
                        ForEach(Array(afterVisits.enumerated()), id: \.offset) { index, visit in
                            let rowLabel: String = index == 0 ? "Immediately after" : "Later"
                            let rowIdentifier: String = index == 0
                                ? "manual-visit-after-context"
                                : "manual-visit-after-context-\(index)"
                            BorderingVisitRow(label: rowLabel, visit: visit) {
                                selectPlace(from: visit)
                            }
                            .accessibilityIdentifier(rowIdentifier)
                        }
                        if let travelEndpoints {
                            Button {
                                markAsTravel(from: travelEndpoints.before, to: travelEndpoints.after)
                            } label: {
                                Label("Review likely travel: \(travelEndpoints.before.displayPlaceName) → \(travelEndpoints.after.displayPlaceName)",
                                      systemImage: "car.fill")
                            }
                            .accessibilityIdentifier("manual-visit-mark-as-travel")
                        }
                    } header: {
                        Text("Two records either side of this gap")
                    } footer: {
                        Text("The closest record is shown first. Tap any record to use its place for this visit. When nearby records bound a short gap between different places, Review likely travel prepares an editable journey — it does not claim to know your transport mode.")
                    }
                }

                Section {
                    if recordingJourney {
                        LabeledContent("Journey") {
                            Text(place).foregroundStyle(.primary)
                        }
                    } else {
                        NavigationLink {
                            VisitLocationChooser(name: $place, resolution: $resolution)
                        } label: {
                            LabeledContent("Location") {
                                Text(place.isEmpty ? "Choose location" : place)
                                    .foregroundStyle(place.isEmpty ? .secondary : .primary)
                            }
                        }
                        .accessibilityIdentifier("choose-location-link")
                    }

                    NavigationLink {
                        PlaceActivitySelection(selection: $activity)
                    } label: {
                        LabeledContent("What did you do?") {
                            Text(activity.isEmpty ? "Choose activity" : activity)
                                .foregroundStyle(activity.isEmpty ? .secondary : .primary)
                        }
                    }
                    .accessibilityIdentifier("choose-activity-link")
                } footer: {
                    if let automaticDraftMessage {
                        Label(automaticDraftMessage, systemImage: "wand.and.stars")
                            .accessibilityIdentifier("manual-visit-automatic-draft-note")
                    } else if recordingJourney {
                        Text("This records the time as travel between these endpoints. It does not create or rename a location.")
                    }
                }

                Section("Time") {
                    DatePicker("Start", selection: $arrival)
                        .accessibilityIdentifier("manual-visit-start-picker")
                    DatePicker("End", selection: $departure)
                        .accessibilityIdentifier("manual-visit-end-picker")
                }

                GapSuggestionSection(range: range, viewModel: gapSuggestionViewModel, useAsDraft: useSuggestionAsDraft)

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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        gapSuggestionViewModel.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { attemptSave() }
                        .disabled(!Self.canSave(place: place, arrival: arrival, departure: departure))
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
            .task {
                loadBorderingVisits()
                applyKnownRuleDraftIfAvailable()
            }
            // A shown suggestion described a specific picture of the archive;
            // once a neighbouring visit changes or a Saved Place's Home/Work
            // role changes underneath this sheet — most likely the background
            // location resolver running while the sheet is still open — it
            // must not keep being shown as if it still applied. (Period, date,
            // scope, and filter live on the screen this sheet is modal over,
            // so they cannot change while it's open, and a fresh gap always
            // gets a fresh `ManualVisitView`/`GapSuggestionViewModel` instance.)
            .onChange(of: visits) {
                gapSuggestionViewModel.invalidateIfShowingResult()
                applyKnownRuleDraftIfAvailable()
            }
            .onChange(of: savedPlaces) {
                gapSuggestionViewModel.invalidateIfShowingResult()
                applyKnownRuleDraftIfAvailable()
            }
        }
    }

    /// The form should not make someone request AI help for a conclusion the
    /// local resolver already has. Only an untouched form is prefilled, so a
    /// later Saved Place refresh can never overwrite a person's own edit.
    private func applyKnownRuleDraftIfAvailable() {
        guard place.isEmpty, activity.isEmpty,
              let beforeVisit, let afterVisit,
              let candidate = GapSuggestionCandidateGenerator.candidates(
                before: beforeVisit,
                after: afterVisit,
                savedPlaces: savedPlaces,
                gapStart: range.start,
                gapEnd: range.end
              ).first(where: { $0.kind == .resolverRuleStay })
        else { return }

        populateDraft(from: candidate)
        automaticDraftMessage = "LifeLog filled this from your recorded pattern. You can change it before saving."
    }

    /// Applies a candidate's evidence to the manual form's own fields — never
    /// saves anything itself. A stay candidate reuses `selectPlace(from:)`, the
    /// same path tapping "Before"/"After" already uses, so a real coordinate is
    /// carried forward exactly as it would be by hand. A travel candidate is
    /// deliberately given no coordinate and no Saved Place: its place field is
    /// the same "A → B" arrow label `VisitSuggestion` already uses for a
    /// commute, so it reads as transition time rather than a destination.
    private func useSuggestionAsDraft(_ candidate: GapSuggestionCandidate) {
        recordingJourney = candidate.kind == .homeWorkTransition
        populateDraft(from: candidate)
        acceptedDraftSnapshot = DraftSnapshot(place: place, activity: activity, arrival: arrival, departure: departure)
    }

    /// Shared by an explicit suggestion and a local, deterministic rule. This
    /// only fills the editable controls; recording suggestion feedback remains
    /// exclusive to the explicit "Use as draft" path.
    private func populateDraft(from candidate: GapSuggestionCandidate) {
        switch candidate.kind {
        case .continuationOfBeforeStay, .nearbyResolvedPlaceStay:
            if let beforeVisit { selectPlace(from: beforeVisit) }
        case .continuationOfAfterStay:
            if let afterVisit { selectPlace(from: afterVisit) }
        case .homeWorkTransition:
            recordingJourney = true
            let fromLabel = beforeVisit?.displayPlaceName ?? "Home"
            let toLabel = afterVisit?.displayPlaceName ?? "Work"
            place = "\(fromLabel) → \(toLabel)"
            resolution = .none
        case .resolverRuleStay:
            if let role = candidate.homeWorkRole,
               let savedPlace = savedPlaces.first(where: { $0.homeWorkRole == role }) {
                selectPlace(from: savedPlace)
            } else {
                place = candidate.placeName ?? candidate.activity ?? ""
                resolution = .none
            }
        }
        if let candidateActivity = candidate.activity {
            activity = candidateActivity
        }
        arrival = range.start
        departure = range.end
    }

    /// One-shot, not a live `@Query` — this is context to look at while deciding
    /// what to write, not state the form needs to react to as the store changes
    /// underneath it while the sheet stays open.
    private func loadBorderingVisits() {
        let fetchStart = range.start
        var beforeDescriptor = FetchDescriptor<Visit>(
            predicate: #Predicate<Visit> { $0.departure != nil && $0.departure! <= fetchStart },
            sortBy: [SortDescriptor(\.arrival, order: .reverse)]
        )
        beforeDescriptor.fetchLimit = 2
        beforeVisits = (try? context.fetch(beforeDescriptor)) ?? []

        let fetchEnd = range.end
        var afterDescriptor = FetchDescriptor<Visit>(
            predicate: #Predicate<Visit> { $0.arrival >= fetchEnd },
            sortBy: [SortDescriptor(\.arrival)]
        )
        afterDescriptor.fetchLimit = 2
        afterVisits = (try? context.fetch(afterDescriptor)) ?? []

        let endpointLookback = fetchStart.addingTimeInterval(-TravelGapEndpointResolver.maximumAdjacentDelay)
        let endpointLookahead = fetchEnd.addingTimeInterval(TravelGapEndpointResolver.maximumAdjacentDelay)
        var nearbyDescriptor = FetchDescriptor<Visit>(
            predicate: #Predicate<Visit> {
                $0.arrival <= endpointLookahead && ($0.departure == nil || $0.departure! >= endpointLookback)
            },
            sortBy: [SortDescriptor(\Visit.arrival)]
        )
        nearbyDescriptor.fetchLimit = 24
        if let nearbyVisits = try? context.fetch(nearbyDescriptor) {
            travelEndpoints = TravelGapEndpointResolver.endpoints(for: range, in: nearbyVisits)
        }
    }

    /// Only the *place* — coordinate included when the source visit has one, so a
    /// pick from "Before"/"After" carries a real position forward, not just text.
    /// The activity is left for the person to choose; a coffee stop before a gap
    /// does not mean the gap itself was also coffee.
    private func selectPlace(from visit: Visit) {
        recordingJourney = false
        place = visit.displayPlaceName
        resolution = (visit.latitude != 0 || visit.longitude != 0)
            ? .matched(name: visit.displayPlaceName, coordinate: visit.coordinate)
            : .none
    }

    /// Records this gap as the journey between two recorded places, exactly the
    /// way `GapSuggestionCandidateGenerator`'s `.homeWorkTransition` candidate
    /// already fills a Home/Work commute -- an "A → B" label with no coordinate,
    /// since the whole point is that no single point applies. Not limited to
    /// Home/Work: a walk that ends and a drive that starts at an ordinary shop is
    /// travel too, and until now had no path to being recorded as such at all.
    private func markAsTravel(from before: Visit, to after: Visit) {
        recordingJourney = true
        place = "\(before.displayPlaceName) → \(after.displayPlaceName)"
        resolution = .none
        activity = "Travelling"
        arrival = range.start
        departure = range.end
    }

    /// A resolver rule may point at configured Home or Work directly, rather
    /// than either bordering health fragment. Carry its coordinate into the
    /// editable draft exactly as choosing that Saved Place by hand does.
    private func selectPlace(from savedPlace: SavedPlace) {
        recordingJourney = false
        place = savedPlace.name
        resolution = .matched(name: savedPlace.name, coordinate: savedPlace.coordinate)
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
        let source = recordingJourney ? VisitSource.manualTravelRaw : VisitSource.manualRaw
        let visit = Visit(arrival: arrival, departure: safeDeparture,
                             latitude: coordinate?.latitude ?? 0, longitude: coordinate?.longitude ?? 0,
                             placeName: safePlace,
                             inferredActivity: safeActivity.isEmpty ? inferred : safeActivity,
                             userActivity: safeActivity.isEmpty ? nil : safeActivity, source: source,
                             recognitionConfidence: resolution.confidence,
                             placeFieldProvenance: recordingJourney ? nil : "manual")
        let result = VisitMutationService.perform(context: context, kind: .manualVisit) {
            context.insert(visit)
            return .init(affectedVisit: visit, callbackInterval: DateInterval(start: arrival, end: safeDeparture),
                         coordinate: coordinate, changedCount: 1)
        }
        if result.committed {
            // Never recorded on a failed save — a gap-suggestion diagnostic
            // must describe what was actually written, not an attempt that
            // left the archive unchanged.
            if let acceptedDraftSnapshot {
                let edited = acceptedDraftSnapshot.place != safePlace || acceptedDraftSnapshot.activity != safeActivity
                    || acceptedDraftSnapshot.arrival != arrival || acceptedDraftSnapshot.departure != safeDeparture
                if edited {
                    gapSuggestionViewModel.recordUserAction("edited", diagnosticsContext: context)
                }
                gapSuggestionViewModel.recordUserAction("saved", diagnosticsContext: context)
            }
            dismiss()
        } else {
            saveFailed = true
        }
    }
}

private struct BorderingVisitRow: View {
    let label: String
    let visit: Visit
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(visit.displayPlaceName)
                    Text(visit.activity).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
