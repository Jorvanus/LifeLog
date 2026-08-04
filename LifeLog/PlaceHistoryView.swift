import SwiftUI
import SwiftData

/// Time-of-day buckets for scoping a bulk change. A single place often means two
/// different things depending on the hour — a home address is "Sleeping" overnight
/// and "At home" the rest of the day — so replacing every entry at once would
/// destroy a distinction the history already records correctly.
enum PlaceTimeBand: String, CaseIterable, Identifiable {
    case allDay, night, morning, day, evening, lateNight
    var id: Self { self }

    var title: String {
        switch self {
        case .allDay: "Any time"
        case .night: "00:00–06:00"
        case .morning: "06:00–11:00"
        case .day: "11:00–17:00"
        case .evening: "17:00–22:00"
        case .lateNight: "22:00–24:00"
        }
    }

    func contains(_ date: Date) -> Bool {
        guard self != .allDay else { return true }
        let hour = Calendar.current.component(.hour, from: date)
        switch self {
        case .allDay: return true
        case .night: return hour < 6
        case .morning: return hour >= 6 && hour < 11
        case .day: return hour >= 11 && hour < 17
        case .evening: return hour >= 17 && hour < 22
        case .lateNight: return hour >= 22
        }
    }
}

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
        let visits = (try? context.fetch(FetchDescriptor<Visit>())) ?? []
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

private struct PlaceHistoryDetail: View {
    @Environment(\.modelContext) private var context
    let placeName: String
    @State private var band: PlaceTimeBand = .allDay
    @State private var replacement = ""
    @State private var confirming = false
    @State private var message: String?
    @State private var breakdown: [(band: PlaceTimeBand, activities: [(String, Int)])] = []
    @State private var matching: [Visit] = []

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
        let name = placeName
        matching = (try? context.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.placeName == name }
        ))) ?? []
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
        var changed = 0
        for visit in scoped where visit.recognitionConfidence != "confirmed" {
            visit.userActivity = activity
            changed += 1
        }
        do {
            try context.save()
            // A per-visit correction record for each row would add thousands of
            // rows for a single action, so the audit is one diagnostic entry and
            // the backup taken beforehand.
            Diagnostics.record(context, subsystem: "Place History",
                               message: "Bulk activity change applied to \(changed) entries.",
                               severity: "info")
            InsightsInvalidation.invalidate(reason: "Place history bulk edit", context: context)
            reload()
            message = "Updated \(changed) \(changed == 1 ? "entry" : "entries")."
        } catch {
            message = "LifeLog couldn’t apply that change. Your timeline is unchanged."
        }
    }
}
