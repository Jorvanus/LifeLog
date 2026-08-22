import CoreMotion
import Foundation
import HealthKit
import Observation

/// Serialises a non-Sendable HealthKit completion so every observer delivery is
/// acknowledged exactly once, even when an import is cancelled or superseded.
final class HealthObserverDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: HKObserverQueryCompletionHandler?

    init(_ completion: @escaping HKObserverQueryCompletionHandler) {
        self.completion = completion
    }

    func finish() {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?()
    }
}

/// Maps HealthKit's deliberately limited read-authorisation information into the
/// concise states the UI can show. It is pure so permission edge cases stay testable.
enum HealthAuthorizationService {
    static func status(unaskedCount: Int, totalCount: Int, hadUnknownResult: Bool) -> String {
        if hadUnknownResult && unaskedCount == 0 { return "Couldn’t check" }
        if unaskedCount == 0 { return "Connected" }
        return unaskedCount == totalCount ? "Not connected" : "Partly connected"
    }
}

/// HealthKit observer completions are owned independently of UI progress. A burst
/// produces at most one replacement import, while every callback is acknowledged.
@MainActor
final class HealthObserverDeliveryCoordinator {
    private var completions: [HealthObserverDelivery] = []
    private(set) var replacementQueued = false

    func receive(_ delivery: HealthObserverDelivery, importing: Bool) -> Bool {
        completions.append(delivery)
        guard !importing else {
            replacementQueued = true
            return false
        }
        return true
    }

    func takeReplacementIfNeeded() -> Bool {
        guard replacementQueued else { return false }
        replacementQueued = false
        return true
    }

    func finishAll() {
        let pending = completions
        completions.removeAll()
        pending.forEach { $0.finish() }
    }
}

/// Serializes every Health-backed archive write, including the small sleep refresh
/// used by Insights. SwiftUI cancellation is cooperative: an older import can still
/// be saving when a newer observer or foreground import starts, so sharing one
/// `ActivityImportActor` is not enough unless its prepare/read/write sessions are
/// also kept from overlapping.
actor HealthImportWriteCoordinator {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard held else {
            held = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard let next = waiters.first else {
            held = false
            return
        }
        waiters.removeFirst()
        next.resume()
    }
}

/// Prevents cancellation or an older async import from publishing progress,
/// invalidation, or errors after a later import superseded it.
struct IncrementalImportCoordinator: Sendable {
    private(set) var currentID: UUID?

    mutating func begin() -> UUID {
        let id = UUID()
        currentID = id
        return id
    }

    func mayPublish(_ id: UUID) -> Bool { currentID == id }

    mutating func finish(_ id: UUID) {
        guard currentID == id else { return }
        currentID = nil
    }
}

/// Motion availability and its short retained history remain separate from HealthKit
/// permissions, so observer delivery never accidentally throttles motion catch-up.
enum MotionActivityReader {
    static func isReadable(available: Bool, authorization: CMAuthorizationStatus) -> Bool {
        available && authorization == .authorized
    }
}

enum HealthSummaryReader {
    static func cacheKey(for interval: DateInterval) -> String {
        "\(interval.start.timeIntervalSinceReferenceDate)-\(interval.end.timeIntervalSinceReferenceDate)"
    }
}

/// The only observable Health state presented by Settings and Insights. Import
/// records and HealthKit samples stay in their actors; the interface sees progress,
/// the latest durable result, and a recoverable explanation only.
@MainActor @Observable
final class HealthUIFacade {
    var authorizationStatus: String = "Not connected"
    var unaskedTypes: [String] = []
    var motionStatus: String = "Not requested"
    var lastImport: Date?
    var lastError: String?
    var progress: ActivityImportProgress?
    var sleepEvidenceState: SleepEvidenceState = .notYetChecked
    var sleepEvidenceStatus: String { sleepEvidenceState.statusText }

    var isImporting: Bool { progress?.isActive == true }
}
