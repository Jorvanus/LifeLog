import SwiftUI
import SwiftData

struct DiagnosticsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \DiagnosticEvent.createdAt, order: .reverse) private var diagnostics: [DiagnosticEvent]
    @State private var reportURL: URL?
    @State private var confirmingClear = false
    @State private var message: String?

    var body: some View {
        List {
            Section("Summary") {
                LabeledContent("Events retained", value: "\(diagnostics.count)")
                LabeledContent("Subsystems", value: "\(Set(diagnostics.map(\.subsystem)).count)")
                LabeledContent("Slow or over-budget", value: "\(diagnostics.filter { $0.message.localizedCaseInsensitiveContains("slow") || $0.message.localizedCaseInsensitiveContains("over budget") }.count)")
            }
            // Both actions sit above the event list. The store keeps hundreds of
            // events, so anything below it is effectively unreachable without
            // scrolling the whole history first.
            Section {
                Button {
                    createReport()
                } label: { Label("Create performance report", systemImage: "chart.bar.doc.horizontal") }
                if let reportURL {
                    ShareLink(item: reportURL) { Label("Share performance report", systemImage: "square.and.arrow.up") }
                }
                Button("Clear diagnostics", role: .destructive) { confirmingClear = true }
                    .disabled(diagnostics.isEmpty)
                    .accessibilityIdentifier("clear-diagnostics")
            } footer: {
                Text("Reports contain only aggregate timings, counts, app version, and device/OS class—not coordinates, place names, notes, or Health values.")
            }
            Section("Events") {
                if diagnostics.isEmpty { Text("No diagnostic events recorded.").foregroundStyle(.secondary) }
                ForEach(diagnostics) { event in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(event.subsystem).font(.caption.bold()); Spacer(); Text(event.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary) }
                        Text(event.message).font(.footnote)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .accessibilityIdentifier("diagnostics-screen")
        .confirmationDialog("Clear diagnostics?", isPresented: $confirmingClear) {
            Button("Clear \(diagnostics.count) events", role: .destructive) { clear() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Diagnostics are how a background problem is traced after the fact. Clearing them cannot be undone, and a performance report made afterwards will have nothing to describe.")
        }
        .alert("Diagnostics", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func createReport() {
        ExportFileCleanup.removeExpired()
        let data = Diagnostics.makePerformanceReport(events: diagnostics)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LifeLog-Performance-Report.json")
        do {
            // Written with complete protection: the report is aggregate-only, but it
            // still describes this device and stays in the temporary directory until
            // it is shared or expires.
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            reportURL = url
        } catch {
            message = "LifeLog couldn’t write the performance report."
        }
    }

    private func clear() {
        for event in diagnostics { context.delete(event) }
        do {
            // The deletes were previously left to autosave, so a clear could appear to
            // work and then reappear on the next launch.
            try context.save()
        } catch {
            message = "LifeLog couldn’t clear the diagnostics."
        }
    }
}
