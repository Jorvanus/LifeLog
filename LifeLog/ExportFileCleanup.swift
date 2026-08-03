import Foundation

/// Keeps share staging files short-lived and bounded. Export contents remain in
/// the user's control after sharing; only temporary copies created by LifeLog
/// are removed automatically.
enum ExportFileCleanup {
    static let maximumAge: TimeInterval = 24 * 60 * 60
    private static let prefixes = ["lifelog-", "LifeLog-"]

    static func removeExpired(now: Date = .now, fileManager: FileManager = .default) {
        let directory = fileManager.temporaryDirectory
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return }
        for file in files where prefixes.contains(where: { file.lastPathComponent.hasPrefix($0) }) {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) > maximumAge else { continue }
            try? fileManager.removeItem(at: file)
        }
    }
}
