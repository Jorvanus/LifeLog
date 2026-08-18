import Foundation

/// Owns the timeline's day-selection rules independently of SwiftUI presentation.
/// Keeping calendar arithmetic here makes foreground rollover and date-picker
/// behavior testable without constructing a view or mounting a query.
enum TimelineDaySelection {
    static func interval(of date: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return DateInterval(start: start, end: max(start, end))
    }

    static func afterForeground(current selectedDay: Date, wasShowingToday: Bool,
                                refreshedClock: Date, calendar: Calendar = .current) -> Date {
        wasShowingToday ? calendar.startOfDay(for: refreshedClock) : selectedDay
    }
}
