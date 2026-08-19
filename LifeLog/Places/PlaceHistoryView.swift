import SwiftUI
import SwiftData
import MapKit

/// Lists every place name in the timeline, however it was recorded. Saved Places
/// only cover geofenced locations, and imported journal rows have no coordinates
/// at all, so this is the only route to the bulk of an imported history.
struct PlaceHistoryView: View {
    @Environment(\.modelContext) private var context
    @State private var summaries: [PlaceHistorySummary] = []
    @State private var loading = true
    @State private var search = ""
    @State private var sort: PlaceHistorySort = .mostEntries
    @State private var reader: VisitArchiveReader?

    private var filtered: [PlaceHistorySummary] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matching = query.isEmpty ? summaries : summaries.filter { $0.name.lowercased().contains(query) }
        return PlaceHistorySort.sorted(matching, by: sort)
    }

    var body: some View {
        List {
            if loading {
                HStack { ProgressView(); Text("Reading your timeline…").foregroundStyle(.secondary) }
            } else if summaries.isEmpty {
                ContentUnavailableView("No named places yet", systemImage: "mappin.slash",
                                       description: Text("Places appear here once visits carry a name."))
            } else {
                Section {
                    ForEach(filtered) { summary in
                        NavigationLink {
                            PlaceHistoryDetail(placeName: summary.name)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(summary.name).font(.headline).lineLimit(1)
                                Text("\(summary.count) \(summary.count == 1 ? "entry" : "entries") · mostly \(summary.dominantActivity) (\(summary.dominantShare)%)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text(sort.footerText + " Open one to correct its activity across every entry at once.")
                }
            }
        }
        .navigationTitle("Place History")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Find a place")
        .accessibilityIdentifier("place-history-screen")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("Sort places", selection: $sort) {
                    ForEach(PlaceHistorySort.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Sort places")
            }
        }
        .task { await load() }
    }

    private func load() async {
        let startedAt = Date.now
        let generation = await InsightsAggregationActor.shared.currentGeneration()
        let reader = reader ?? VisitArchiveReader(modelContainer: context.container)
        self.reader = reader
        do {
            let result = try await reader.placeSummaries(generation: generation)
            // Do not publish a value assembled from an older store after an import,
            // correction, or restore landed while this actor was reading it.
            let currentGeneration = await InsightsAggregationActor.shared.currentGeneration()
            guard !Task.isCancelled, generation == currentGeneration else { return }
            summaries = result.summaries
            loading = false
        Diagnostics.budget(context, subsystem: "Place History", operation: "background summary",
                           startedAt: startedAt, budget: Diagnostics.PerformanceBudget.settingsOpening,
                           itemCount: result.itemCount)
        } catch is CancellationError {
            return
        } catch {
            loading = false
        }
    }
}

enum PlaceHistorySort: String, CaseIterable, Identifiable {
    case mostEntries
    case alphabetical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mostEntries: "Most entries"
        case .alphabetical: "A–Z"
        }
    }

    var footerText: String {
        switch self {
        case .mostEntries: "Sorted by how often each place appears."
        case .alphabetical: "Sorted alphabetically by place name."
        }
    }

    static func sorted(_ summaries: [PlaceHistorySummary], by order: Self) -> [PlaceHistorySummary] {
        switch order {
        case .mostEntries:
            return summaries.sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .alphabetical:
            return summaries.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }
}

/// The three headline numbers a place's own history can answer: when a visit is
/// most likely to start, how long a typical stay runs, and how much time the
/// place has claimed in total.
private struct PlaceVisitAnalytics {
    let peakHourLabel: String?
    let averageStayLabel: String?
    let lifetimeLabel: String

    private struct WeekdayHour: Hashable { let weekday: Int; let hour: Int }

    /// Below this many visits sharing the same weekday and hour, "usually" would
    /// be reading a pattern into what could easily be one or two coincidences —
    /// the same reasoning `ArchiveRetrospectives.minimumOccasionsForAGap` uses.
    static let minimumOccasionsForPeakHour = 3

    static func make(from visits: [PlaceHistoryEntry]) -> PlaceVisitAnalytics {
        let calendar = Calendar.current
        var slotCounts: [WeekdayHour: Int] = [:]
        var representativeDate: [WeekdayHour: Date] = [:]
        for visit in visits {
            let components = calendar.dateComponents([.weekday, .hour], from: visit.arrival)
            guard let weekday = components.weekday, let hour = components.hour else { continue }
            let slot = WeekdayHour(weekday: weekday, hour: hour)
            slotCounts[slot, default: 0] += 1
            if representativeDate[slot] == nil { representativeDate[slot] = visit.arrival }
        }

        var peakHourLabel: String?
        if let (slot, count) = slotCounts.max(by: { $0.value < $1.value }),
           count >= minimumOccasionsForPeakHour,
           let sample = representativeDate[slot],
           let hourDate = calendar.date(bySettingHour: slot.hour, minute: 0, second: 0, of: sample) {
            let weekdayName = sample.formatted(.dateTime.weekday(.abbreviated))
            let timeString = hourDate.formatted(date: .omitted, time: .shortened)
            peakHourLabel = "Usually \(weekdayName) at \(timeString)"
        }

        // Duration falls back to "now" for a visit still open, which would grow
        // every time this screen redraws. Only a visit that has actually ended
        // has a stay length worth averaging.
        let completed = visits.filter { $0.departure != nil }
        let averageStayLabel: String? = completed.isEmpty ? nil :
            "Avg stay: \(formattedDuration(completed.reduce(0) { $0 + $1.duration } / Double(completed.count)))"

        let totalHours = Int((visits.reduce(0) { $0 + $1.duration } / 3600).rounded())
        let lifetimeLabel = "\(totalHours) \(totalHours == 1 ? "hour" : "hours") logged (\(visits.count) \(visits.count == 1 ? "visit" : "visits"))"

        return PlaceVisitAnalytics(peakHourLabel: peakHourLabel, averageStayLabel: averageStayLabel,
                                    lifetimeLabel: lifetimeLabel)
    }
}

struct PlaceHistoryDetail: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var savedPlaces: [SavedPlace]
    let placeName: String
    @State private var band: PlaceTimeBand = .allDay
    @State private var replacement = ""
    @State private var renamedPlace = ""
    @State private var confirming = false
    @State private var confirmingRename = false
    @State private var message: String?
    @State private var breakdown: [(band: PlaceTimeBand, activities: [(String, Int)])] = []
    @State private var matching: [PlaceHistoryEntry] = []
    @State private var reader: VisitArchiveReader?
    @State private var pickingMergeTarget = false
    @State private var mergeTarget: PlaceHistorySummary?
    @State private var mergeInFlight = false
    /// The detail screen owns only one place's entries, so load the archive-wide
    /// target names through the same reader used by the parent list.
    @State private var summariesForMerge: [PlaceHistorySummary] = []

    private var analytics: PlaceVisitAnalytics { PlaceVisitAnalytics.make(from: matching) }
    private var savedPlace: SavedPlace? {
        savedPlaces.first { NameKey.same($0.name, placeName) }
    }

    /// A person's own choice is never overwritten by a bulk change.
    private var protectedCount: Int {
        scoped.filter { VisitRecognitionConfidence(rawValue: $0.recognitionConfidence) == .confirmed }.count
    }
    private var scoped: [PlaceHistoryEntry] {
        matching.filter { band.contains($0.arrival) }
    }
    private var changeableCount: Int { scoped.count - protectedCount }

    var body: some View {
        Form {
            formContent
        }
        .navigationTitle(placeName)
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
        .confirmationDialog("Change \(changeableCount) entries?", isPresented: $confirming) {
            Button("Change \(changeableCount) entries", role: .destructive) { apply() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Every entry for \(placeName) in \(band.title.lowercased()) becomes “\(TextSafety.clean(replacement, maximumLength: 80))”, apart from \(protectedCount) you confirmed yourself.")
        }
        .confirmationDialog("Rename this place?", isPresented: $confirmingRename) {
            Button("Rename \(matching.count) entries", role: .destructive) { performRename() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Every timeline entry recorded as “\(placeName)” will become “\(cleanRenamedPlace)”. A matching Saved Place keeps its location, radius, role, and activity.")
        }
        .alert("Place history", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
        .confirmationDialog("Merge into “\(mergeTarget?.name ?? "")”?", isPresented: Binding(
            get: { mergeTarget != nil }, set: { if !$0 { mergeTarget = nil } }
        ), titleVisibility: .visible) {
            if let mergeTarget {
                Button("Merge into “\(mergeTarget.name)”", role: .destructive) {
                    performMerge(into: mergeTarget.name)
                }
            }
            Button("Cancel", role: .cancel) { mergeTarget = nil }
        } message: {
            Text("Every entry recorded as “\(placeName)” will be renamed to “\(mergeTarget?.name ?? "")”.")
        }
        .sheet(isPresented: $pickingMergeTarget) {
            NavigationStack {
                PlaceHistoryMergeTargetPicker(candidates: mergeCandidates) { target in
                    pickingMergeTarget = false
                    mergeTarget = target
                }
            }
        }
    }

    @ViewBuilder
    private var formContent: some View {
        if !matching.isEmpty { PlaceHistoryAnalyticsSection(analytics: analytics) }
        if let savedPlace { SavedPlaceContextSection(place: savedPlace) }
        if !matching.isEmpty { PlaceHistoryVisitsSection(placeName: placeName, visits: matching) }
        PlaceHistoryBreakdownSection(breakdown: breakdown)
        PlaceActivityCorrectionSection(band: $band, replacement: $replacement,
                                       protectedCount: protectedCount, changeableCount: changeableCount,
                                       onConfirm: { confirming = true })
        PlaceNameCorrectionSection(name: $renamedPlace, currentName: placeName,
                                   entryCount: matching.count, isBusy: mergeInFlight,
                                   onConfirm: { confirmingRename = true })
        if !mergeCandidates.isEmpty {
            PlaceMergeSection(isBusy: mergeInFlight, onChoose: { pickingMergeTarget = true })
        }
    }

    private var mergeCandidates: [PlaceHistorySummary] {
        summariesForMerge.filter { $0.name.caseInsensitiveCompare(placeName) != .orderedSame }
    }

    private var cleanRenamedPlace: String {
        TextSafety.clean(renamedPlace, maximumLength: 120)
    }

    private func reload() {
        Task { await reloadInBackground() }
    }

    private func reloadInBackground() async {
        let generation = await InsightsAggregationActor.shared.currentGeneration()
        let reader = reader ?? VisitArchiveReader(modelContainer: context.container)
        self.reader = reader
        guard let entries = try? await reader.placeEntries(named: placeName) else { return }
        let currentGeneration = await InsightsAggregationActor.shared.currentGeneration()
        guard !Task.isCancelled, generation == currentGeneration else { return }
        matching = entries
        if renamedPlace.isEmpty { renamedPlace = placeName }
        if let summaryResult = try? await reader.placeSummaries(generation: generation) {
            summariesForMerge = summaryResult.summaries
        }
        breakdown = PlaceTimeBand.allCases.filter { $0 != .allDay }.map { slot in
            var counts: [String: Int] = [:]
            for visit in matching where slot.contains(visit.arrival) {
                counts[visit.activity, default: 0] += 1
            }
            return (slot, counts.sorted { $0.value > $1.value }.prefix(3).map { ($0.key, $0.value) })
        }
    }

    private func apply() {
        let activity = TextSafety.clean(replacement, maximumLength: 80)
        guard !activity.isEmpty else { return }
        let result = VisitMutationService.perform(context: context, kind: .bulkHistoricalCorrection) {
            var changed = 0
            var placeDescriptor = FetchDescriptor<SavedPlace>(
                predicate: #Predicate { $0.name == placeName }
            )
            placeDescriptor.fetchLimit = 1
            let mapsIdentifier = try context.fetch(placeDescriptor).first?.mapsIdentifier
            let entries: [Visit]
            if let mapsIdentifier, !mapsIdentifier.isEmpty {
                entries = try context.fetch(VisitHistoryQuery.place(mapsIdentifier: mapsIdentifier))
            } else {
                entries = try context.fetch(VisitHistoryQuery.legacyPlace(named: placeName))
            }
            for visit in entries where
                (NameKey.same(visit.placeName, placeName) || visit.mapsIdentifier == mapsIdentifier) &&
                VisitRecognitionConfidence(rawValue: visit.recognitionConfidence) != .confirmed {
                visit.userActivity = activity
                changed += 1
            }
            // A per-visit correction record for each row would add thousands of
            // rows for a single action, so the full audit records one aggregate result.
            return .init(changedCount: changed)
        }
        if result.committed {
            reload()
            let changed = result.changedCount
            message = "Updated \(changed) \(changed == 1 ? "entry" : "entries")."
        } else {
            message = "LifeLog couldn’t apply that change. Your timeline is unchanged."
        }
    }

    private func performMerge(into targetName: String) {
        mergeTarget = nil
        mergeInFlight = true
        let sourceName = placeName
        let startedAt = Date.now
        Task {
            do {
                let changed = try await PlaceRenameActor(modelContainer: context.container)
                    .renamePlace(sourceName: sourceName, targetName: targetName)
                Diagnostics.budget(context, subsystem: "Place History", operation: "place merge",
                                   startedAt: startedAt, budget: Diagnostics.PerformanceBudget.activityPlaceMerge,
                                   itemCount: changed)
                InsightsInvalidation.invalidate(reason: "Places merged from Place History", context: context)
                mergeInFlight = false
                dismiss()
            } catch is CancellationError {
                mergeInFlight = false
            } catch {
                mergeInFlight = false
                message = "LifeLog couldn’t merge this place. Nothing changed — try again."
            }
        }
    }

    private func performRename() {
        let targetName = cleanRenamedPlace
        guard !targetName.isEmpty,
              targetName.caseInsensitiveCompare(placeName) != .orderedSame else { return }
        confirmingRename = false
        mergeInFlight = true
        let sourceName = placeName
        let startedAt = Date.now
        Task {
            do {
                let changed = try await PlaceRenameActor(modelContainer: context.container)
                    .mergePlace(sourceNames: [sourceName], targetName: targetName)
                Diagnostics.budget(context, subsystem: "Place History", operation: "place rename",
                                   startedAt: startedAt, budget: Diagnostics.PerformanceBudget.activityPlaceMerge,
                                   itemCount: changed)
                InsightsInvalidation.invalidate(reason: "Place renamed from Place History", context: context)
                mergeInFlight = false
                dismiss()
            } catch is CancellationError {
                mergeInFlight = false
            } catch {
                mergeInFlight = false
                message = "LifeLog couldn’t rename this place. Nothing changed — try again."
            }
        }
    }
}

private struct PlaceHistoryAnalyticsSection: View {
    let analytics: PlaceVisitAnalytics

    var body: some View {
        Section {
            Label(analytics.lifetimeLabel, systemImage: "mappin.and.ellipse")
            if let averageStayLabel = analytics.averageStayLabel {
                Label(averageStayLabel, systemImage: "hourglass")
            }
            if let peakHourLabel = analytics.peakHourLabel {
                Label(peakHourLabel, systemImage: "clock.fill")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("place-history-analytics")
    }
}

private struct SavedPlaceContextSection: View {
    let place: SavedPlace

    var body: some View {
        Section {
            let radiusLabel = String(format: "%.0f m", place.radius)
            SavedPlaceLocationMap(place: place)
            LabeledContent("Saved radius", value: radiusLabel)
        } header: {
            Text("Saved Place location")
        } footer: {
            Text("This is the saved geofence location, not a claim that every visit happened at the exact pin.")
        }
    }
}

private struct PlaceHistoryVisitsSection: View {
    let placeName: String
    let visits: [PlaceHistoryEntry]

    var body: some View {
        Section {
            NavigationLink {
                PlaceHistoryVisitsView(placeName: placeName, visits: visits)
            } label: {
                Label("View visits", systemImage: "list.bullet.rectangle")
                Spacer()
                Text("\(visits.count)").foregroundStyle(.secondary)
            }
        } header: {
            Text("Visits")
        } footer: {
            Text("Open the visit history to review arrival time, duration, and recorded activity.")
        }
    }
}

private struct PlaceHistoryVisitsView: View {
    let placeName: String
    let visits: [PlaceHistoryEntry]

    private var recentVisits: [PlaceHistoryEntry] {
        Array(visits.sorted { $0.arrival > $1.arrival }.prefix(100))
    }

    private func activityText(_ visit: PlaceHistoryEntry) -> String {
        visit.activity.isEmpty ? "No activity" : visit.activity
    }

    var body: some View {
        List {
            ForEach(recentVisits) { visit in
                VStack(alignment: .leading, spacing: 3) {
                    Text(visit.arrival.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute()))
                        .font(.subheadline.weight(.semibold))
                    Text(visit.departure == nil ? "Still open · \(activityText(visit))" :
                         "\(formattedDuration(visit.duration)) · \(activityText(visit))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .navigationTitle("Visits")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if visits.count > recentVisits.count {
                Text("Showing the latest \(recentVisits.count) of \(visits.count) visits.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
        .accessibilityIdentifier("place-history-visits-screen")
    }
}

private struct PlaceHistoryBreakdownSection: View {
    let breakdown: [(band: PlaceTimeBand, activities: [(String, Int)])]

    var body: some View {
        Section {
            ForEach(breakdown, id: \.band) { entry in
                if !entry.activities.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.band.title).font(.subheadline.weight(.semibold))
                        ForEach(entry.activities, id: \.0) { activity, count in
                            Text("\(activity.isEmpty ? "No activity" : activity) · \(count)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("What this place looks like now")
        }
    }
}

private struct PlaceActivityCorrectionSection: View {
    @Binding var band: PlaceTimeBand
    @Binding var replacement: String
    let protectedCount: Int
    let changeableCount: Int
    let onConfirm: () -> Void

    var body: some View {
        Section {
            Picker("Apply to", selection: $band) {
                ForEach(PlaceTimeBand.allCases) { Text($0.title).tag($0) }
            }
            TextField("New activity", text: $replacement)
            NavigationLink { PlaceActivitySelection(selection: $replacement) } label: {
                Label("Choose an activity", systemImage: "list.bullet")
            }
            .accessibilityIdentifier("choose-activity-link")
            LabeledContent("Entries that will change", value: "\(changeableCount)")
            if protectedCount > 0 { LabeledContent("Kept as you set them", value: "\(protectedCount)") }
            Button("Change \(changeableCount) entries", role: .destructive, action: onConfirm)
                .disabled(changeableCount == 0 || TextSafety.clean(replacement, maximumLength: 80).isEmpty)
                .accessibilityIdentifier("bulk-change-activity")
        } header: {
            Text("Correct the activity")
        } footer: {
            Text("Entries you have confirmed individually are never changed. This rewrites many entries at once and can only be undone from a backup, so create one first if you are unsure.")
        }
    }
}

private struct PlaceNameCorrectionSection: View {
    @Binding var name: String
    let currentName: String
    let entryCount: Int
    let isBusy: Bool
    let onConfirm: () -> Void

    private var cleanName: String { TextSafety.clean(name, maximumLength: 120) }

    var body: some View {
        Section {
            TextField("New place name", text: $name)
            LabeledContent("Entries that will change", value: "\(entryCount)")
            Button("Rename \(entryCount) entries", action: onConfirm)
                .disabled(cleanName.isEmpty || cleanName.caseInsensitiveCompare(currentName) == .orderedSame || isBusy)
                .accessibilityIdentifier("rename-place-button")
        } header: {
            Text("Correct the place name")
        } footer: {
            Text("This changes the place name on every matching timeline entry, including imported history. A matching Saved Place keeps its location, radius, role, and activity.")
        }
    }
}

private struct PlaceMergeSection: View {
    let isBusy: Bool
    let onChoose: () -> Void

    var body: some View {
        Section {
            Button(action: onChoose) {
                if isBusy { HStack { ProgressView(); Text("Merging…") } }
                else { Label("Merge into another place", systemImage: "arrow.triangle.merge") }
            }
            .disabled(isBusy)
            .accessibilityIdentifier("place-history-merge-button")
        } footer: {
            Text("Moves every timeline entry recorded as this place onto the place you choose, including imported history. This cannot be undone here — export a backup first if you are unsure.")
        }
    }
}

private struct SavedPlaceLocationMap: View {
    let place: SavedPlace

    var body: some View {
        let coordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
        Map(initialPosition: .region(region(for: coordinate))) {
            Marker(place.name, coordinate: coordinate)
                .tint(.blue)
        }
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .mapControls { MapCompass(); MapUserLocationButton() }
        .accessibilityIdentifier("place-history-saved-place-map")
    }

    private func region(for coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate,
                           span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004))
    }
}

private struct PlaceHistoryMergeTargetPicker: View {
    let candidates: [PlaceHistorySummary]
    let onPick: (PlaceHistorySummary) -> Void
    @State private var search = ""

    private var filtered: [PlaceHistorySummary] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return candidates }
        return candidates.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if filtered.isEmpty {
                ContentUnavailableView("No other places", systemImage: "arrow.triangle.merge",
                                       description: Text("There’s nothing else in Place History to merge into."))
            } else {
                ForEach(filtered) { place in
                    Button {
                        onPick(place)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(place.name).foregroundStyle(.primary)
                            Text("\(place.count) \(place.count == 1 ? "entry" : "entries")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Merge into…")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Find a place")
        .accessibilityIdentifier("place-history-merge-target-picker")
    }
}
