import Foundation

/// Failure switches used only by UI tests to exercise user-visible recovery paths
/// that depend on protected files or an unavailable backup writer.
enum UITestFailureInjection {
    private static var enabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTesting")
    }

    static var shouldFailBackup: Bool {
        enabled && ProcessInfo.processInfo.arguments.contains("-ui-test-fail-backup")
    }

    static var shouldFailProtectedReport: Bool {
        enabled && ProcessInfo.processInfo.arguments.contains("-ui-test-fail-protected-report")
    }

    static var shouldShowEmptyDiagnostics: Bool {
        enabled && ProcessInfo.processInfo.arguments.contains("-ui-test-empty-diagnostics")
    }
}
