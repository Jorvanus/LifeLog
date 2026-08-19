import Foundation
import Testing
@testable import LifeLog

struct TimelineDaySelectionTests {
    @Test("Timeline distinguishes walking workout from passive walking")
    func walkingSourceLabels() {
        #expect(TimelineWalkingSource.resolve(source: VisitSource.healthWorkoutRaw,
                                              activity: "Walking") == .workout)
        #expect(TimelineWalkingSource.resolve(source: VisitSource.healthWalkingRaw,
                                              activity: "Walking") == .detected)
        #expect(TimelineWalkingSource.resolve(source: VisitSource.motionRaw,
                                              activity: "Walking") == .detected)
        #expect(TimelineWalkingSource.workout.title == "Walking workout")
        #expect(TimelineWalkingSource.detected.title == "Walking detected")
    }

    @Test("Timeline day intervals use the calendar day rather than a fixed duration")
    func intervalIsCalendarBounded() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let interval = TimelineDaySelection.interval(of: date, calendar: calendar)
        #expect(interval.duration == 86_400)
        #expect(calendar.isDate(interval.start, inSameDayAs: date))
    }

    @Test("Timeline rollover updates today without moving a deliberate past-day selection")
    func foregroundRolloverRespectsOwnership() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let selected = Date(timeIntervalSince1970: 1_800_000_000)
        let refreshed = selected.addingTimeInterval(86_400 + 1)
        #expect(TimelineDaySelection.afterForeground(current: selected, wasShowingToday: true,
                                                     refreshedClock: refreshed, calendar: calendar)
                == calendar.startOfDay(for: refreshed))
        #expect(TimelineDaySelection.afterForeground(current: selected, wasShowingToday: false,
                                                     refreshedClock: refreshed, calendar: calendar)
                == selected)
    }
}
