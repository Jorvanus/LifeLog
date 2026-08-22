import Foundation
import Testing
@testable import LifeLog

struct ExportFileStagingTests {
    @Test("Staging writes complete-protected temporary files")
    func writesProtectedStagingFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeLog-export-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("LifeLog-Backup-test.json")

        try ExportFileStaging.write(Data("backup".utf8), to: url)

        #expect(ExportFileStaging.isUsable(url))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #if targetEnvironment(simulator)
        // The Simulator has no Secure Enclave-backed key hierarchy, so Data
        // Protection classes are not enforced there: `setAttributes` accepts
        // `.protectionKey` without error (verified above, by `write` not
        // throwing), but the class itself is never actually persisted or
        // echoed back by `attributesOfItem`. Only a real device can verify the
        // class was truly applied.
        #else
        #expect(attributes[.protectionKey] as? FileProtectionType == .complete)
        #endif
    }

    @Test("Staging distinguishes a missing temporary file from a usable one")
    func missingStagingFileIsNotUsable() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeLog-missing-(UUID().uuidString).json")
        #expect(!ExportFileStaging.isUsable(url))
    }

    @Test("Cleanup makes matching files eligible only after the 24-hour threshold")
    func cleanupUsesEligibilityThreshold() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeLog-Backup-cleanup-(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("backup".utf8).write(to: url)
        let old = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)

        ExportFileCleanup.removeExpired(now: old.addingTimeInterval(ExportFileCleanup.maximumAge - 1),
                                        fileManager: FileManager.default)
        #expect(FileManager.default.fileExists(atPath: url.path))
        ExportFileCleanup.removeExpired(now: old.addingTimeInterval(ExportFileCleanup.maximumAge + 1),
                                        fileManager: FileManager.default)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
