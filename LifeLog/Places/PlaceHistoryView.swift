import SwiftUI
import SwiftData

struct PlaceHistorySummary: Identifiable {
    let name: String
    let count: Int
    let dominantActivity: String
    let dominantShare: Int
    var id: String { name }
}

/// Lists every place name in the timeline, however it was recorded. Saved Places
/// only cover geofenced locations, and imported journal rows have no coordinates
/// at all, so this is the only route to the bulk of an imported history.
struct PlaceHistoryView: View {
    @Environment(\.modelContext) private var context
    @State private var summaries: [PlaceHistorySummary] = []
    @State private var loading = true
    @State private var search = ""

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
        // One full pass is unavoidable: SwiftData cannot group, and the names live
        // across every source. This is a Settings screen rather than the launch
        // path, and the result is cached in state for the life of the screen.
        let allVisits = (try? context.fetch(FetchDescriptor<Visit>())) ?? []
        // Place History is a route from Insights as well as Settings. Keep its
        // summary aligned with the same source visibility policy: imported journal
        // and device records remain eligible when Insights says they are, while
        // ignored/superseded records never become a misleading place result.
        let locationVisits = allVisits.filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
        let visits = allVisits.filter {
            ActivityLocationPolicy.shouldShowInInsights($0, locationVisits: locationVisits)
        }
        var counts: [String: [String: Int]] = [:]
        for visit in visits {
            let name = visit.placeName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !Visit.isPlaceholderName(name), name != "Imported journal" else { continue }
            counts[name, default: [:]][visit.activity, default: 0] += 1
        }
        summaries = counts.map { name, activities in
            let total = activities.values.reduce(0, +)
            let top = activities.max { $0.value < $1.value }
            return PlaceHistorySummary(
                name: name, count: total,
                dominantActivity: top?.key.isEmpty == false ? top!.key : "no activity",
                dominantShare: total > 0 ? Int((Double(top?.value ?? 0) / Double(total) * 100).rounded()) : 0
            )
        }.sorted { $0.count > $1.count }
        loading = false
        Diagnostics.performance(context, subsystem: "Place History", operation: "summary",
                                startedAt: startedAt, itemCount: visits.count)
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

    static func make(from visits: [Visit]) -> PlaceVisitAnalytics {
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
    @State private var matching: [Visit] = []

    private var analytics: PlaceVisitAnalytics { PlaceVisitAnalytics.make(from: matching) }

    /// A person's own choice is never overwritten by a bulk change.
    private var protectedCount: Int {
        scoped.filter { $0.recognitionConfidence == "confirmed" }.count
    }
    private var scoped: [Visit] {
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
        // SwiftData's string predicate cannot express NameKey's accent and
        // whitespace normalization, so fetch the names and apply the shared
        // fallback identity in memory. This keeps bulk corrections consistent
        // with the other place-history consumers.
        let allVisits = (try? context.fetch(FetchDescriptor<Visit>())) ?? []
        let locationVisits = allVisits.filter { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored }
        let visits = allVisits.filter {
            ActivityLocationPolicy.shouldShowInInsights($0, locationVisits: locationVisits)
        }
        matching = visits.filter { NameKey.same($0.placeName, placeName) }
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
            for visit in scoped where visit.recognitionConfidence != "confirmed" {
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
