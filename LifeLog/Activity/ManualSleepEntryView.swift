import SwiftUI
import SwiftData

/// A deliberate fallback for nights without a wearable or another Health source.
/// It records what the person says happened; it never upgrades an empty phone trace
/// into invented sleep.
struct ManualSleepEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var start = ManualSleepEntryView.defaultStart
    @State private var end = ManualSleepEntryView.defaultEnd
    @State private var saveFailed = false

    private static var defaultStart: Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return calendar.date(byAdding: .hour, value: -1, to: today) ?? today
    }

    private static var defaultEnd: Date {
        Calendar.current.startOfDay(for: .now)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Use this when you slept without wearing your Watch or another tracker. This is your confirmed record, not a measurement.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Last night") {
                    DatePicker("Fell asleep", selection: $start)
                    DatePicker("Woke up", selection: $end)
                }
            }
            .navigationTitle("Add sleep")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(end <= start)
                }
            }
            .alert("Couldn’t save sleep", isPresented: $saveFailed) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("LifeLog left your existing timeline unchanged.")
            }
        }
    }

    private func save() {
        context.insert(Visit(arrival: start, departure: end,
                             latitude: 0, longitude: 0,
                             placeName: "Sleep", inferredActivity: "Sleeping",
                             userActivity: "Sleeping", source: SleepEvidence.manualSource,
                             recognitionConfidence: "confirmed"))
        do {
            try context.save()
            InsightsInvalidation.invalidate(reason: "Manual sleep added", context: context)
            dismiss()
        } catch {
            saveFailed = true
        }
    }
}
