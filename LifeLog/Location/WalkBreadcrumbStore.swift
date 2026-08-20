import Foundation
import CoreLocation

/// Whether LifeLog keeps a coarse coordinate trail for passive walks. Off by default,
/// mirroring `LocationDiagnostics.isDetailed` — a separate switch rather than sharing
/// that one, since walk routes are a feature someone opts into, not a debugging aid.
enum WalkRouteTracking {
    static let key = "LifeLog.WalkRouteTracking.enabled.v1"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// A coarse point on the way somewhere, kept only long enough to be matched into the
/// next Health-reported walking window and folded into that Visit's own route.
struct WalkBreadcrumb: Codable, Sendable {
    let latitude: Double
    let longitude: Double
    let accuracy: Double
    let recordedAt: Date
}

/// Recent walking breadcrumbs, kept in `Caches` rather than the SwiftData store:
/// this is disposable scratch data, never part of the archive or its backups, and
/// the OS is free to purge it under storage pressure the same way it would any other
/// regenerable cache — losing a few points just means a walk's route stays empty,
/// exactly as it is today.
///
/// A capped, trimmed-on-write file plays the same role here that `LocationJournal`
/// plays for detailed diagnostics, without touching that journal's own toggle,
/// retention, or its place in the SwiftData schema/migration history.
enum WalkBreadcrumbStore {
    /// A handful of days covers the gap even if Health's own walking import falls
    /// behind for a while; whatever is older than this is no longer useful evidence
    /// of any specific walk.
    private static let maximumAge: TimeInterval = 3 * 24 * 60 * 60
    /// A hard ceiling independent of age, so a phone that never opens LifeLog for a
    /// long stretch can't grow this file without bound.
    private static let maximumCount = 2_000

    private static let lock = NSLock()

    private static var fileURL: URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("WalkBreadcrumbs.json")
    }

    /// Called from the same place `LocationJournal` records a callback's raw
    /// coordinate — a no-op unless the owner has turned this on. `now` is only ever
    /// overridden by tests, to exercise age-based trimming without waiting days.
    static func record(_ location: CLLocation, now: Date = .now) {
        guard WalkRouteTracking.isEnabled, CLLocationCoordinate2DIsValid(location.coordinate) else { return }
        lock.lock()
        defer { lock.unlock() }
        var points = load()
        points.append(WalkBreadcrumb(latitude: location.coordinate.latitude,
                                     longitude: location.coordinate.longitude,
                                     accuracy: location.horizontalAccuracy,
                                     recordedAt: location.timestamp))
        trim(&points, now: now)
        save(points)
    }

    /// Empties the store. Exposed for tests to isolate themselves from whatever the
    /// file already held; there is no user-facing reason to call this, since the
    /// owner turning tracking off is already handled by `record` simply stopping.
    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        save([])
    }

    /// Breadcrumbs inside a walking interval, oldest first — ready to become a
    /// `Visit`'s route. Safe to call whether or not tracking is enabled or any
    /// breadcrumbs exist; an empty result just means the walk stays routeless, as
    /// every passive walk does today.
    static func breadcrumbs(in interval: DateInterval) -> [WalkBreadcrumb] {
        lock.lock()
        defer { lock.unlock() }
        return load()
            .filter { interval.start <= $0.recordedAt && $0.recordedAt <= interval.end }
            .sorted { $0.recordedAt < $1.recordedAt }
    }

    private static func trim(_ points: inout [WalkBreadcrumb], now: Date) {
        let cutoff = now.addingTimeInterval(-maximumAge)
        points.removeAll { $0.recordedAt < cutoff }
        if points.count > maximumCount {
            points.removeFirst(points.count - maximumCount)
        }
    }

    private static func load() -> [WalkBreadcrumb] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([WalkBreadcrumb].self, from: data)) ?? []
    }

    private static func save(_ points: [WalkBreadcrumb]) {
        guard let data = try? JSONEncoder().encode(points) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
