import Foundation

/// Time-of-day buckets for scoping a bulk change. A single place often means two
/// different things depending on the hour — a home address is "Sleeping" overnight
/// and "At home" the rest of the day — so replacing every entry at once would
/// destroy a distinction the history already records correctly.
///
/// Shared rather than kept private to Place History: activity inference asks the
/// same "what does this place usually mean at this hour" question, and a second,
/// differently-boundaried time-of-day scheme would answer it inconsistently.
enum PlaceTimeBand: String, CaseIterable, Identifiable {
    case allDay, night, morning, day, evening, lateNight
    var id: Self { self }

    var title: String {
        switch self {
        case .allDay: "Any time"
        case .night: "00:00–06:00"
        case .morning: "06:00–11:00"
        case .day: "11:00–17:00"
        case .evening: "17:00–22:00"
        case .lateNight: "22:00–24:00"
        }
    }

    func contains(_ date: Date) -> Bool {
        guard self != .allDay else { return true }
        let hour = Calendar.current.component(.hour, from: date)
        switch self {
        case .allDay: return true
        case .night: return hour < 6
        case .morning: return hour >= 6 && hour < 11
        case .day: return hour >= 11 && hour < 17
        case .evening: return hour >= 17 && hour < 22
        case .lateNight: return hour >= 22
        }
    }

    /// The specific band (never `.allDay`) a moment falls into.
    static func containing(_ date: Date) -> PlaceTimeBand {
        allCases.first { $0 != .allDay && $0.contains(date) } ?? .allDay
    }
}
