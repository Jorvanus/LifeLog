import Foundation

enum ExportFileStagingError: LocalizedError {
    case outOfSpace
    case protectionFailed
    case writeFailed(Error)

    var errorDescription: String? {
        switch self {
        case .outOfSpace:
            "There isn’t enough free space to create the temporary backup. Free some space and try again."
        case .protectionFailed:
            "LifeLog couldn’t apply complete file protection to the temporary backup. Nothing was exported."
        case .writeFailed(let error):
            "LifeLog couldn’t write the temporary backup: \(error.localizedDescription)"
        }
    }
}

/// Writes a share staging copy and keeps its lifecycle distinct from the copy the
/// person chooses to save. The temporary file is protected, atomic, and removable
/// by `ExportFileCleanup`; a destination selected in the share sheet is never here.
enum ExportFileStaging {
    static func write(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw classify(error)
        }
        do {
            try fileManager.setAttributes([.protectionKey: FileProtectionType.complete],
                                          ofItemAtPath: url.path)
        } catch {
            try? fileManager.removeItem(at: url)
            throw ExportFileStagingError.protectionFailed
        }
    }

    static func isUsable(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    private static func classify(_ error: Error) -> ExportFileStagingError {
        let nsError = error as NSError
        let outOfSpace = nsError.domain == NSCocoaErrorDomain &&
            nsError.code == CocoaError.Code.fileWriteOutOfSpace.rawValue
        return outOfSpace ? .outOfSpace : .writeFailed(error)
    }
}
