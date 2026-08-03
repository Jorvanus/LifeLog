import SwiftUI
import SwiftData

struct DiagnosticsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \DiagnosticEvent.createdAt, order: .reverse) private var diagnostics: [DiagnosticEvent]
    @State private var reportURL: URL?

    var body: some View {
        List {
            Section("Summary") {
                LabeledContent("Events retained", value: "\(diagnostics.count)")
                LabeledContent("Subsystems", value: "\(Set(diagnostics.map(\.subsystem)).count)")
                LabeledContent("Slow or over-budget", value: "\(diagnostics.filter { $0.message.localizedCaseInsensitiveContains(\"slow\") || $0.message.localizedCaseInsensitiveContains(\"over budget\") }.count)")
            }
            Section("Events") {
                if diagnostics.isEmpty { Text("No diagnostic events recorded.").foregroundStyle(.secondary) }
                ForEach(diagnostics) { event in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(event.subsystem).font(.caption.bold()); Spacer(); Text(event.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary) }
                        Text(event.message).font(.footnote)
                    }
                }
                if !diagnostics.isEmpty { Button("Clear Diagnostics", role: .destructive) { diagnostics.forEach(context.delete) } }
            }
            Section("Share") {
                Button {
                    let data = Diagnostics.makePerformanceReport(events: diagnostics)
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("LifeLog-Performance-Report.json")
                    try? data.write(to: url, options: .atomic); reportURL = url
                } label: { Label("Create performance report", systemImage: "chart.bar.doc.horizontal") }
                if let reportURL { ShareLink(item: reportURL) { Label("Share performance report", systemImage: "square.and.arrow.up") } }
                Text("Reports contain only aggregate timings, counts, app version, and device/OS class—not coordinates, place names, notes, or Health values.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Diagnostics")
    }
}
