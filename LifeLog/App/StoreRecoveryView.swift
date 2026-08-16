import SwiftUI
import UIKit

struct StoreOpenError: Sendable {
    let domain: String
    let code: Int
    let storeURL: URL
    let occurredAt: Date

    init(error: Error, storeURL: URL) {
        let nsError = error as NSError
        domain = nsError.domain
        code = nsError.code
        self.storeURL = storeURL
        occurredAt = .now
    }

    var summary: String {
        "\(domain) (code \(code))"
    }
}

struct StoreRecoveryView: View {
    let failure: StoreOpenError?
    let retry: () -> Void
    @State private var reportURL: URL?
    @State private var storeCopyURL: URL?
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 48)).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .center)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Timeline needs attention")
                            .font(.largeTitle.bold())
                        Text("LifeLog couldn’t open the protected on-device timeline. Your existing store has not been deleted or overwritten.")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Try opening it again first", systemImage: "arrow.clockwise")
                            .font(.headline)
                        Text("If the phone was recently restarted or the store was temporarily protected, retrying may restore access.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Retry Opening Timeline", action: retry)
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(20)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Recovery options", systemImage: "externaldrive")
                            .font(.headline)
                        Text("Export a diagnostic report for troubleshooting. If the protected files can still be read, export a copy before attempting any further repair.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let reportURL {
                            ShareLink(item: reportURL) {
                                Label("Share Diagnostic Report", systemImage: "square.and.arrow.up")
                            }
                        } else {
                            Button("Create Diagnostic Report") { createReport() }
                        }
                        if let storeCopyURL {
                            ShareLink(item: storeCopyURL) {
                                Label("Share Protected Store Copy", systemImage: "archivebox")
                            }
                        } else {
                            Button("Export Protected Store Copy") { createStoreCopy() }
                        }
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("What to do next").font(.headline)
                        Text("Keep the app installed while recovering. Restart the iPhone, make sure it is unlocked, and try again. If the problem continues, share the report or store copy before contacting support.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let failure {
                            Text("Diagnostic: \(failure.summary)")
                                .font(.caption.monospaced()).foregroundStyle(.tertiary)
                        }
                    }
                    if let exportError {
                        Text(exportError).font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(22)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Store Recovery")
            .accessibilityIdentifier("store-recovery-screen")
        }
    }

    private func createReport() {
        do {
            ExportFileCleanup.removeExpired()
            reportURL = try StoreRecoverySupport.makeDiagnosticReport(failure: failure)
            exportError = nil
        } catch {
            exportError = "The diagnostic report couldn’t be created."
        }
    }

    private func createStoreCopy() {
        guard let failure else {
            exportError = "The protected store location is unavailable."
            return
        }
        do {
            storeCopyURL = try StoreRecoverySupport.makeStoreCopy(from: failure.storeURL, failure: failure)
            exportError = nil
        } catch {
            exportError = "The protected store could not be copied while it is locked. The original was left unchanged."
        }
    }
}

enum StoreRecoverySupport {
    /// Derived from `LifeLogMigrationPlan` -- the same source of truth
    /// `LocalBackupService` reads for its own manifest -- so a recovery report
    /// never drifts from the schema `LifeLogApp` actually opens, the way the
    /// hard-coded "LifeLogSchemaV4" text once did across seven version bumps.
    static var currentSchemaDescription: String {
        let current = LifeLogMigrationPlan.schemas.last!
        return "\(current) (\(current.versionIdentifier))"
    }

    static func makeDiagnosticReport(failure: StoreOpenError?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeLog-Recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let report = """
        LifeLog protected store recovery report
        Created: \((failure?.occurredAt ?? .now).ISO8601Format())
        Schema: \(currentSchemaDescription)
        Error: \(failure?.summary ?? "Unknown store-opening failure")
        Store copy attempted: no

        This report contains no visits, coordinates, notes, or Health data.
        """
        let url = directory.appendingPathComponent("LifeLog-recovery-report.txt")
        try report.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func makeStoreCopy(from storeURL: URL, failure: StoreOpenError) throws -> URL {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("LifeLog-Store-Recovery-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var copied = false
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.copyItem(at: source, to: directory.appendingPathComponent(source.lastPathComponent))
            copied = true
        }
        guard copied else { throw CocoaError(.fileNoSuchFile) }
        // Match the protection the live store carries -- see `StoreProtection`
        // -- so a copy exported while the device is locked doesn't ship with
        // weaker guarantees than the original it was copied from.
        StoreProtection.prepareForBackgroundAccess(storeURL: directory.appendingPathComponent(storeURL.lastPathComponent))
        let manifest = """
        LifeLog protected store recovery copy
        Schema: \(currentSchemaDescription)
        Opening diagnostic: \(failure.summary)
        Original store was copied without deletion or modification.
        """
        try manifest.write(to: directory.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        return directory
    }
}
