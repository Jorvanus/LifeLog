import SwiftUI
import SwiftData

/// Offers the activities a person has actually recorded but that the catalogue has
/// never heard of. Until an activity is in the catalogue it has no category, so
/// Insights files it under "Other" — a timeline full of "Work" reads as 5 visits
/// while thousands sit unlabelled. Adopting is deliberately a choice per activity
/// rather than an automatic sweep: how often a label appears says nothing about
/// whether it is the label you meant.
struct ActivityImportView: View {
    struct Candidate: Identifiable {
        let name: String
        let count: Int
        var category: String
        var isSelected: Bool
        var id: String { name }
    }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let onAdd: ([ActivityDefinition]) -> Void

    @State private var candidates: [Candidate] = []
    @State private var loading = true

    private var selectedCount: Int { candidates.filter(\.isSelected).count }

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    HStack { ProgressView(); Text("Reading your timeline…").foregroundStyle(.secondary) }
                } else if candidates.isEmpty {
                    ContentUnavailableView("Nothing new to add", systemImage: "checkmark.circle",
                                           description: Text("Every activity in your timeline is already in the list."))
                } else {
                    Section {
                        ForEach($candidates) { $candidate in
                            VStack(alignment: .leading, spacing: 8) {
                                Button {
                                    candidate.isSelected.toggle()
                                } label: {
                                    HStack {
                                        Image(systemName: candidate.isSelected ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(candidate.isSelected ? Color.accentColor : .secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(candidate.name).font(.headline)
                                            Text("\(candidate.count) \(candidate.count == 1 ? "entry" : "entries")")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if candidate.isSelected {
                                    Picker("Group under", selection: $candidate.category) {
                                        ForEach(ActivityCatalog.categories, id: \.self) { Text($0).tag($0) }
                                    }
                                    .font(.subheadline)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("Found in your timeline")
                    } footer: {
                        Text("The group decides where Insights counts the activity. LifeLog guesses from the name; change it if the guess is wrong.")
                    }
                }
            }
            .navigationTitle("Add From History")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("activity-import-screen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(selectedCount)") { add() }.disabled(selectedCount == 0)
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        let startedAt = Date.now
        let known = Set(ActivityCatalog.load().map { $0.name.lowercased() })
        let visits = (try? context.fetch(FetchDescriptor<Visit>())) ?? []
        var counts: [String: Int] = [:]
        for visit in visits {
            let activity = visit.activity.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !activity.isEmpty, !known.contains(activity.lowercased()) else { continue }
            counts[activity, default: 0] += 1
        }
        candidates = counts.sorted { $0.value > $1.value }.map { name, count in
            Candidate(name: name, count: count,
                      category: ActivityCatalog.suggestedCategory(for: name),
                      // Pre-select what is clearly part of the person's vocabulary
                      // rather than a one-off typo, but leave the choice with them.
                      isSelected: count >= 10)
        }
        loading = false
        Diagnostics.performance(context, subsystem: "Activities", operation: "history scan",
                                startedAt: startedAt, itemCount: visits.count)
    }

    private func add() {
        let additions = candidates.filter(\.isSelected).map { candidate in
            var definition = ActivityDefinition(name: candidate.name, category: candidate.category,
                                                symbol: symbol(for: candidate.category))
            definition.colorHex = nil
            return definition
        }
        onAdd(additions)
        InsightsInvalidation.invalidate(reason: "Activity catalogue updated", context: context)
        dismiss()
    }

    private func symbol(for category: String) -> String {
        switch category {
        case "Home": "house.fill"
        case "Work": "briefcase.fill"
        case "Food & Drink": "fork.knife"
        case "Shopping": "bag.fill"
        case "Fitness": "figure.run"
        case "Healthcare": "cross.case.fill"
        case "Education": "book.fill"
        case "Travel": "car.fill"
        case "Entertainment": "film.fill"
        case "Social": "person.2.fill"
        case "Sleep": "bed.double.fill"
        default: "circle.fill"
        }
    }
}
