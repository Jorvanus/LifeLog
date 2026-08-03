import SwiftUI

/// Full-screen activity picker used by Saved Places. Keeping this as a page
/// makes the same editable activity vocabulary available without a cramped menu.
struct PlaceActivitySelection: View {
    @Environment(\.dismiss) private var dismiss
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
                Text("Activities are shared with the Activities list in Settings and can be reused across Saved Places and visits.")
            }
        }
        .navigationTitle("Choose activity")
        .task { ActivityCatalog.seed(); activities = ActivityCatalog.load() }
        .sheet(isPresented: $adding) {
            ActivityEditor { newActivity in
                activities.append(newActivity)
                ActivityCatalog.save(activities)
                selection = newActivity.name
                adding = false
            }
        }
    }
}
