import Foundation

/// Keeps the existing SQLite files compatible with background Core Location.
/// They remain encrypted and unavailable before the first unlock after reboot.
enum StoreProtection {
    static func prepareForBackgroundAccess(storeURL: URL) {
        let fileManager = FileManager.default
        let protection = FileProtectionType.completeUntilFirstUserAuthentication
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: storeURL.path + suffix)
            guard fileManager.fileExists(atPath: file.path) else { continue }
            try? fileManager.setAttributes([.protectionKey: protection], ofItemAtPath: file.path)
        }
    }
}
