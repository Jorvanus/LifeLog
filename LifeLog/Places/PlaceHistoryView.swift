import SwiftUI
import SwiftData

/// Lists every place name in the timeline, however it was recorded. Saved Places
/// only cover geofenced locations, and imported journal rows have no coordinates
/// at all, so this is the only route to the bulk of an imported history.
struct PlaceHistoryView: View {
    @Environment(\.modelContext) private var context
    @State private var summaries: [PlaceHistorySummary] = []
    @State private var loading = true
    @State private var search = ""
    @State private var reader: VisitArchiveReader?

    private var filtered: [PlaceHistorySummary] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return summaries }
        return summaries.filter { $0.name.lowercased().contains(query) }
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
                    Text("Sorted by how often each place appears. Open one to correct its activity across every entry at once.")
                }
            }
        }
        .navigationTitle("Place History")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Find a place")
        .accessibilityIdentifier("place-history-screen")
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
                               startedAt: startedAt, budget: 1.0, itemCount: result.itemCount)
        } catch is CancellationError {
            return
        } catch {
            loading = false
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
    let placeName: String
    @State private var band: PlaceTimeBand = .allDay
    @State private var replacement = ""
    @State private var confirming = false
    @State private var message: String?
    @State private var breakdown: [(band: PlaceTimeBand, activities: [(String, Int)])] = []
    @State private var matching: [PlaceHistoryEntry] = []
    @State private var reader: VisitArchiveReader?

    private var analytics: PlaceVisitAnalytics { PlaceVisitAnalytics.make(from: matching) }

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
            if !matching.isEmpty {
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
            Section("What this place looks like now") {
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
            }
            Section {
                Picker("Apply to", selection: $band) {
                    ForEach(PlaceTimeBand.allCases) { Text($0.title).tag($0) }
                }
                TextField("New activity", text: $replacement)
                LabeledContent("Entries that will change", value: "\(changeableCount)")
                if protectedCount > 0 {
                    LabeledContent("Kept as you set them", value: "\(protectedCount)")
                }
                Button("Change \(changeableCount) entries", role: .destructive) { confirming = true }
                    .disabled(changeableCount == 0 ||
                              TextSafety.clean(replacement, maximumLength: 80).isEmpty)
                    .accessibilityIdentifier("bulk-change-activity")
            } header: {
                Text("Correct the activity")
            } footer: {
                Text("Entries you have confirmed individually are never changed. This rewrites many entries at once and can only be undone from a backup, so create one first if you are unsure.")
            }
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
        .alert("Place history", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
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
}
