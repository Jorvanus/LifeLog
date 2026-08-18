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
    @State private var creatingBackup = false
    @State private var backupTask: Task<Void, Never>?

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
            Section("Imported journal") {
                LabeledContent("Records") {
                    Text("\(entries.count)").accessibilityIdentifier("journal-record-count")
                }
                if entries.isEmpty {
                    Text("No imported journal history.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("journal-empty-state")
                }
                LabeledContent("Estimated storage", value: ByteCountFormatter.string(fromByteCount: Int64(entries.reduce(0) { $0 + $1.note.count }), countStyle: .file))
            }
            Section("Preview") {
                Picker("Retention", selection: $option) { ForEach(Option.allCases) { Text($0.title).tag($0) } }
                LabeledContent("Records removed", value: "\(removable.count)")
                LabeledContent("Estimated savings", value: ByteCountFormatter.string(fromByteCount: Int64(removable.reduce(0) { $0 + $1.note.count }), countStyle: .file))
            }
            Section {
                if creatingBackup {
                    HStack {
                        ProgressView()
                        Text("Creating backup…").foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { backupTask?.cancel() }
                    }
                    .accessibilityIdentifier("journal-cleanup-progress")
                } else {
                    Button("Apply cleanup", role: .destructive) { confirming = true }
                        .disabled(removable.isEmpty)
                        .accessibilityIdentifier("apply-journal-cleanup")
                }
            } footer: { Text("Keeping all data makes no changes. Cleanup is reversible only through the backup created immediately beforehand.") }
            if let backupURL { Section("Backup created") { ShareLink(item: backupURL) { Label("Share backup", systemImage: "square.and.arrow.up") } } }
        }
        .navigationTitle("Journal Storage")
        .accessibilityIdentifier("journal-storage-screen")
        .confirmationDialog("Back up before cleanup?", isPresented: $confirming) {
            Button("Create backup and remove \(removable.count) records", role: .destructive) { apply() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("LifeLog will create a complete local backup before deleting anything.") }
        .alert("Journal cleanup", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK", role: .cancel) { } } message: { Text(message ?? "") }
    }

    private func apply() {
        creatingBackup = true
        let toRemove = removable
        let container = context.container
        backupTask?.cancel()
        backupTask = Task {
            let url: URL
            do {
                let data = try await BackupExportActor(modelContainer: container).makeBackup()
                try Task.checkCancellation()
                let candidateURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("LifeLog-Journal-Backup-\(Int(Date.now.timeIntervalSince1970)).json")
                try data.write(to: candidateURL, options: .atomic)
                try Task.checkCancellation()
                url = candidateURL
            } catch is CancellationError {
                await MainActor.run { creatingBackup = false }
                return
            } catch {
                await MainActor.run {
                    message = "Cleanup was not applied. The backup could not be created, so your data was left unchanged."
                    creatingBackup = false
                }
                return
            }
            await MainActor.run {
                backupURL = url
                creatingBackup = false
                toRemove.forEach(context.delete)
                do {
                    try context.save()
                    message = "Cleanup complete. The backup is ready to share."
                } catch {
                    message = "Cleanup was not applied due to an error while saving."
                }
            }
        }
    }
}
