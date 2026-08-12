import SwiftUI
import SwiftData
import Charts

/// One activity in depth: how it moved over time, how it compares with the period
/// before, where it happens, and the totals underneath — plus, for one already in
/// the catalogue, everything about it that can be changed.
///
/// Used to be two screens: this one, read-only, reached from the Activities tab;
/// and a separate editor for name/colour/category/icon, reached only from Settings.
/// The stats told you what an activity was doing and the editor told you what it
/// looked like, and neither could answer the other's question — editing meant
/// leaving the page you were already looking at to find the same activity again
/// in a different tab. One screen now does both.
struct ActivityDetailView: View {
    let activityName: String
    var symbol: String = "circle.fill"
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var candidates: [Visit]
    @State private var window: Window = .week
    @State private var now = Date.now
    /// Held in state rather than read inline, so adopting updates this page in place
    /// instead of leaving the offer sitting there once it has been taken.
    @State private var isAdopted = true

    // Editable only once adopted -- an unadopted label has no catalogue entry yet
    // for any of this to belong to.
    @State private var existingID: UUID?
    @State private var name = ""
    @State private var category = "Other"
    @State private var editSymbol = "circle.fill"
    @State private var categoryColorValue: Color = .gray
    @State private var loadedEditableState = false

    @State private var confirmingDelete = false
    @State private var renameRequest: RenameRequest?
    @State private var renameFailed = false

    struct RenameRequest: Identifiable {
        let definition: ActivityDefinition
        let previousName: String
        let count: Int
        /// Set when the new name already belongs to another activity. Renaming into
        /// an existing name is a merge, not a rename.
        let mergesInto: ActivityDefinition?
        var id: String { previousName }
    }

    enum Window: String, CaseIterable, Identifiable {
        case week = "7 days"
        case month = "30 days"
        case quarter = "90 days"

        var days: Int {
            switch self {
            case .week: 7
            case .month: 30
            case .quarter: 90
            }
        }
        var id: String { rawValue }
    }

    init(activityName: String, symbol: String = "circle.fill") {
        self.activityName = activityName
        self.symbol = symbol
        let name = activityName
        // Keep this identity predicate centralised with the other bounded history
        // fetches instead of letting each detail screen grow its own broad query.
        _candidates = Query(VisitHistoryQuery.activity(named: name))
    }

    private var statistics: ActivityStatistics {
        ActivityStatistics.make(activity: activityName, visits: candidates,
                                days: window.days, now: now)
    }

