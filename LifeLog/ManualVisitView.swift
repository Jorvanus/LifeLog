import SwiftUI
import SwiftData

struct ManualVisitView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var place = ""
    @State private var activity = ""
    @State private var arrival = Date()
    @State private var departure = Date()
    @State private var saveFailed = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Place", text: $place)
                TextField("What were you doing?", text: $activity)
                DatePicker("Arrived", selection: $arrival)
                DatePicker("Left", selection: $departure)
            }
            .navigationTitle("Add visit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(place.isEmpty) }
            }
            .alert("Couldn’t save visit", isPresented: $saveFailed) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("LifeLog left your existing timeline unchanged.")
            }
        }
    }

    private func save() {
        let safePlace = TextSafety.clean(place, maximumLength: 120)
        let safeActivity = TextSafety.clean(activity, maximumLength: 80)
        let safeDeparture = max(arrival, departure)
        context.insert(Visit(arrival: arrival, departure: safeDeparture, latitude: 0, longitude: 0,
                             placeName: safePlace, inferredActivity: safeActivity.isEmpty ? "Visiting" : safeActivity,
                             userActivity: safeActivity, source: "manual"))
        do {
            try context.save()
            dismiss()
        } catch {
            saveFailed = true
        }
    }
}
