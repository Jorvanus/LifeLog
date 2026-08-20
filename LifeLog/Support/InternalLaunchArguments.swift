import Foundation

/// Keeps deterministic fixtures and navigation shortcuts available to development
/// builds without allowing a distributed build to switch stores or inject failures.
enum InternalLaunchArguments {
    static var all: [String] {
#if DEBUG
        ProcessInfo.processInfo.arguments
#else
        []
#endif
    }

    static func contains(_ argument: String) -> Bool {
        all.contains(argument)
    }
}
