import Foundation

/// Keeps existing SQLite files background-compatible after the signed app has
/// opened once. The app entitlement itself remains `Complete` to match the
/// personal-team provisioning profile; this is a best-effort file-level change.
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
