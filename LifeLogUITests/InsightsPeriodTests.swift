import XCTest

/// Insights at Week/Month/Year granularity: each period's hero cards,
/// calendars, place/health pickers, and selection state.
final class InsightsPeriodTests: LifeLogUITestCase {
    func testWeekInsightsKeepsStripHeroAndCombinesWeeklyBalance() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed", "-ui-test-week-travel"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()

        XCTAssertTrue(app.buttons["Week"].waitForExistence(timeout: 5))
        app.buttons["Week"].tap()
        XCTAssertTrue(element("insights-weekly-strip").waitForExistence(timeout: 10))
        XCTAssertTrue(element("insights-week-your-week").waitForExistence(timeout: 10))
        XCTAssertTrue(element("insights-getting-around").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Each column is a day; colours show where your time went."].exists)
        XCTAssertFalse(element("insights-week-scorecard").exists)
        XCTAssertFalse(element("insights-week-life-areas").exists)
        XCTAssertFalse(element("insights-week-commute").exists)

        let selectedDay = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'selected'"))
            .firstMatch
        XCTAssertTrue(selectedDay.waitForExistence(timeout: 5))
        let weekColumns = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'logged'"))
        XCTAssertTrue(weekColumns.firstMatch.exists)
        weekColumns.firstMatch.tap()
        XCTAssertTrue(element("weekly-selected-day").waitForExistence(timeout: 5))
        weekColumns.firstMatch.tap()
        XCTAssertFalse(element("weekly-selected-day").exists)
    }

    func testMonthInsightsUsesOneHeroCardForHeadlineAndKeyMetrics() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()

        XCTAssertTrue(app.buttons["Month"].waitForExistence(timeout: 5))
        app.buttons["Month"].tap()
        XCTAssertTrue(element("insights-month-hero").waitForExistence(timeout: 10))
        XCTAssertFalse(element("insights-month-headline").exists)
        XCTAssertFalse(element("insights-month-scorecard").exists)
        XCTAssertFalse(element("insights-travel-summary").exists)
    }

    func testMonthInsightsCalendarHasWeekdaysAndLegend() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()

        XCTAssertTrue(app.buttons["Month"].waitForExistence(timeout: 5))
        app.buttons["Month"].tap()
        XCTAssertTrue(element("insights-month-calendar").waitForExistence(timeout: 10))
        XCTAssertTrue(element("month-calendar-weekdays").waitForExistence(timeout: 5))
        XCTAssertTrue(element("month-calendar-legend").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No data"].exists)
        XCTAssertTrue(app.staticTexts["Mostly Home"].exists)
        XCTAssertTrue(app.staticTexts["Activity"].exists)
        XCTAssertTrue(app.staticTexts["Away from Home"].exists)
    }

    func testMonthPlaceStoryUsesFocusedSections() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()

        XCTAssertTrue(app.buttons["Month"].waitForExistence(timeout: 5))
        app.buttons["Month"].tap()
        XCTAssertTrue(element("insights-month-places").waitForExistence(timeout: 10))
        XCTAssertTrue(element("month-place-story-picker").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Most time"].exists)
        XCTAssertTrue(app.buttons["Most visits"].exists)
        XCTAssertTrue(app.buttons["New"].exists)
        XCTAssertTrue(app.buttons["Changed"].exists)
        XCTAssertFalse(app.staticTexts["Biggest change from last month"].exists)

        app.buttons["New"].tap()
        XCTAssertTrue(app.staticTexts["New"].exists)
    }

    func testMonthAnalysisKeepsChangesAndBalanceActionable() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()

        XCTAssertTrue(app.buttons["Month"].waitForExistence(timeout: 5))
        app.buttons["Month"].tap()
        XCTAssertTrue(element("insights-month-changes").waitForExistence(timeout: 10))
        XCTAssertTrue(element("insights-month-balance").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Recorded time by life area"].exists)
        XCTAssertFalse(app.staticTexts["Meaningful differences from last month"].exists)
    }

    func testInsightsMonthBalanceSelectionAndDeselect() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()
        XCTAssertTrue(app.buttons["Month"].waitForExistence(timeout: 5))
        app.buttons["Month"].tap()
        XCTAssertTrue(element("insights-month-balance").waitForExistence(timeout: 10))

        let balance = element("insights-month-balance")
        let firstArea = balance.buttons.firstMatch
        XCTAssertTrue(firstArea.waitForExistence(timeout: 5))
        firstArea.tap()
        XCTAssertTrue(element("month-selected-balance").waitForExistence(timeout: 5))
        firstArea.tap()
        XCTAssertFalse(element("month-selected-balance").exists)
    }

    func testYearLifeAreaChartHasSelectableLegendAndDrillDown() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()

        XCTAssertTrue(app.buttons["Year"].waitForExistence(timeout: 5))
        app.buttons["Year"].tap()
        XCTAssertTrue(element("annual-life-area-chart").waitForExistence(timeout: 10))
        let home = element("annual-life-area-Home")
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.tap()
        XCTAssertTrue(element("annual-selected-life-area").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Home"].exists)
        home.tap()
        XCTAssertFalse(element("annual-selected-life-area").exists)
    }

    func testYearPlacesUsesOneStableSelectedSegment() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()

        XCTAssertTrue(app.buttons["Year"].waitForExistence(timeout: 5))
        app.buttons["Year"].tap()
        var places = element("insights-year-places")
        var attempts = 0
        while !places.exists && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(places.waitForExistence(timeout: 5))
        XCTAssertTrue(element("year-place-picker").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Most time"].exists)
        XCTAssertTrue(app.buttons["Most visits"].exists)
        XCTAssertTrue(app.buttons["New places"].exists)
        XCTAssertTrue(app.buttons["Not visited"].exists)
        app.buttons["New places"].tap()
        XCTAssertTrue(app.staticTexts["New places"].exists)
    }

    func testYearHealthUsesFocusedSectionsAndUsefulUnavailableState() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-ui-test-seed"]
        app.launch()
        app.tabBars.buttons["Insights"].tap()

        XCTAssertTrue(app.buttons["Year"].waitForExistence(timeout: 5))
        app.buttons["Year"].tap()
        var wellbeing = element("insights-year-wellbeing")
        var attempts = 0
        while !wellbeing.exists && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(wellbeing.waitForExistence(timeout: 5))
        XCTAssertTrue(element("year-health-picker").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Movement"].exists)
        XCTAssertTrue(app.buttons["Sleep"].exists)
        XCTAssertTrue(app.buttons["Workouts"].exists)
        XCTAssertTrue(app.staticTexts["Apple Health is not connected"].waitForExistence(timeout: 5))
    }
}