    var body: some View {
        List {
            // First, because it is the only thing on this screen that needs doing. The
            // row that led here says the label is not an activity yet; until this
            // existed, tapping that message arrived somewhere that could not act on it,
            // and the only remedy was a swipe mentioned once in a footer.
            if !isAdopted {
                adoption
            } else {
                editable
            }
            if statistics.isEmpty {
                ContentUnavailableView("Nothing recorded yet", systemImage: "chart.line.uptrend.xyaxis",
                                       description: Text("When your timeline uses “\(activityName)”, its history appears here."))
            } else {
                overTime
                comparison
                places
                totals
                history
                usage
            }
            if isAdopted {
                deletion
            }
        }
        .navigationTitle(activityName)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("activity-detail-screen")
        .toolbar {
            if isAdopted {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { attemptSave() }
                        .disabled(TextSafety.clean(name, maximumLength: 80).isEmpty)
                }
            }
        }
        .onAppear {
            now = .now
            isAdopted = ActivityCatalog.isAdopted(activityName)
            if isAdopted, !loadedEditableState {
                loadEditableState()
                loadedEditableState = true
            }
        }
        .alert("The visits kept the old name", isPresented: $renameFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The activity was renamed, but its visits could not be written just now. Rename it again to bring them across.")
        }
        .confirmationDialog("Delete activity?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete anyway", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(deletionWarning)
        }
        .confirmationDialog(renameTitle, isPresented: Binding(
            get: { renameRequest != nil },
            set: { if !$0 { renameRequest = nil } })
        ) {
            if let request = renameRequest {
                if request.mergesInto != nil {
                    Button("Merge into “\(request.definition.name)”") {
                        commitRename(request, updatingVisits: true)
                    }
                } else {
                    Button("Rename \(request.count) \(request.count == 1 ? "visit" : "visits")") {
                        commitRename(request, updatingVisits: true)
                    }
                    Button("Leave visits as they are") {
                        commitRename(request, updatingVisits: false)
                    }
                }
                Button("Cancel", role: .cancel) { renameRequest = nil }
            }
        } message: {
            if let request = renameRequest {
                if request.mergesInto != nil {
                    Text("“\(request.definition.name)” already exists. Merging moves \(request.count) \(request.count == 1 ? "visit" : "visits") onto it and removes the duplicate, so the list keeps one entry per activity.")
                } else {
                    Text("\(request.count) \(request.count == 1 ? "visit is" : "visits are") labelled “\(request.previousName)”. Left alone they keep the old label and Insights counts them as Other.")
                }
            }
        }
    }

    private var adoption: some View {
        Section {
            Button {
                guard ActivityCatalog.adoptFromHistory(activityName) else { return }
                // Grouping is computed rather than stored, so adopting re-buckets every
                // visit already carrying this label. Insights has to be told.
                InsightsInvalidation.invalidate(reason: "Activity adopted from history", context: context)
                isAdopted = true
                loadEditableState()
                loadedEditableState = true
            } label: {
                Label("Add to Activities", systemImage: "plus.circle.fill")
                    .font(.body.weight(.semibold))
            }
            .accessibilityIdentifier("adopt-activity-button")
        } header: {
            Text("From your history")
        } footer: {
            Text("“\(activityName)” comes from your recorded visits and is not in your activity list yet, so it has no group, icon or colour of its own. Adding it gives it all three — and Insights will stop counting it as Other.")
        }
    }

    private var editable: some View {
        Section {
            TextField("Activity name", text: $name)
            ColorPicker("Activity colour", selection: $categoryColorValue, supportsOpacity: false)
            Picker("Group under", selection: $category) {
                ForEach(ActivityCatalog.categories, id: \.self) { Text($0).tag($0) }
            }
            NavigationLink {
                ActivityIconPicker(symbol: $editSymbol, tint: categoryColorValue)
            } label: {
                LabeledContent("Icon") {
                    Image(systemName: editSymbol).foregroundStyle(categoryColorValue)
                }
            }
            .accessibilityIdentifier("activity-icon-link")
        } footer: {
            Text("The group decides where Insights counts the time, and changing it re-counts existing visits straight away. Renaming offers to bring its visits with it.")
        }
    }

    private var overTime: some View {
        Section {
            Picker("Period", selection: $window) {
                ForEach(Window.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Chart(statistics.recentDays) { day in
                BarMark(x: .value("Day", day.day, unit: .day),
                        y: .value("Hours", day.hours))
                    .foregroundStyle(activityColor(activityName))
            }
            .frame(height: 160)
            .chartYAxis { AxisMarks(position: .leading) }
            .accessibilityLabel("\(activityName) over the last \(window.rawValue)")
        } header: {
            Text("Over time")
        }
    }

    private var comparison: some View {
        Section {
            LabeledContent("This \(window.rawValue)", value: formattedDuration(statistics.currentPeriodTime))
            LabeledContent("Previous \(window.rawValue)", value: formattedDuration(statistics.previousPeriodTime))
            if let change = statistics.changeFraction {
                LabeledContent("Change") {
                    Label(percentage(change), systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .foregroundStyle(change >= 0 ? .green : .orange)
                }
            }
            LabeledContent("Average per day", value: formattedDuration(statistics.averagePerDay))
            LabeledContent("Average per week", value: formattedDuration(statistics.averagePerWeek))
        } header: {
            Text("Compared with before")
        } footer: {
            if statistics.changeFraction == nil {
                Text("There is nothing recorded in the previous period to compare with.")
            }
        }
    }

    private var places: some View {
        Section("Top locations") {
            ForEach(statistics.places.prefix(8)) { place in
                LabeledContent(place.name, value: "\(place.occasions)")
            }
        }
    }

    private var totals: some View {
        Section("Totals") {
            LabeledContent("Total occasions", value: "\(statistics.occasions)")
            LabeledContent("Total time", value: formattedDuration(statistics.totalTime))
            LabeledContent("Average", value: formattedDuration(statistics.averageTime))
            LabeledContent("Shortest", value: formattedDuration(statistics.shortestTime))
            LabeledContent("Longest", value: formattedDuration(statistics.longestTime))
        }
    }

    /// Exact match on top of the loose fetch: `candidates` is narrowed in the
    /// store first, since SwiftData cannot filter on the computed `activity`
    /// property, then matched precisely here — the same two-step `visits` used
    /// to do on its own before moving in from the old activity editor.
    private var matchingVisits: [Visit] {
        let key = activityName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return candidates.filter {
            $0.activity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
        }
    }

    @ViewBuilder private var history: some View {
        if !matchingVisits.isEmpty {
            Section {
                NavigationLink {
                    ActivityVisitsView(activityName: activityName, visits: matchingVisits)
                } label: {
                    LabeledContent("History", value: "\(matchingVisits.count) \(matchingVisits.count == 1 ? "visit" : "visits")")
                }
                .accessibilityIdentifier("activity-visits-link")
            } footer: {
                Text("Open to review them, or correct one on its own without changing the rest.")
            }
        }
    }

    @ViewBuilder private var usage: some View {
        Section {
            if let first = statistics.firstUsed {
                Text(usageSentence(occasions: statistics.occasions, first: first))
            }
            if let last = statistics.lastUsed {
                Text("Last used on \(last.formatted(date: .long, time: .omitted)).")
            }
        } header: {
            Text("Usage")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var deletion: some View {
        Section {
            Button("Delete Activity", role: .destructive) { confirmingDelete = true }
                .accessibilityIdentifier("delete-activity")
        } footer: {
            Text(statistics.occasions > 0
                 ? "Its visits keep their label, but Insights counts them as “Other” until an activity with this name exists again."
                 : "Nothing in your timeline uses this activity.")
        }
    }

    /// Reads as a sentence rather than a field, because a single use is worth saying
    /// out loud: it is usually the sign of a label that was created and then forgotten.
    private func usageSentence(occasions: Int, first: Date) -> String {
        let date = first.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        return occasions == 1
            ? "This activity was used once, on \(date)."
            : "First used on \(date), \(occasions) times since."
    }

    private func percentage(_ change: Double) -> String {
        let magnitude = abs(change) * 100
        let rounded = magnitude >= 10 ? String(format: "%.0f", magnitude) : String(format: "%.1f", magnitude)
        return "\(change >= 0 ? "+" : "−")\(rounded)%"
    }

    private func loadEditableState() {
        guard let definition = ActivityCatalog.load().first(where: {
            $0.name.caseInsensitiveCompare(activityName) == .orderedSame
        }) else { return }
        existingID = definition.id
        name = definition.name
        category = definition.category
        editSymbol = definition.symbol
        categoryColorValue = activityColor(definition.name)
    }

    private func attemptSave() {
        let cleanName = TextSafety.clean(name, maximumLength: 80)
        let cleanCategory = TextSafety.clean(category, maximumLength: 40)
        let cleanSymbol = TextSafety.clean(editSymbol, maximumLength: 60)
        guard !cleanName.isEmpty else { return }
        var definition = ActivityDefinition(id: existingID ?? UUID(), name: cleanName,
                                  category: cleanCategory.isEmpty ? "Other" : cleanCategory,
                                  symbol: cleanSymbol.isEmpty ? "circle.fill" : cleanSymbol)
        definition.colorHex = activityColorHex(categoryColorValue)

        let previousName = activityName
        let renamed = previousName.caseInsensitiveCompare(cleanName) != .orderedSame
        // A rename leaves every existing visit holding the old wording, orphaned from
        // the catalogue. Offer to carry them across rather than silently stranding them.
        let collision = ActivityCatalog.load().first {
            $0.id != definition.id && $0.name.caseInsensitiveCompare(cleanName) == .orderedSame
        }
        if renamed, statistics.occasions > 0 || collision != nil {
            renameRequest = RenameRequest(definition: definition, previousName: previousName,
                                          count: statistics.occasions, mergesInto: collision)
            return
        }
        saveActivityColor(categoryColorValue, forActivity: cleanName)
        commit(definition)
    }

    private func commit(_ definition: ActivityDefinition) {
        var activities = ActivityCatalog.load()
        if let index = activities.firstIndex(where: { $0.id == definition.id }) {
            activities[index] = definition
        } else {
            activities.append(definition)
        }
        ActivityCatalog.save(activities)
        InsightsInvalidation.invalidate(reason: "Activity definition changed", context: context)
        dismiss()
    }

    private func commitRename(_ request: RenameRequest, updatingVisits: Bool) {
        renameRequest = nil
        if let target = request.mergesInto {
            // Keep the entry that was already there, with its group and colour, and
            // drop the one being renamed onto it.
            var activities = ActivityCatalog.load()
            activities.removeAll { $0.id == request.definition.id }
            ActivityCatalog.save(activities)
            if updatingVisits {
                applyVisitRename(from: request.previousName, to: target.name)
            }
        } else {
            saveActivityColor(categoryColorValue, forActivity: request.definition.name)
            var activities = ActivityCatalog.load()
            if let index = activities.firstIndex(where: { $0.id == request.definition.id }) {
                activities[index] = request.definition
            } else {
                activities.append(request.definition)
            }
            ActivityCatalog.save(activities)
            if updatingVisits {
                applyVisitRename(from: request.previousName, to: request.definition.name)
            }
        }
        InsightsInvalidation.invalidate(reason: "Activity renamed", context: context)
        dismiss()
    }

    private func applyVisitRename(from previousName: String, to updatedName: String) {
        do {
            _ = try ActivityCatalog.renameActivity(from: previousName, to: updatedName, context: context)
        } catch {
            // The catalogue entry is renamed either way, so staying silent would
            // leave every visit behind under the old label while the screen said
            // they had come across — the exact stranding this option prevents.
            renameFailed = true
        }
    }

    private func delete() {
        var activities = ActivityCatalog.load()
        activities.removeAll { $0.id == existingID }
        ActivityCatalog.save(activities)
        InsightsInvalidation.invalidate(reason: "Activity deleted", context: context)
        dismiss()
    }

    private var renameTitle: String {
        renameRequest?.mergesInto == nil ? "Rename its visits too?" : "Merge these activities?"
    }

    private var deletionWarning: String {
        "“\(activityName)” is used by \(statistics.occasions) \(statistics.occasions == 1 ? "visit" : "visits"). Deleting does not change those visits, but Insights will count them as Other until the activity exists again. Changing its group instead keeps the history counted."
    }
}

/// Every visit currently labelled with one activity, newest first, each opening the
/// normal visit editor. Matching mirrors `Visit.activity`: an explicit choice wins,
/// and the inferred value only counts when no explicit one was made — so this list
/// always agrees with the count shown alongside it. The list itself comes from the
/// caller, already fetched and matched, rather than this view repeating the same
/// query `ActivityDetailView` just ran.
private struct ActivityVisitsView: View {
    let activityName: String
    let visits: [Visit]

    var body: some View {
        List {
            if visits.isEmpty {
                ContentUnavailableView("No visits use this", systemImage: "clock.badge.questionmark",
                                       description: Text("Nothing in your timeline is labelled “\(activityName)” right now."))
            } else {
                Section {
                    ForEach(visits) { visit in
                        NavigationLink { VisitEditor(visit: visit) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(visit.displayPlaceName).font(.headline).lineLimit(1)
                                Text(visit.arrival.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Editing one visit changes only that visit. To change them all at once, use Place History for a place, or rename the activity itself.")
                }
            }
        }
        .navigationTitle(activityName)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("activity-visits-screen")
    }
}
