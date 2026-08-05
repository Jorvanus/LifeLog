import SwiftUI
import SwiftData

/// Groups decide where Insights counts time, but until now they could only be seen
/// one activity at a time, through the picker in the activity editor — there was no
/// way to ask "what is in Fitness?" or to add a group of your own. This is that view
/// of the same data, from the group's side.
struct ActivityGroupsView: View {
    @Environment(\.modelContext) private var context
    @State private var groups: [String] = ActivityCatalog.loadCategories()
    @State private var activities: [ActivityDefinition] = ActivityCatalog.load()
    @State private var adding = false
    @State private var newGroupName = ""
    @State private var renaming: RenameRequest?
    @State private var pendingDeletion: String?
    @State private var duplicateName = false

    private struct RenameRequest: Identifiable {
        let previous: String
        var updated: String
        var id: String { previous }
    }

    private func members(of group: String) -> [ActivityDefinition] {
        activities.filter { $0.category.caseInsensitiveCompare(group) == .orderedSame }
    }

    var body: some View {
        List {
            ForEach(groups, id: \.self) { group in
                Section {
                    let members = members(of: group)
                    if members.isEmpty {
                        Text("No activities yet")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ForEach(members) { activity in
                            Label {
                                Text(activity.name)
                            } icon: {
                                Image(systemName: activity.symbol)
                                    .foregroundStyle(activityColor(activity.name))
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(group)
                        Spacer()
                        // The fallback group cannot be renamed or removed: deleting a
                        // group has to leave its activities somewhere.
                        if group != ActivityCatalog.fallbackCategory {
                            Menu {
                                Button("Rename group") {
                                    renaming = RenameRequest(previous: group, updated: group)
                                }
                                Button("Delete group", role: .destructive) {
                                    pendingDeletion = group
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .accessibilityLabel("Edit \(group)")
                            }
                            .accessibilityIdentifier("group-menu-\(group)")
                        }
                    }
                }
            }
            Section {
                EmptyView()
            } footer: {
                Text("An activity belongs to one group, set when you open the activity. Renaming a group brings its activities with it; deleting one moves them to \(ActivityCatalog.fallbackCategory), where they are still counted.")
            }
        }
        .navigationTitle("Groups")
        .accessibilityIdentifier("activity-groups-screen")
        .toolbar {
            // In the toolbar rather than at the end of the list: with a dozen groups
            // each listing its activities, a button below them all is several screens
            // down, and SwiftUI has not even built it until you scroll there.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newGroupName = ""
                    adding = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add group")
                .accessibilityIdentifier("add-group")
            }
        }
        .onAppear(perform: reload)
        .alert("Add group", isPresented: $adding) {
            TextField("Group name", text: $newGroupName)
            Button("Cancel", role: .cancel) { }
            Button("Add") {
                guard ActivityCatalog.addCategory(newGroupName) else {
                    duplicateName = true
                    return
                }
                reload()
            }
        } message: {
            Text("Groups are how Insights adds your time up.")
        }
        .alert("Rename group", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Group name", text: Binding(
                get: { renaming?.updated ?? "" },
                set: { renaming?.updated = $0 }
            ))
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                guard let request = renaming else { return }
                renaming = nil
                ActivityCatalog.renameCategory(from: request.previous, to: request.updated)
                reload()
                InsightsInvalidation.invalidate(reason: "Activity group renamed", context: context)
            }
        } message: {
            if let request = renaming {
                let count = members(of: request.previous).count
                Text(count == 0
                     ? "No activities are in this group yet."
                     : "\(count) \(count == 1 ? "activity moves" : "activities move") with it, and Insights re-counts their visits straight away.")
            }
        }
        .alert("That group already exists", isPresented: $duplicateName) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Two groups with the same name would split the same time in two.")
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete group", role: .destructive) {
                guard let group = pendingDeletion else { return }
                pendingDeletion = nil
                ActivityCatalog.deleteCategory(group)
                reload()
                InsightsInvalidation.invalidate(reason: "Activity group deleted", context: context)
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Its activities keep their labels and move to \(ActivityCatalog.fallbackCategory).")
        }
    }

    private var deletionTitle: String {
        guard let group = pendingDeletion else { return "" }
        let count = members(of: group).count
        return count == 0
            ? "Delete “\(group)”?"
            : "Delete “\(group)” and move \(count) \(count == 1 ? "activity" : "activities")?"
    }

    private func reload() {
        groups = ActivityCatalog.loadCategories()
        activities = ActivityCatalog.load()
    }
}
