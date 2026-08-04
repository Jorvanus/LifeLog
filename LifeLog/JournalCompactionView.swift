import SwiftUI
import SwiftData

struct JournalCompactionView: View {
    enum Option: String, CaseIterable, Identifiable { case all, merge, trim; var id: Self { self }; var title: String { switch self { case .all: "Keep all data"; case .merge: "Merge equivalent adjacent entries"; case .trim: "Remove old or short entries" } } }
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Visit> { $0.source == "imported-journal" }, sort: \Visit.arrival) private var entries: [Visit]
    @State private var option: Option = .all
    @State private var confirming = false
    @State private var backupURL: URL?
    @State private var message: String?

    private var removable: [Visit] {
        guard option != .all else { return [] }
        var result: [Visit] = []
        for (index, entry) in entries.enumerated() {
            let short = entry.duration < 5 * 60
            let duplicate = index > 0 && entries[index - 1].displayPlaceName == entry.displayPlaceName && abs(entry.arrival.timeIntervalSince(entries[index - 1].departure ?? entry.arrival)) < 5 * 60
            if (option == .merge && duplicate) || (option == .trim && (short || duplicate)) { result.append(entry) }
        }
        return result
    }

    var body: some View {
        Form {
            Section("Imported journal") { LabeledContent("Records", value: "\(entries.count)"); LabeledContent("Estimated storage", value: ByteCountFormatter.string(fromByteCount: Int64(entries.reduce(0) { $0 + $1.note.count }), countStyle: .file)) }
            Section("Preview") {
                Picker("Retention", selection: $option) { ForEach(Option.allCases) { Text($0.title).tag($0) } }
                LabeledContent("Records removed", value: "\(removable.count)")
                LabeledContent("Estimated savings", value: ByteCountFormatter.string(fromByteCount: Int64(removable.reduce(0) { $0 + $1.note.count }), countStyle: .file))
            }
            Section { Button("Apply cleanup", role: .destructive) { confirming = true }.disabled(removable.isEmpty) } footer: { Text("Keeping all data makes no changes. Cleanup is reversible only through the backup created immediately beforehand.") }
            if let backupURL { Section("Backup created") { ShareLink(item: backupURL) { Label("Share backup", systemImage: "square.and.arrow.up") } } }
        }
        .navigationTitle("Journal Storage")
        .confirmationDialog("Back up before cleanup?", isPresented: $confirming) {
            Button("Create backup and remove \(removable.count) records", role: .destructive) { apply() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("LifeLog will create a complete local backup before deleting anything.") }
        .alert("Journal cleanup", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK", role: .cancel) { } } message: { Text(message ?? "") }
    }

    private func apply() {
        do {
            let data = try LocalBackupService.makeBackup(context: context, diagnostics: [])
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("LifeLog-Journal-Backup-\(Int(Date.now.timeIntervalSince1970)).json")
            try data.write(to: url, options: .atomic); backupURL = url
            removable.forEach(context.delete); try context.save(); message = "Cleanup complete. The backup is ready to share."
        } catch { message = "Cleanup was not applied. The backup could not be created, so your data was left unchanged." }
    }
}
