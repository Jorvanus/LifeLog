import Foundation

/// The period Insights is showing, and how to step through and title it.
enum InsightWindow: String, CaseIterable, Identifiable, Hashable {
    case day, week, month, year
    var id: Self { self }
    var title: String { rawValue.capitalized }

    func interval(containing date: Date) -> DateInterval {
        let calendar = Calendar.current
        switch self {
        case .day:
            let start = calendar.startOfDay(for: date)
            return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
        case .week: return calendar.dateInterval(of: .weekOfYear, for: date)!
        case .month: return calendar.dateInterval(of: .month, for: date)!
        case .year: return calendar.dateInterval(of: .year, for: date)!
        }
    }

    func move(_ date: Date, by value: Int) -> Date {
        let component: Calendar.Component = switch self { case .day: .day; case .week: .weekOfYear; case .month: .month; case .year: .year }
        return Calendar.current.date(byAdding: component, value: value, to: date) ?? date
    }

    /// The comparable preceding calendar period. Subtracting a duration makes May
    /// compare with a 31-day slice beginning in March; calendar arithmetic keeps a
    /// month against April and a leap year against the preceding calendar year.
    func previousComparisonInterval(for interval: DateInterval) -> DateInterval {
        let component: Calendar.Component = switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
        let calendar = Calendar.current
        let start = calendar.date(byAdding: component, value: -1, to: interval.start) ?? interval.start
        let end = calendar.date(byAdding: component, value: -1, to: interval.end) ?? interval.end
        return DateInterval(start: start, end: end)
    }

    func title(for interval: DateInterval) -> String {
        switch self {
        case .day: interval.start.formatted(.dateTime.day().month(.abbreviated))
        case .week: "Week of \(interval.start.formatted(.dateTime.day().month(.abbreviated)))"
        case .month: interval.start.formatted(.dateTime.month(.wide).year())
        case .year: interval.start.formatted(.dateTime.year())
        }
    }

    func subtitle(for interval: DateInterval) -> String {
        switch self {
        case .day: interval.start.formatted(.dateTime.weekday(.wide).year())
        case .week: "\(interval.start.formatted(.dateTime.day().month(.abbreviated))) – \(interval.end.addingTimeInterval(-1).formatted(.dateTime.day().month(.abbreviated).year()))"
        case .month: "\(Int(interval.duration / 86400)) days"
        case .year: "January – December"
        }
    }
}
