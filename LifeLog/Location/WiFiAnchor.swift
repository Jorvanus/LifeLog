import Foundation
import CryptoKit
import NetworkExtension

/// Uses the Wi-Fi network you are joined to as evidence of when you left a place.
///
/// Core Location does not report a departure until it notices the region was left,
/// which is often long afterwards — so LifeLog falls back to timing a departure from
/// the *next* arrival. A captured day had home ending at 9:05:09 and the next place
/// beginning at 9:05:17, which made a twenty-five minute commute read as four.
///
/// Your home network drops when you walk out the door, and that is a real event.
///
/// What this deliberately does **not** do is close a stay when the network goes away.
/// A router reboot, a dropped band, or a phone preferring cellular would then invent a
/// departure that never happened — the same class of mistake as inventing an arrival.
/// It only ever sharpens a departure that Core Location was already guessing at, and
/// only within bounds LifeLog actually observed.
enum WiFiAnchor {
    /// What LifeLog knows about the network under the stay currently open.
    struct Observation: Codable, Equatable, Sendable {
        /// Identifies the network without recording which network it is.
        let networkHash: String
        /// The last moment the phone was seen joined to it.
        var lastSeen: Date
        /// The first moment afterwards it was seen *not* joined to it, if that has
        /// happened yet. The true departure lies between the two.
        var firstAbsent: Date?
    }

    private static let storageKey = "LifeLog.WiFiAnchor.current.v1"

    // MARK: - Identity

    /// A network is identified by a hash, never by name. An SSID says where someone
    /// lives and who their neighbours are; the app only needs to know "the same one
    /// as before", which a digest answers just as well.
    static func hash(ssid: String, bssid: String?) -> String {
        let material = "\(ssid.lowercased())|\(bssid?.lowercased() ?? "")"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// The network the phone is joined to, or nil on cellular, in aeroplane mode, or
    /// when the entitlement or location permission is missing.
    static func currentNetworkHash() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                guard let network else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: hash(ssid: network.ssid, bssid: network.bssid))
            }
        }
    }

    // MARK: - Bookkeeping

    static func loadObservation() -> Observation? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(Observation.self, from: data)
    }

    static func save(_ observation: Observation?) {
        guard let observation, let data = try? JSONEncoder().encode(observation) else {
            UserDefaults.standard.removeObject(forKey: storageKey)
            return
        }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// Folds one sample into what is already known.
    ///
    /// Only the network present when the stay began counts. Joining a *different*
    /// network mid-stay is as good as joining none: either way the phone is no longer
    /// where it was, and the moment that was first true is what bounds the stay.
    static func update(_ observation: Observation?, sampled hash: String?,
                       at moment: Date) -> Observation? {
        guard let observation else {
            // Nothing anchored yet, so this sample becomes the anchor — but only a
            // real network can anchor anything.
            return hash.map { Observation(networkHash: $0, lastSeen: moment, firstAbsent: nil) }
        }
        if hash == observation.networkHash {
            // Back on the same network: whatever absence was seen was a drop, not a
            // departure, and the record of it must go.
            var updated = observation
            updated.lastSeen = max(observation.lastSeen, moment)
            updated.firstAbsent = nil
            return updated
        }
        guard observation.firstAbsent == nil else { return observation }
        var updated = observation
        updated.firstAbsent = moment
        return updated
    }

    // MARK: - The correction

    /// A better departure for a stay Core Location is about to close, or nil to leave
    /// its own timing alone.
    ///
    /// `firstAbsent` is the first moment LifeLog *observed* the phone off the network,
    /// so the person had certainly left by then. It is used rather than `lastSeen`
    /// because the gap between the two is unobserved, and shortening a stay into time
    /// nobody watched would be a guess.
    static func departure(for observation: Observation?, arrival: Date,
                          fallback: Date) -> Date? {
        guard let observation, let absent = observation.firstAbsent else { return nil }
        // Never extend a stay, and never end one before it began.
        guard absent > arrival, absent < fallback else { return nil }
        return absent
    }
}
