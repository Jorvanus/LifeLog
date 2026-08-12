import Testing
@testable import LifeLog

struct DurationFormattingTests {
    @Test("Short durations retain useful minute precision")
    func shortDuration() {
        #expect(formatDurationMinutes(43) == "43m")
        #expect(formatDurationMinutes(7 * 60 + 25) == "7h 25m")
    }

    @Test("Long durations use days instead of four digit hour totals")
    func longDuration() {
        #expect(formatDurationMinutes(1_435 * 60 + 43) == "59d 19h")
        #expect(formatDurationMinutes(7 * 24 * 60) == "7d")
    }
}
