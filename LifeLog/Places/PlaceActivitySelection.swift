import SwiftUI
import SwiftData

/// Full-screen activity picker used by Saved Places. Keeping this as a page
/// makes the same editable activity vocabulary available without a cramped menu.
struct PlaceActivitySelection: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Binding var selection: String
    @State private var activities = ActivityCatalog.load()
    @State private var adding = false

    var body: some View {
        List {
            Section("Activities") {
                Button("No default activity") { selection = ""; dismiss() }
                ForEach(activities) { activity in
                    Button {
                        selection = activity.name
                        dismiss()
                    } label: {
                        Label(activity.name, systemImage: activity.symbol)
                            .foregroundStyle(.primary)
                    }
                }
            }
            Section {
                Button { adding = true } label: { Label("Create activity", systemImage: "plus.circle") }
            } footer: {
                Text("Activities are shared with Activity Labels in Settings and can be reused across Saved Places and visits.")
            }
        }
        .navigationTitle("Choose Activity")
        // Seeding itself now happens once, unconditionally, at app launch
        // (`RootView`'s `.task`) — this only needs its own local copy.
        .task { activities = ActivityCatalog.load() }
        .sheet(isPresented: $adding) {
            ActivityEditor { newActivity in
                activities.append(newActivity)
                guard (try? ActivityCatalog.save(activities, context: context)) != nil else {
                    activities = ActivityCatalog.load()
                    return
                }
                selection = newActivity.name
                adding = false
            }
        }
    }
}
